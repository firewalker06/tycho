# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require "securerandom"
require "time"

require_relative "constants"
require_relative "file_store"
require_relative "personal_assistant_action_catalog"

module HQ
  # Stores model-proposed assistant actions as an immutable, server-owned review
  # record. The model can describe intent, but it cannot provide identity,
  # confirmation, or an executable command.
  class PersonalAssistantActions
    attr_reader :path

    READ_ONLY = PersonalAssistantActionCatalog::READ_ONLY
    MUTATIONS = PersonalAssistantActionCatalog::MUTATIONS
    TYPES = PersonalAssistantActionCatalog::TYPES
    ACTION_ARGUMENTS = PersonalAssistantActionCatalog::ARGUMENTS
    NULLABLE_ARGUMENTS = PersonalAssistantActionCatalog::NULLABLE_ARGUMENTS
    TRANSITIONS = {
      "ready" => %w[ready queued],
      "awaiting_confirmation" => %w[awaiting_confirmation queued rejected],
      "queued" => %w[queued executing failed],
      "executing" => %w[executing executed failed verifying],
      "verifying" => %w[verifying executed failed],
      "failed" => %w[failed verifying],
      "executed" => %w[executed],
      "rejected" => %w[rejected]
    }.freeze

    def initialize(path: File.join(PERSONAL_ASSISTANT_DIR, "proposals.json"), executor:, verifier: nil, guard: nil,
                   auto_execute: true, clock: -> { Time.now })
      @path = path
      @executor = executor
      @verifier = verifier
      @guard = guard
      @auto_execute = auto_execute == true
      @clock = clock
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

      created, new_proposals = synchronize do |current|
        new_proposals = []
        proposals = Array(items).map do |item|
          normalized = normalize(item)
          digest = Digest::SHA256.hexdigest(JSON.generate(normalized))
          existing = current.fetch("proposals").find { |proposal| proposal["digest"] == digest && proposal["active_key"] == active_key && proposal["source_run_id"] == source_run_id }
          next existing if existing

          proposal = normalized.merge("id" => "pa-#{SecureRandom.uuid}", "digest" => digest, "active_key" => active_key,
                                      "source_run_id" => source_run_id, "state" => READ_ONLY.include?(normalized["type"]) ? "ready" : "awaiting_confirmation")
          current.fetch("proposals") << proposal
          new_proposals << proposal
          proposal
        end
        [proposals, new_proposals]
      end
      new_proposals.each { |proposal| execute!(proposal["id"], confirmed: true) if @auto_execute && proposal["state"] == "ready" }
      created.map { |proposal| public_proposal(find!(proposal["id"])) }
    end

    # Atomically accepts one immutable proposal for background execution. The
    # proposal file is the queue; callers only need to wake the server worker
    # after this method returns.
    def enqueue!(id, confirmed: false, digest: nil)
      synchronize do |current|
        target = current.fetch("proposals").find { |item| item["id"] == id.to_s }
        raise ArgumentError, "Unknown proposal" unless target
        verify_digest!(target, digest)
        if MUTATIONS.include?(target["type"]) && %w[ready awaiting_confirmation].include?(target["state"]) && confirmed != true
          raise ArgumentError, "Exact Tycho confirmation is required"
        end

        case target["state"]
        when "ready", "awaiting_confirmation"
          transition!(target, "queued")
          target["queued_at"] = timestamp
          { "accepted" => true, "replayed" => false, "proposal" => public_proposal(target) }
        when "rejected"
          { "accepted" => false, "replayed" => true, "proposal" => public_proposal(target) }
        else
          { "accepted" => true, "replayed" => true, "proposal" => public_proposal(target) }
        end
      end
    end

    alias queue! enqueue!

    # Read-only receipt lookup used by duplicate confirmation. It deliberately
    # never waits on the effect lock held by process_next!.
    def receipt!(id, digest: nil)
      target = find!(id)
      verify_digest!(target, digest)
      public_proposal(target)
    end

    # Claims, validates, executes, and records one proposal while retaining
    # the per-action lock for the entire external effect. The proposal file is
    # the queue; this is the only production execution seam.
    def process_next!(owner_id:, lease_seconds: 300, proposal_id: nil)
      owner = owner_id.to_s.strip
      raise ArgumentError, "Action worker ownership is required" if owner.empty?

      candidate_ids = if proposal_id
                        [proposal_id.to_s]
                      else
                        synchronize do |current|
                          current.fetch("proposals", []).filter_map do |proposal|
                            proposal["id"] if %w[ready queued].include?(proposal["state"])
                          end
                        end
                      end
      candidate_ids.each do |id|
        receipt = with_execution_lock(id, nonblocking: :skip) do
          process_locked!(id, owner:, lease_seconds:)
        end
        return receipt if receipt
      end
      nil
    end

    # Recovery only touches expired leases and takes the same per-action lock
    # before changing a record. A live worker therefore cannot be stolen even
    # if its bounded lease expires while an external call is running.
    def recover_expired!(worker_id:, now: @clock.call)
      owner = worker_id.to_s.strip
      raise ArgumentError, "Action worker ownership is required" if owner.empty?

      candidate_ids = synchronize do |current|
        current.fetch("proposals", []).filter_map do |proposal|
          proposal["id"] if %w[executing verifying].include?(proposal["state"])
        end
      end
      candidate_ids.sum do |id|
        recovered = with_execution_lock(id, nonblocking: :skip) do
          synchronize do |current|
            target = current.fetch("proposals").find { |item| item["id"] == id.to_s }
            next false unless target && %w[executing verifying].include?(target["state"])
            next false if lease_active?(target, now)

            mark_outcome_unknown!(target)
            true
          end
        end
        recovered ? 1 : 0
      end
    end

    alias recover_interrupted! recover_expired!

    # A displayed preview may move with an unaccepted proposal. Once frozen by
    # confirmation, it is immutable and later GETs must return it verbatim.
    def set_preflight!(id, preflight, precondition_token: nil, execution_arguments: nil, freeze: false)
      result = synchronize do |current|
        target = current.fetch("proposals").find { |item| item["id"] == id.to_s }
        raise ArgumentError, "Unknown proposal" unless target
        raise ArgumentError, "Action preflight must be an object" unless preflight.is_a?(Hash)

        if target["preflight_frozen"] == true
          supplied = precondition_token || preflight["precondition_token"]
          if freeze && supplied.to_s != target["precondition_token"].to_s
            raise ArgumentError, "Action precondition has changed"
          end
          next public_proposal(target)
        end

        token = precondition_token || preflight["precondition_token"]
        raise ArgumentError, "Action precondition token is required" if freeze && token.to_s.empty?

        target["preflight"] = deep_copy(preflight)
        target["precondition_token"] = token.to_s unless token.to_s.empty?
        target["preflight_at"] = timestamp
        if freeze
          target["preflight_frozen"] = true
          target["accepted_preflight_at"] = timestamp
          target["execution_arguments"] = deep_copy(execution_arguments) if execution_arguments.is_a?(Hash)
        end
        public_proposal(target)
      end
      result
    end

    def freeze_preflight!(id, preflight, precondition_token:, execution_arguments: nil)
      set_preflight!(id, preflight, precondition_token:, execution_arguments:, freeze: true)
    end

    def execute!(id, confirmed: false)
      pending = proposal(id)
      raise ArgumentError, "Proposal has already been claimed" unless %w[ready awaiting_confirmation].include?(pending["state"])
      raise ArgumentError, "Exact Tycho confirmation is required" if MUTATIONS.include?(pending["type"]) && confirmed != true

      enqueue!(id, confirmed:, digest: pending["digest"])
      receipt = process_next!(owner_id: "direct-#{SecureRandom.uuid}", proposal_id: id)
      raise ArgumentError, "Proposal was not available for execution" unless receipt
      raise RuntimeError, receipt["error"] if receipt["state"] == "failed" && receipt["error"]

      receipt
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

          transition!(target, "verifying")
          target["verification_started_at"] = timestamp
          claimed = true
          target.dup
        end
        verification = @verifier.call(proposal.fetch("type"), execution_arguments(proposal), proposal)
        synchronize do |current|
          target = current.fetch("proposals").find { |item| item["id"] == id.to_s }
          target["verification"] = verification
          target["verified_at"] = timestamp
          if verification.is_a?(Hash) && verification["completed"] == true
            transition!(target, "executed")
            target["result"] = verification["result"]
            target.delete("error")
            target.delete("recovery")
          elsif verification.is_a?(Hash) && verification["no_effect"] == true
            transition!(target, "failed")
            target["recovery"] = {
              "state" => "replacement_available",
              "action" => "replace",
              "reason" => verification.is_a?(Hash) ? verification["reason"].to_s : "Tycho could not verify the outcome"
            }
          else
            transition!(target, "failed")
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

          transition!(target, "failed")
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
        transition!(target, "rejected")
        target["rejected_at"] = timestamp
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
        raise ArgumentError, "A Personal Assistant action is still executing" if current.fetch("proposals", []).any? { |proposal| %w[queued executing verifying].include?(proposal["state"]) }

        yield current
      end
    end

    private

    def process_locked!(id, owner:, lease_seconds:)
      proposal = synchronize do |current|
        target = current.fetch("proposals").find { |item| item["id"] == id.to_s }
        next nil unless target

        if target["state"] == "ready"
          next nil unless READ_ONLY.include?(target["type"])

          transition!(target, "queued")
          target["queued_at"] = timestamp
        end
        next nil unless target["state"] == "queued"

        transition!(target, "executing")
        target["claimed_at"] = timestamp
        target["claim_owner"] = owner
        target["lease_expires_at"] = (@clock.call + lease_seconds.to_f).utc.iso8601(6)
        target.dup
      end
      return nil unless proposal

      begin
        @guard&.call(proposal.dup)
      rescue StandardError => e
        return fail_claimed!(id, e)
      end

      begin
        result = @executor.call(proposal.fetch("type"), execution_arguments(proposal))
      rescue StandardError => e
        return fail_execution!(id, e)
      end

      # Keep this write inside the execution lock. If it fails after the
      # effect, the record remains executing and later recovery reports an
      # unknown outcome instead of falsely claiming success or replaying it.
      synchronize do |current|
        target = current.fetch("proposals").find { |item| item["id"] == id.to_s }
        raise ArgumentError, "Unknown proposal" unless target
        raise ArgumentError, "Proposal is no longer executing" unless target["state"] == "executing"

        transition!(target, "executed")
        target["result"] = result
        target["executed_at"] = timestamp
        target.delete("error")
        target.delete("code")
        target.delete("recovery")
        target.delete("claim_owner")
        target.delete("lease_expires_at")
        public_proposal(target)
      end
    end

    def fail_claimed!(id, error)
      synchronize do |current|
        target = current.fetch("proposals").find { |item| item["id"] == id.to_s }
        next nil unless target && target["state"] == "executing"

        transition!(target, "failed")
        target["error"] = error.message
        target["code"] = error_code(error)
        target["recovery"] = {
          "state" => "replacement_available",
          "action" => "replace",
          "reason" => error.message
        }
        target.delete("claim_owner")
        target.delete("lease_expires_at")
        public_proposal(target)
      end
    end

    def fail_execution!(id, error)
      synchronize do |current|
        target = current.fetch("proposals").find { |item| item["id"] == id.to_s }
        next nil unless target && target["state"] == "executing"

        transition!(target, "failed")
        target["error"] = error.message
        target["code"] = error_code(error)
        target.delete("code") if target["code"].nil? || target["code"].empty?
        target["recovery"] = {
          "state" => "verification_available",
          "action" => "verify"
        }
        target.delete("claim_owner")
        target.delete("lease_expires_at")
        public_proposal(target)
      end
    end

    def mark_outcome_unknown!(target)
      transition!(target, "failed")
      target["error"] = "The action was interrupted before Tycho could prove its outcome."
      target["code"] = "outcome_unknown"
      target["recovery"] = {
        "state" => "outcome_unknown",
        "action" => "verify",
        "reason" => "The process stopped while the action was in flight."
      }
      target.delete("claim_owner")
      target.delete("lease_expires_at")
    end

    def lease_active?(proposal, now)
      expires_at = proposal["lease_expires_at"].to_s
      return false if expires_at.empty?

      Time.iso8601(expires_at) > now
    rescue ArgumentError, TypeError
      false
    end

    def error_code(error)
      value = if error.respond_to?(:code)
                error.code
              elsif error.respond_to?(:details) && error.details.is_a?(Hash)
                error.details["code"] || error.details[:code]
              end
      value.to_s unless value.to_s.empty?
    end

    def execution_arguments(proposal)
      stored = proposal["execution_arguments"]
      return deep_copy(stored) if stored.is_a?(Hash)

      deep_copy(proposal.fetch("arguments"))
    end

    def verify_digest!(proposal, digest)
      value = digest.to_s.strip
      return if value.empty? || value == proposal["digest"].to_s

      raise ArgumentError, "Assistant proposal has changed"
    end

    def transition!(proposal, next_state)
      current = proposal["state"].to_s
      return proposal if current == next_state
      unless TRANSITIONS.fetch(current, []).include?(next_state)
        raise ArgumentError, "Invalid assistant action transition: #{current} -> #{next_state}"
      end

      proposal["state"] = next_state
    end

    def timestamp
      @clock.call.utc.iso8601(6)
    end

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
      FileStore.read_json(@path, fallback: { "version" => 2, "proposals" => [] })
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
        acquired = lock.flock(mode)
        return nil if nonblocking == :skip && !acquired
        raise ArgumentError, "Action is still executing" unless acquired

        yield
      end
    rescue Errno::EWOULDBLOCK
      raise ArgumentError, "Action is still executing"
    end

    def find!(id)
      state.fetch("proposals", []).find { |proposal| proposal["id"] == id.to_s } || raise(ArgumentError, "Unknown proposal")
    end

    def public_proposal(proposal)
      proposal.slice(
        "id", "digest", "type", "arguments", "description", "active_key", "source_run_id", "state", "result", "error", "code", "recovery", "verification", "tracked", "preflight", "precondition_token", "preflight_frozen", "preflight_at", "accepted_preflight_at", "queued_at", "claimed_at", "executed_at", "rejected_at", "verification_started_at", "verified_at", "lease_expires_at"
      )
    end

    def deep_copy(value)
      JSON.parse(JSON.generate(value))
    end


    def truncate(value, bytes)
      value.encode(Encoding::UTF_8, invalid: :replace, undef: :replace).each_char.with_object(String.new) { |char, result| break result if result.bytesize + char.bytesize > bytes; result << char }
    end
  end
end
