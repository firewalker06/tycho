# frozen_string_literal: true

require "digest"
require "fileutils"
require "uri"

require_relative "constants"
require_relative "file_store"
require_relative "project_workspace"
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
      raise Error, "Cross-server delegation is not allowed" if !supplied_server.empty? && supplied_server != expected_server
      raise Error, "An agent cannot delegate to itself" if parent.key == child.key

      existing = relation_for_child(child.key)
      existing_parent = existing&.dig("parent", "agent_key")
      raise Error, "Agent #{child.key} already has a different parent" if existing_parent && existing_parent != parent.key

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
          "child_native_session_id" => run.session_id.to_s.empty? ? nil : safe_text(run.session_id, 500),
          "status" => status,
          "summary" => safe_text(child.last_summary, 4000),
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
      stored_server = payload["server_id"].to_s
      expected_server = server_identity.fetch("id")
      mismatch = !stored_server.empty? && stored_server != expected_server
      raise Error, "Delegation ledger belongs to a different Tycho server" if mismatch

      relationships = Array(payload["relationships"])
      invalid = relationships.any? do |relation|
        [relation["server_id"], relation.dig("parent", "server_id"), relation.dig("child", "server_id")]
          .compact.any? { |value| value != expected_server }
      end
      raise Error, "Delegation ledger contains ambiguous server identities" if invalid

      {
        "schema_version" => SCHEMA_VERSION,
        "server_id" => expected_server,
        "relationships" => relationships,
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
        "name" => safe_text(agent.display_name, 500),
        "project_key" => safe_text(agent.project_key, 200)
      }
      if include_origin
        reference["run_id"] = agent.last_run&.run_id
        reference["run_number"] = agent.run_count
        reference["native_session_id"] = safe_text(agent.session_id, 500) unless agent.session_id.to_s.empty?
      end
      reference.compact
    end

    def safe_inquiry(value)
      return nil unless value.is_a?(Hash)

      {
        "message" => safe_text(value["message"], 2000),
        "fields" => Array(value["fields"]).first(20).filter_map do |field|
          next unless field.is_a?(Hash)

          sanitized = field.slice("key", "label", "description", "input_type", "required")
          sanitized.transform_values! { |item| item.is_a?(String) ? safe_text(item, 500) : item }
          sanitized["options"] = Array(field["options"]).first(20).map { |item| safe_text(item, 300) }
          sanitized
        end
      }
    end

    def safe_attachments(values)
      Array(values).first(20).filter_map do |attachment|
        next unless attachment.is_a?(Hash)

        url = safe_http_url(attachment["url"])
        next unless url

        {
          "type" => attachment["type"].to_s == "link" ? "link" : "file",
          "title" => safe_text(attachment["title"], 500),
          "url" => url,
          "description" => safe_text(attachment["description"], 1000),
          "mime_type" => safe_text(attachment["mime_type"], 200)
        }.compact
      end
    end

    def safe_http_url(value)
      uri = URI.parse(value.to_s)
      return nil unless %w[http https].include?(uri.scheme&.downcase)
      return nil if uri.host.to_s.empty? || uri.userinfo

      decoded_path = URI.decode_www_form_component(uri.path.to_s)
      return nil if secret_value?(decoded_path) || decoded_path.match?(ProjectWorkspace::PRIVATE_KEY_MARKER)

      uri.query = nil
      uri.fragment = nil
      uri.to_s
    rescue URI::InvalidURIError
      nil
    end

    def safe_text(value, length)
      original = value.to_s
      return "[REDACTED]" if original.match?(ProjectWorkspace::PRIVATE_KEY_MARKER)

      text = original[0, length]
        .gsub(/github_pat_[A-Za-z0-9_]+|gh[pousr]_[A-Za-z0-9_]+/i, "[REDACTED]")
        .gsub(/(Bearer\s+)[^\s]+/i, "\\1[REDACTED]")
        .gsub(/((?:api[_-]?key|access[_-]?token|auth[_-]?token|password|private[_-]?key|secret|token)\s*[:=]\s*)\S+/i,
              "\\1[REDACTED]")
      ProjectWorkspace::SECRET_VALUE_PATTERNS.each { |pattern| text = text.gsub(pattern, "[REDACTED]") }
      text.gsub(/-----BEGIN (?:[A-Z0-9 ]+ )?PRIVATE KEY-----.*?-----END (?:[A-Z0-9 ]+ )?PRIVATE KEY-----/m,
                "[REDACTED]")
    end

    def secret_value?(value)
      ProjectWorkspace::SECRET_VALUE_PATTERNS.any? { |pattern| value.to_s.match?(pattern) }
    end
  end
end
