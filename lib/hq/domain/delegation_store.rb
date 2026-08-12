# frozen_string_literal: true

require "digest"
require "fileutils"

require_relative "constants"
require_relative "file_store"
require_relative "server_identity"

module HQ
  class DelegationStore
    SCHEMA_VERSION = 1
    TERMINAL_STATUSES = %w[success succeeded no_action_needed partial failed blocked input_required stopped].freeze

    class Error < ArgumentError; end

    def initialize(path: DELEGATIONS_FILE, server_identity: ServerIdentity.load)
      @path = path
      @server_identity = server_identity
    end

    attr_reader :server_identity

    def relationships
      data.fetch("relationships")
    end

    def reports
      data.fetch("reports")
    end

    def relation_for_child(child_key)
      relationships.find { |item| item.dig("child", "agent_key") == child_key.to_s }
    end

    def children_for_parent(parent_key)
      relationships.select { |item| item.dig("parent", "agent_key") == parent_key.to_s }
    end

    def validate!(parent:, child:, parent_server_id: nil)
      expected_server = server_identity.fetch("id")
      supplied_server = parent_server_id.to_s.strip
      if !supplied_server.empty? && supplied_server != expected_server
        raise Error, "Cross-server delegation is not allowed"
      end
      raise Error, "An agent cannot delegate to itself" if parent.key == child.key

      existing = relation_for_child(child.key)
      if existing && existing.dig("parent", "agent_key") != parent.key
        raise Error, "Agent #{child.key} already has a different parent"
      end

      ancestor = parent.key
      visited = {}
      while ancestor
        raise Error, "Delegation would create a cycle" if ancestor == child.key
        break if visited[ancestor]

        visited[ancestor] = true
        ancestor = relation_for_child(ancestor)&.dig("parent", "agent_key")
      end
      existing
    end

    def attach!(parent:, child:, parent_server_id: nil, now: Time.now)
      with_lock do
        existing = validate!(parent:, child:, parent_server_id:)
        return [existing, false] if existing

        relation = {
          "id" => Digest::SHA256.hexdigest("delegation-v1\0#{server_identity.fetch("id")}\0#{parent.key}\0#{child.key}"),
          "server_id" => server_identity.fetch("id"),
          "server_name" => server_identity.fetch("name"),
          "parent" => agent_reference(parent, include_origin: true),
          "child" => agent_reference(child, include_origin: false),
          "created_at" => now.utc.iso8601
        }
        payload = data
        payload.fetch("relationships") << relation
        write(payload)
        [relation, true]
      end
    end

    def record_report!(child:, now: Time.now)
      relation = relation_for_child(child.key)
      return [nil, false] unless relation

      run = child.last_run
      return [nil, false] unless run
      status = child.effective_status.to_s
      return [nil, false] unless TERMINAL_STATUSES.include?(status)

      report_id = Digest::SHA256.hexdigest("delegation-report-v1\0#{relation.fetch("id")}\0#{run.run_id}")
      with_lock do
        payload = data
        existing = payload.fetch("reports").find { |item| item["id"] == report_id }
        return [existing, false] if existing

        report = {
          "id" => report_id,
          "relationship_id" => relation.fetch("id"),
          "parent_agent_key" => relation.dig("parent", "agent_key"),
          "child" => relation.fetch("child"),
          "child_run_id" => run.run_id,
          "child_run_number" => child.run_count,
          "child_native_session_id" => run.session_id.to_s.empty? ? nil : run.session_id,
          "status" => status,
          "summary" => child.last_summary.to_s[0, 4000],
          "inquiry" => safe_inquiry(child.latest_inquiry),
          "attachments" => safe_attachments(child.structured_result&.fetch("attachments", nil)),
          "created_at" => now.utc.iso8601,
          "delivered_at" => nil,
          "resume_state" => "queued"
        }.compact
        payload.fetch("reports") << report
        write(payload)
        [report, true]
      end
    end

    def update_report!(report_id, delivered_at: :unchanged, resume_state: nil, resumed_at: nil)
      with_lock do
        payload = data
        report = payload.fetch("reports").find { |item| item["id"] == report_id.to_s }
        return nil unless report

        next_delivered_at = delivered_at == :unchanged ? report["delivered_at"] : delivered_at&.utc&.iso8601
        next_resume_state = resume_state || report["resume_state"]
        next_resumed_at = resumed_at ? resumed_at.utc.iso8601 : report["resumed_at"]
        return report if report["delivered_at"] == next_delivered_at &&
                         report["resume_state"] == next_resume_state &&
                         report["resumed_at"] == next_resumed_at

        report["delivered_at"] = next_delivered_at
        report["resume_state"] = next_resume_state
        report["resumed_at"] = next_resumed_at if next_resumed_at
        write(payload)
        report
      end
    end

    private

    def data
      payload = FileStore.read_json(@path, fallback: {})
      {
        "schema_version" => SCHEMA_VERSION,
        "server_id" => server_identity.fetch("id"),
        "relationships" => Array(payload["relationships"]),
        "reports" => Array(payload["reports"])
      }
    end

    def write(payload)
      FileStore.write_json(@path, payload)
    end

    def with_lock
      FileUtils.mkdir_p(File.dirname(@path))
      File.open("#{@path}.lock", File::RDWR | File::CREAT, 0o600) do |file|
        file.flock(File::LOCK_EX)
        yield
      ensure
        file.flock(File::LOCK_UN)
      end
    end

    def agent_reference(agent, include_origin:)
      reference = {
        "server_id" => server_identity.fetch("id"),
        "server_name" => server_identity.fetch("name"),
        "agent_key" => agent.key,
        "name" => agent.display_name,
        "project_key" => agent.project_key
      }
      if include_origin
        reference["run_id"] = agent.last_run&.run_id
        reference["run_number"] = agent.run_count
        reference["native_session_id"] = agent.session_id unless agent.session_id.to_s.empty?
      end
      reference.compact
    end

    def safe_inquiry(value)
      return nil unless value.is_a?(Hash)

      {
        "message" => value["message"].to_s[0, 2000],
        "fields" => Array(value["fields"]).first(20).filter_map do |field|
          next unless field.is_a?(Hash)

          field.slice("key", "label", "description", "input_type", "required", "options")
        end
      }
    end

    def safe_attachments(values)
      Array(values).first(20).filter_map do |attachment|
        next unless attachment.is_a?(Hash)

        url = attachment["url"].to_s
        next unless url.match?(%r{\Ahttps?://}i)

        attachment.slice("type", "title", "url", "description", "mime_type")
      end
    end
  end
end
