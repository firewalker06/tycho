# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require "securerandom"

require_relative "constants"
require_relative "file_store"

module HQ
  # Stores model-proposed assistant actions as an immutable, server-owned review
  # record. The model can describe intent, but it cannot provide identity,
  # confirmation, or an executable command.
  class PersonalAssistantActions
    READ_ONLY = %w[read_docs search_docs inspect_agents inspect_projects].freeze
    MUTATIONS = %w[install_or_update_tycho_skill create_agent message_agent start_agent stop_agent].freeze
    TYPES = (READ_ONLY + MUTATIONS).freeze

    def initialize(path: File.join(PERSONAL_ASSISTANT_DIR, "proposals.json"), executor:)
      @path = path
      @executor = executor
    end

    def proposals
      state.fetch("proposals", []).map { |proposal| public_proposal(proposal) }
    end

    # Only a finalized run is allowed to create proposals. source_run_id makes
    # delivery idempotent when polling, hooks, or a restarted server see it again.
    def register_finalized!(items, active_key:, source_run_id:)
      raise ArgumentError, "Finalized Personal Assistant run is required" if source_run_id.to_s.empty?

      created = synchronize do |current|
        Array(items).map do |item|
          normalized = normalize(item)
          digest = Digest::SHA256.hexdigest(JSON.generate(normalized))
          existing = current.fetch("proposals").find { |proposal| proposal["digest"] == digest && proposal["active_key"] == active_key && proposal["source_run_id"] == source_run_id }
          next existing if existing

          proposal = normalized.merge("id" => "pa-#{SecureRandom.uuid}", "digest" => digest, "active_key" => active_key,
                                      "source_run_id" => source_run_id, "state" => READ_ONLY.include?(normalized["type"]) ? "ready" : "awaiting_confirmation")
          current.fetch("proposals") << proposal
          proposal
        end
      end
      created.each { |proposal| execute!(proposal["id"], confirmed: true) if proposal["state"] == "ready" }
      created.map { |proposal| public_proposal(find!(proposal["id"])) }
    end

    def execute!(id, confirmed: false)
      pending = find!(id)
      raise ArgumentError, "Exact Tycho confirmation is required" if MUTATIONS.include?(pending["type"]) && confirmed != true
      proposal = synchronize do |current|
        target = current.fetch("proposals").find { |item| item["id"] == id }
        raise ArgumentError, "Unknown proposal" unless target
        raise ArgumentError, "Proposal has already been claimed" unless %w[ready awaiting_confirmation].include?(target["state"])
        target["state"] = "executing"
        target["claimed_at"] = Time.now.utc.iso8601
        target.dup
      end
      result = @executor.call(proposal.fetch("type"), proposal.fetch("arguments"))
      synchronize do |current|
        target = current.fetch("proposals").find { |item| item["id"] == id }
        target["state"] = "executed"; target["result"] = result; target["executed_at"] = Time.now.utc.iso8601
      end
      public_proposal(find!(id))
    rescue StandardError => e
      synchronize do |current|
        target = current.fetch("proposals").find { |item| item["id"] == id }
        next unless target && target["state"] == "executing"

        target["state"] = "failed"
        target["error"] = e.message
      end
      raise
    end

    def reject!(id)
      synchronize do |current|
        target = current.fetch("proposals").find { |item| item["id"] == id }
        raise ArgumentError, "Unknown proposal" unless target
        raise ArgumentError, "Only pending mutations can be rejected" unless target["state"] == "awaiting_confirmation"
        target["state"] = "rejected"
        target["rejected_at"] = Time.now.utc.iso8601
      end
      public_proposal(find!(id))
    end

    private

    def normalize(item)
      item = item.is_a?(Hash) ? item.transform_keys(&:to_s) : {}
      type = item["type"].to_s
      raise ArgumentError, "Unsupported assistant action" unless TYPES.include?(type)
      arguments = item["arguments"].is_a?(Hash) ? item["arguments"].transform_keys(&:to_s) : {}
      raise ArgumentError, "Assistant actions cannot supply server or parent identity" if arguments.keys.any? { |key| %w[server server_key parent_agent_key actor].include?(key) }
      allowed = allowed_arguments(type)
      raise ArgumentError, "Assistant action arguments do not match #{type}" unless arguments.keys.sort == allowed.sort && arguments.values.none?(&:nil?)
      { "type" => type, "arguments" => arguments, "description" => item["description"].to_s.byteslice(0, 500) }
    end

    def allowed_arguments(type)
      {
        "read_docs" => %w[path], "search_docs" => %w[query], "inspect_agents" => [], "inspect_projects" => [],
        "install_or_update_tycho_skill" => %w[harness action], "create_agent" => %w[project_key name prompt agent model reasoning_effort],
        "message_agent" => %w[agent_key prompt], "start_agent" => %w[agent_key], "stop_agent" => %w[agent_key]
      }.fetch(type)
    end

    def state
      FileStore.read_json(@path, fallback: { "version" => 1, "proposals" => [] })
    end

    def synchronize
      FileUtils.mkdir_p(File.dirname(@path))
      File.open("#{@path}.lock", "w") do |lock|
        lock.flock(File::LOCK_EX)
        current = state
        result = yield current
        FileStore.write_json(@path, current)
        result
      end
    end

    def find!(id)
      state.fetch("proposals", []).find { |proposal| proposal["id"] == id.to_s } || raise(ArgumentError, "Unknown proposal")
    end

    def public_proposal(proposal)
      proposal.slice("id", "type", "arguments", "description", "state", "result", "error", "executed_at", "rejected_at")
    end
  end
end
