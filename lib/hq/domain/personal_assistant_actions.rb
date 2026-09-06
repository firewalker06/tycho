# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require "securerandom"

require_relative "constants"
require_relative "file_store"
require_relative "personal_assistant_action_catalog"

module HQ
  # Stores model-proposed assistant actions as an immutable, server-owned review
  # record. The model can describe intent, but it cannot provide identity,
  # confirmation, or an executable command.
  class PersonalAssistantActions
    READ_ONLY = PersonalAssistantActionCatalog::READ_ONLY
    MUTATIONS = PersonalAssistantActionCatalog::MUTATIONS
    TYPES = PersonalAssistantActionCatalog::TYPES
    ACTION_ARGUMENTS = PersonalAssistantActionCatalog::ARGUMENTS
    NULLABLE_ARGUMENTS = PersonalAssistantActionCatalog::NULLABLE_ARGUMENTS

    def initialize(path: File.join(PERSONAL_ASSISTANT_DIR, "proposals.json"), executor:, verifier: nil, guard: nil)
      @path = path
      @executor = executor
      @verifier = verifier
      @guard = guard
    end

    def proposals
      state.fetch("proposals", []).map { |proposal| public_proposal(proposal) }
    end

    def proposal(id)
      public_proposal(find!(id))
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
      claimed = false
      with_execution_lock(id) do
        pending = find!(id)
        raise ArgumentError, "Exact Tycho confirmation is required" if MUTATIONS.include?(pending["type"]) && confirmed != true
        proposal = synchronize do |current|
          target = current.fetch("proposals").find { |item| item["id"] == id }
          raise ArgumentError, "Unknown proposal" unless target
          raise ArgumentError, "Proposal has already been claimed" unless %w[ready awaiting_confirmation].include?(target["state"])
          @guard&.call(target.dup) if MUTATIONS.include?(target["type"])
          target["state"] = "executing"
          target["claimed_at"] = Time.now.utc.iso8601
          claimed = true
          target.dup
        end
        result = @executor.call(proposal.fetch("type"), proposal.fetch("arguments"))
        synchronize do |current|
          target = current.fetch("proposals").find { |item| item["id"] == id }
          target["state"] = "executed"; target["result"] = result; target["executed_at"] = Time.now.utc.iso8601
        end
        public_proposal(find!(id))
      end
    rescue StandardError => e
      if claimed
        synchronize do |current|
          target = current.fetch("proposals").find { |item| item["id"] == id }
          next unless target && target["state"] == "executing"

          target["state"] = "failed"
          target["error"] = e.message
          target["recovery"] = { "state" => "verification_available", "action" => "verify" }
        end
      end
      raise
    end

    def track!(id, tracked)
      synchronize do |current|
        target = current.fetch("proposals").find { |item| item["id"] == id.to_s }
        raise ArgumentError, "Unknown proposal" unless target

        target["tracked"] = tracked if tracked.is_a?(Hash) && !tracked.empty?
      end
      public_proposal(find!(id))
    end

    # Verification never re-executes a mutation. It only reconciles observed
    # state and makes a replacement proposal possible when no effect occurred.
    def verify!(id)
      raise ArgumentError, "Action verification is unavailable" unless @verifier

      claimed = false
      with_execution_lock(id, nonblocking: true) do
        proposal = synchronize do |current|
          target = current.fetch("proposals").find { |item| item["id"] == id.to_s }
          raise ArgumentError, "Unknown proposal" unless target
          raise ArgumentError, "Only failed or interrupted actions can be verified" unless %w[failed executing].include?(target["state"])
          @guard&.call(target.dup) if MUTATIONS.include?(target["type"])

          target["state"] = "verifying"
          target["verification_started_at"] = Time.now.utc.iso8601
          claimed = true
          target.dup
        end
        verification = @verifier.call(proposal.fetch("type"), proposal.fetch("arguments"), proposal)
        synchronize do |current|
          target = current.fetch("proposals").find { |item| item["id"] == id.to_s }
          target["verification"] = verification
          target["verified_at"] = Time.now.utc.iso8601
          if verification.is_a?(Hash) && verification["completed"] == true
            target["state"] = "executed"
            target["result"] = verification["result"]
            target.delete("error")
            target.delete("recovery")
          elsif verification.is_a?(Hash) && verification["no_effect"] == true
            target["state"] = "failed"
            target["recovery"] = {
              "state" => "replacement_available",
              "action" => "replace",
              "reason" => verification.is_a?(Hash) ? verification["reason"].to_s : "Tycho could not verify the outcome"
            }
          else
            target["state"] = "failed"
            target["recovery"] = {
              "state" => "outcome_unknown",
              "action" => "verify",
              "reason" => verification.is_a?(Hash) ? verification["reason"].to_s : "Tycho could not verify the outcome"
            }
          end
        end
        public_proposal(find!(id))
      end
    rescue StandardError => e
      if claimed
        synchronize do |current|
          target = current.fetch("proposals", []).find { |item| item["id"] == id.to_s }
          next unless target && target["state"] == "verifying"

          target["state"] = "failed"
          target["error"] = e.message
          target["recovery"] = { "state" => "verification_available", "action" => "verify" }
        end
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

    # Holds the proposal lock across the companion lifecycle reset. This makes
    # an executing proposal a preflight failure, rather than discovering it
    # after the protected session has been stopped or archived.
    def reset!
      with_no_executing_actions! do |current|
        result = yield
        current["proposals"] = []
        result
      end
    end

    def with_no_executing_actions!
      synchronize do |current|
        raise ArgumentError, "A Personal Assistant action is still executing" if current.fetch("proposals", []).any? { |proposal| %w[executing verifying].include?(proposal["state"]) }

        yield current
      end
    end

    private

    def normalize(item)
      raise ArgumentError, "Assistant proposal must be an object" unless item.is_a?(Hash)
      item = item.transform_keys(&:to_s)
      raise ArgumentError, "Assistant proposal has unsupported fields" unless item.keys.sort == %w[arguments description type]
      type = item["type"]
      raise ArgumentError, "Assistant action type must be a string" unless type.is_a?(String)
      raise ArgumentError, "Unsupported assistant action" unless TYPES.include?(type)
      raise ArgumentError, "Assistant action description must be a string" unless item["description"].is_a?(String)
      raise ArgumentError, "Assistant action arguments must be an object" unless item["arguments"].is_a?(Hash)
      arguments = item["arguments"].transform_keys(&:to_s)
      raise ArgumentError, "Assistant actions cannot supply server or parent identity" if arguments.keys.any? { |key| %w[server server_key parent_agent_key actor].include?(key) }
      allowed = allowed_arguments(type)
      nullable = NULLABLE_ARGUMENTS.fetch(type, [])
      raise ArgumentError, "Assistant action arguments do not match #{type}" unless arguments.keys.sort == allowed.sort && arguments.all? { |key, value| nullable.include?(key) ? value.nil? || value.is_a?(String) : value.is_a?(String) }
      { "type" => type, "arguments" => arguments, "description" => truncate(item["description"], 500) }
    end

    def allowed_arguments(type)
      ACTION_ARGUMENTS.fetch(type)
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

    def with_execution_lock(id, nonblocking: false)
      FileUtils.mkdir_p(File.dirname(@path))
      path = "#{@path}.#{Digest::SHA256.hexdigest(id.to_s)}.execution.lock"
      File.open(path, "w") do |lock|
        mode = File::LOCK_EX
        mode |= File::LOCK_NB if nonblocking
        raise ArgumentError, "Action is still executing" unless lock.flock(mode)

        yield
      end
    rescue Errno::EWOULDBLOCK
      raise ArgumentError, "Action is still executing"
    end

    def find!(id)
      state.fetch("proposals", []).find { |proposal| proposal["id"] == id.to_s } || raise(ArgumentError, "Unknown proposal")
    end

    def public_proposal(proposal)
      proposal.slice("id", "type", "arguments", "description", "active_key", "source_run_id", "state", "result", "error", "recovery", "verification", "tracked", "executed_at", "rejected_at", "verified_at")
    end


    def truncate(value, bytes)
      value.encode(Encoding::UTF_8, invalid: :replace, undef: :replace).each_char.with_object(String.new) { |char, result| break result if result.bytesize + char.bytesize > bytes; result << char }
    end
  end
end
