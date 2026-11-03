# frozen_string_literal: true

require_relative "prompt_queue_test"

module RemoteUIQueueResultServiceTest
  module_function

  def assert(condition, message)
    raise message unless condition
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
    # Exercise the unchanged source-appropriate dispositions and protected callback rules.
    PromptQueueTest.assert_bulk_removal_is_audited_and_stale_snapshots_do_nothing
    PromptQueueTest.assert_failed_claim_can_be_discarded_except_for_delegation_callbacks
    PromptQueueTest.assert_selected_processing_preserves_fifo_and_prevents_duplicate_dispatch
    puts "remote_ui_queue_result_service_test: ok (isolated real service, local fake processes only)"
  end
end

RemoteUIQueueResultServiceTest.run! if $PROGRAM_NAME == __FILE__
