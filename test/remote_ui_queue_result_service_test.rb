# frozen_string_literal: true

require_relative "prompt_queue_test"

module RemoteUIQueueResultServiceTest
  module_function

  def assert(condition, message)
    raise message unless condition
  end

  def assert_guarded_failed_actions
    %w[retry discard protected].each do |operation|
      PromptQueueTest.with_queue_store do |registry, workspace|
        target = PromptQueueTest.terminal_agent(workspace, status: "blocked")
        target.enqueue_prompt!(id: "first", prompt: "First message", source: operation == "protected" ? "delegation_callback" : "user")
        store = HQ::AgentStore.new(registry.projects)
        store.save([target])
        service = HQ::RemoteService.new(registry:)
        service.instance_variable_set(:@agent_store, store)
        failed = PromptQueueTest.with_stubbed_start(error: IOError.new("Controlled launch refusal")) do
          service.process_prompt_queue(target.key, "entry_ids" => ["first"], "expected_entry_ids" => ["first"])
        end
        batch = failed.fetch(:agent).fetch(:prompt_queue).fetch("queue_work")
        attrs = { "expected_entry_ids" => ["first"], "expected_batch_id" => batch.fetch("batch_id") }
        current = service.send(:find_agent_reference!, target.key)
        current.enqueue_prompt!(id: "later", prompt: "Later message", source: "user")
        store.save([current])
        %w[retry discard].each do |kind|
          begin
            service.public_send("#{kind}_prompt_queue", target.key, attrs)
            raise "Expected stale #{kind} rejection"
          rescue HQ::RemoteService::Error => e
            assert(e.status == 409, "stale recovery must be a conflict")
          end
        end
        current = service.send(:find_agent_reference!, target.key)
        assert(current.prompt_queue_dispatch_error && current.visible_prompt_queue_entries.map { |entry| entry["id"] } == %w[first later],
               "stale recovery must retain error, work and order")
        attrs["expected_entry_ids"] = %w[first later]
        begin
          service.discard_prompt_queue(target.key, attrs.merge("expected_batch_id" => "other-batch"))
          raise "Expected changed-batch rejection"
        rescue HQ::RemoteService::Error => e
          assert(e.status == 409, "different batch must not be discarded")
        end
        if operation == "retry"
          PromptQueueTest.with_stubbed_running_start do
            response = service.retry_prompt_queue(target.key, attrs)
            assert(response.fetch(:agent).fetch(:running), "explicit retry must start the same failed work")
          end
        elsif operation == "discard"
          PromptQueueTest.with_stubbed_start(error: IOError.new("Controlled later launch refusal")) do
            response = service.discard_prompt_queue(target.key, attrs)
            assert(response[:discarded] && response[:batch]["dispositions"]["first"]["outcome"] == "declined_with_reason",
                   "discard must record the original batch disposition")
            assert(response[:agent][:prompt_queue]["entries"].any? { |entry| entry["id"] == "later" }, "later work must not be discarded")
          end
        else
          begin
            service.discard_prompt_queue(target.key, attrs)
            raise "Expected protected callback rejection"
          rescue HQ::RemoteService::Error => e
            assert(e.status == 409, "protected callbacks must be retried")
          end
        end
      end
    end
    puts "guarded failed queue retry/discard: ok"
  end

  def assert_uncertain_discard_cannot_remove_part_of_a_failed_claim
    PromptQueueTest.with_queue_store do |registry, workspace|
      target = PromptQueueTest.terminal_agent(workspace, status: "blocked")
      %w[a b].each { |id| target.enqueue_prompt!(id:, prompt: "Message #{id}", source: "user") }
      store = HQ::AgentStore.new(registry.projects)
      store.save([target])
      service = HQ::RemoteService.new(registry:)
      service.instance_variable_set(:@agent_store, store)
      PromptQueueTest.with_stubbed_start(error: IOError.new("Controlled launch refusal")) do
        service.process_prompt_queue(target.key, "entry_ids" => %w[a b], "expected_entry_ids" => %w[a b])
        service.process_prompt_queue(target.key, "entry_ids" => ["a"], "expected_entry_ids" => %w[a b])
      end
      current = service.send(:find_agent_reference!, target.key)
      batch_id = current.active_queue_work.fetch("id")
      begin
        service.remove_prompt_queue(target.key, "entry_ids" => ["a"], "expected_entry_ids" => %w[a b], "expected_batch_id" => "")
        raise "A claim created after the recovery read must block subset removal"
      rescue HQ::RemoteService::Error => e
        assert(e.status == 409, "claim race must preserve both instructions")
      end
      prompts = []
      PromptQueueTest.with_stubbed_start(prompts:) do
        removed = service.discard_prompt_queue(target.key, "expected_entry_ids" => %w[a b], "expected_batch_id" => batch_id)
        assert(removed[:discarded] && removed[:batch]["unresolved_entry_ids"].empty?, "whole failed batch must be resolved")
        assert(removed[:batch]["dispositions"].values.all? { |item| item["outcome"] == "declined_with_reason" }, "discard must be durable")
        begin
          service.retry_prompt_queue(target.key)
          raise "Discarded claim must not be retried"
        rescue HQ::RemoteService::Error => e
          assert(e.status == 409, "no discarded claim can remain available for retry")
        end
      end
      assert(prompts.empty?, "discarded instructions must never reach a retry prompt")
      assert(service.send(:find_agent_reference!, target.key).prompt_queue_claim.nil?, "discard must retire the claim")
    end
    puts "uncertain discard and later retry: ok"
  end

  def run!
    %w[started busy refusal].each do |scenario|
      PromptQueueTest.with_queue_store do |registry, workspace|
        target = PromptQueueTest.terminal_agent(workspace, status: "blocked")
        %w[a b c].each { |id| target.enqueue_prompt!(id:, prompt: "Synthetic #{id}", source: "user") }
        store = HQ::AgentStore.new(registry.projects)
        store.save([target])
        service = HQ::RemoteService.new(registry:)
        service.instance_variable_set(:@agent_store, store)
        body = { "entry_ids" => %w[c a], "expected_entry_ids" => %w[a b c] }
        stale = service.process_prompt_queue(target.key, body.merge("expected_entry_ids" => ["a"]))
        assert(stale["status"] == "stale" && stale["processed_entry_ids"].empty?, "stale must do nothing")
        result = if scenario == "refusal"
                   PromptQueueTest.with_stubbed_start(error: IOError.new("Synthetic native launch refusal")) do
                     service.process_prompt_queue(target.key, body)
                   end
                 else
                   PromptQueueTest.with_stubbed_running_start do
                     if scenario == "busy"
                       blocker = HQ::ManagedAgent.new(key: "busy", name: "Synthetic busy", project_key: "web",
                                                      template_key: "custom", workspace:, prompt: "Synthetic")
                       store.save([target, blocker])
                       store.start_agent!(blocker.key)
                     end
                     service.process_prompt_queue(target.key, body)
                   end
                 end
        agent = result.fetch(:agent)
        expected = scenario == "started" ? "started" : "accepted"
        assert(result["status"] == expected && agent[:running] == (scenario == "started"), "truthful start state: #{scenario}")
        assert(result["processed_entry_ids"] == %w[c a], "selected IDs must be explicit")
        projected = agent.fetch(:prompt_queue).fetch("entries").map { |entry| entry.fetch("id") }
        assert(projected == result["current_entry_ids"], "projection must agree with current IDs")
        if scenario == "refusal"
          assert(agent[:prompt_queue]["dispatch_error"], "launch refusal retains error")
        elsif scenario == "busy"
          assert(agent[:run_count] == 1, "busy target must not launch a new run")
        end
        puts "queue service #{scenario}: #{result['status']}, running=#{agent[:running]}, selected=#{result['processed_entry_ids'].join(',')}"
      end
    end
    assert_guarded_failed_actions
    assert_uncertain_discard_cannot_remove_part_of_a_failed_claim
    # Exercise the unchanged source-appropriate dispositions and protected callback rules.
    PromptQueueTest.assert_bulk_removal_is_audited_and_stale_snapshots_do_nothing
    PromptQueueTest.assert_failed_claim_can_be_discarded_except_for_delegation_callbacks
    PromptQueueTest.assert_selected_processing_preserves_fifo_and_prevents_duplicate_dispatch
    puts "remote_ui_queue_result_service_test: ok (isolated real service, local fake processes only)"
  end
end

RemoteUIQueueResultServiceTest.run! if $PROGRAM_NAME == __FILE__
