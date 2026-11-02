# frozen_string_literal: true

require "digest"

module HQ
  class AgentStore
    INQUIRY_RECEIPT_TTL = 7 * 24 * 60 * 60
    INQUIRY_RECEIPT_LIMIT = 128

    # The answer, FIFO inclusion, ownership and acceptance record commit together.
    # Expired intents cannot become new writes after their record is pruned.
    def accept_inquiry_intent!(key, inquiry_id:, intent_id:, fingerprint:, created_at:, start:, schedule_targets_for:, prepare:)
      with_exclusive_lock do
        agents, = read_snapshot
        target = find_agent_in!(agents, key)
        assert_inquiry_visible!(target)
        now = Time.now
        raise ArgumentError, "Answer recovery has expired" unless created_at <= now + 60 && created_at > now - INQUIRY_RECEIPT_TTL

        target.inquiry_receipts.delete_if { |_id, receipt| Time.parse(receipt.fetch("created_at")) <= now - INQUIRY_RECEIPT_TTL }
        if (receipt = target.inquiry_receipts[intent_id])
          raise ArgumentError, "Answer intent does not match" unless receipt["fingerprint"] == fingerprint && receipt["inquiry_id"] == inquiry_id

          return { agent: target, receipt:, replayed: true }
        end
        raise ArgumentError, "Too many retained answers; try later" if target.inquiry_receipts.size >= INQUIRY_RECEIPT_LIMIT

        receipt = { "fingerprint" => fingerprint, "inquiry_id" => inquiry_id, "created_at" => created_at.utc.iso8601(6) }
        begin
          FileTransaction.run([AGENTS_FILE, DELEGATIONS_FILE, target.memory_path, target.attachments_path]) do |transaction|
            raise PromptInputRejected, "Inquiry has changed; refresh and try again" if inquiry_id.to_s.empty? || target.latest_inquiry_id.to_s != inquiry_id

            prepared = prepare.call(target)
            transaction.on_rollback { AgentAttachmentStore.new(target).remove_remote_uploads!(prepared.fetch(:attachments)) }
            accept_delegation_prompt!(target, owner: "user")
            metadata = { "inquiry_intent_id" => intent_id }
            target.add_user_message!(prepared.fetch(:answer), inquiry_id:, attachments: prepared.fetch(:attachments), metadata:, event_id: "inquiry-answer:#{intent_id}")
            unless prepared[:feedback_embedded] || prepared[:feedback].to_s.empty?
              target.add_user_message!(prepared[:feedback], metadata: metadata.merge("inquiry_feedback" => true), event_id: "inquiry-answer:#{intent_id}:feedback")
            end
            include_pending_queue_work_with_user_input!(target)
            receipt.merge!("accepted_at" => now.utc.iso8601(6), "run_count" => target.run_count,
                           "authority" => @delegation_coordinator.ownership_stamp(key), "input_marker" => inquiry_input_marker(target),
                           "start_result" => start ? nil : "not_requested", "schedule_resume_targets" => schedule_targets_for.call(target),
                           "schedule_resume_complete" => false, "schedule_resume_result" => [])
            target.inquiry_receipts[intent_id] = receipt
            save_unlocked(agents)
          end
        rescue PromptInputRejected => e
          agents, = read_snapshot
          target = find_agent_in!(agents, key)
          receipt.merge!("rejected" => true, "reason" => e.message)
          target.inquiry_receipts[intent_id] = receipt
          save_unlocked(agents)
        end
        { agent: target, receipt:, replayed: false }
      end
    end

    # A run records this intent before native spawn. A lost response never starts it twice.
    # A later user action or inquiry supersedes an unfinished original start decision.
    def finish_inquiry_start!(key, intent_id:)
      with_exclusive_lock do
        agents, = read_snapshot
        target = find_agent_in!(agents, key)
        assert_inquiry_visible!(target)
        receipt = target.inquiry_receipts.fetch(intent_id)
        return target if receipt["rejected"] || receipt["start_result"]

        original_run = target.runs.find { |run| run.metadata&.fetch("inquiry_intent_id", nil) == intent_id }
        receipt["start_result"] = if original_run
                                    "attempted"
                                  elsif target.run_count != receipt["run_count"] || target.latest_inquiry || target.suspended_inquiry ||
                                        inquiry_input_marker(target) != receipt["input_marker"] ||
                                        @delegation_coordinator.ownership_stamp(key) != receipt["authority"]
                                    "superseded"
                                  elsif target.running?
                                    "already_running"
                                  end
        unless receipt["start_result"]
          dispatched = start_target!(target, agents, run_metadata: { "inquiry_intent_id" => intent_id })
          receipt["start_result"] = dispatched ? "started" : "not_started"
        end
        save_unlocked(agents)
        target
      end
    end

    def complete_inquiry_schedule_effect!(key, intent_id:)
      with_exclusive_lock do
        agents, = read_snapshot
        target = find_agent_in!(agents, key)
        assert_inquiry_visible!(target)
        receipt = target.inquiry_receipts.fetch(intent_id)
        return target if receipt["schedule_resume_complete"]

        allow_resume = !receipt["schedule_resume_superseded"] && !target.latest_inquiry && !target.suspended_inquiry &&
                       @delegation_coordinator.ownership_stamp(key) == receipt["authority"]
        resumed_schedules = yield receipt, allow_resume
        receipt["schedule_resume_result"] = resumed_schedules.map { |item| item.transform_keys(&:to_s) }
        receipt["schedule_resume_complete"] = true
        save_unlocked(agents)
        target
      end
    end

    def inquiry_input_marker(target)
      event = AgentMemory.new(target).events.reverse.find { |item| item["type"] == "user_message" }
      Digest::SHA256.hexdigest(JSON.generate(event))
    end

    def assert_inquiry_visible!(target)
      raise ArgumentError, "Unknown agent: #{target.key}" unless Visibility.agent_visible?(target, @projects)
    end
  end
end
