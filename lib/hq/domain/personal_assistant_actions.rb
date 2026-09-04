# frozen_string_literal: true

require "digest"
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

    def register!(items, active_key:)
      Array(items).map do |item|
        normalized = normalize(item)
        digest = Digest::SHA256.hexdigest(JSON.generate(normalized))
        existing = state.fetch("proposals", []).find { |proposal| proposal["digest"] == digest && proposal["active_key"] == active_key }
        next public_proposal(existing) if existing

        proposal = normalized.merge("id" => "pa-#{SecureRandom.uuid}", "digest" => digest, "active_key" => active_key,
                                    "state" => READ_ONLY.include?(normalized["type"]) ? "ready" : "awaiting_confirmation")
        update { |current| current.fetch("proposals") << proposal }
        execute!(proposal["id"], confirmed: true) if READ_ONLY.include?(proposal["type"])
        public_proposal(find!(proposal["id"]))
      end
    end

    def execute!(id, confirmed: false)
      proposal = find!(id)
      raise ArgumentError, "Proposal has already been executed" if %w[executed rejected].include?(proposal["state"])
      raise ArgumentError, "Exact Tycho confirmation is required" if MUTATIONS.include?(proposal["type"]) && confirmed != true

      update do |current|
        target = current.fetch("proposals").find { |item| item["id"] == id }
        raise ArgumentError, "Proposal has already been executed" if target["state"] == "executed"
        target["state"] = "executing"
      end
      result = @executor.call(proposal.fetch("type"), proposal.fetch("arguments"))
      update do |current|
        target = current.fetch("proposals").find { |item| item["id"] == id }
        target["state"] = "executed"; target["result"] = result; target["executed_at"] = Time.now.utc.iso8601
      end
      public_proposal(find!(id))
    rescue StandardError => e
      update do |current|
        target = current.fetch("proposals").find { |item| item["id"] == id }
        target["state"] = "failed"; target["error"] = e.message if target && target["state"] == "executing"
      end
      raise
    end

    private

    def normalize(item)
      item = item.is_a?(Hash) ? item.transform_keys(&:to_s) : {}
      type = item["type"].to_s
      raise ArgumentError, "Unsupported assistant action" unless TYPES.include?(type)
      arguments = item["arguments"].is_a?(Hash) ? item["arguments"].transform_keys(&:to_s) : {}
      raise ArgumentError, "Assistant actions cannot supply server or parent identity" if arguments.keys.any? { |key| %w[server server_key parent_agent_key actor].include?(key) }
      { "type" => type, "arguments" => arguments.slice(*allowed_arguments(type)), "description" => item["description"].to_s.byteslice(0, 500) }
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

    def update
      state = state(); result = yield state; FileStore.write_json(@path, state); result
    end

    def find!(id)
      state.fetch("proposals", []).find { |proposal| proposal["id"] == id.to_s } || raise(ArgumentError, "Unknown proposal")
    end

    def public_proposal(proposal)
      proposal.slice("id", "type", "arguments", "description", "state", "result", "error", "executed_at")
    end
  end
end
