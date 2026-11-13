# frozen_string_literal: true

require "stringio"
require_relative "prompt_queue_test"
require_relative "../lib/hq/cli_command"

module ManualScheduleQueueTest
  module_function

  def assert(condition, message)
    raise message unless condition
  end

  def fixture(status)
    PromptQueueTest.with_queue_store do |registry, workspace|
      agent = PromptQueueTest.terminal_agent(workspace, status: "stopped")
      agent.associate_schedule!("manual-schedule")
      %w[first later].each { |id| agent.enqueue_prompt!(id:, prompt: "Work #{id}") }
      store = HQ::AgentStore.new(registry.projects)
      store.save([agent])
      state = HQ::ScheduleState.new(key: "manual-schedule", status:, enabled: status != "paused",
                                    last_target_key: agent.key, stop_id: "operator-stop", stopped_reason: "operator",
                                    acknowledged_target_stop: "unchanged-stop", run_count: 7)
      HQ::ScheduleStore.new.save(state.key => state)
      schedule_bytes = File.binread(HQ::SCHEDULES_STATE_FILE)
      service = HQ::RemoteService.new(registry:)
      service.instance_variable_set(:@agent_store, store)
      yield store, service, agent, workspace
      assert(File.binread(HQ::SCHEDULES_STATE_FILE) == schedule_bytes, "#{status}: queue action changed schedule state")
    end
  end

  def current(store)
    store.load_with_poll_events(process_delegations: false, dispatch_prompt_queues: false).first.first
  end

  def process(service, agent)
    service.process_prompt_queue(agent.key, "entry_ids" => ["first"], "expected_entry_ids" => %w[first later])
  end

  def assert_one_delivery_and_automatic_suppression
    %w[paused stopped].each do |status|
      fixture(status) do |store, service, agent, _workspace|
        prompts = []
        PromptQueueTest.with_stubbed_start(prompts:) do
          2.times { store.load }
          assert(prompts.empty?, "#{status}: automatic poll started queued work")
          payload = service.send(:prompt_queue_payload, current(store))
          assert(payload.dig("processing", "manual_once") == { "schedule_status" => status, "blocker" => nil },
                 "#{status}: manual capability missing")
          result = process(service, agent)
          assert(result["processed_entry_ids"] == ["first"] && prompts.length == 1,
                 "#{status}: selected action did not deliver exactly once")
          loaded = current(store)
          assert(loaded.last_run.metadata["prompt_queue_entry_ids"] == ["first"], "selected claim changed")
          assert(!prompts.first.include?("Work later"), "unselected work leaked into the delivery")
          batch = loaded.active_queue_work
          store.complete_queue_work!(agent.key, batch_id: batch["id"], dispositions: [{ "entry_id" => "first", "outcome" => "completed" }])
          3.times { store.load }
          loaded = current(store)
          assert(prompts.length == 1 && loaded.visible_prompt_queue_entries.map { |entry| entry["id"] } == ["later"],
                 "#{status}: later automatic dispatch was not suppressed")
          assert(loaded.run_count == 2, "#{status}: manual delivery changed more than one run")
        end
      end
    end
  end

  def assert_concurrent_clicks_and_failure_recovery
    %w[paused stopped].each do |status|
      fixture(status) do |store, service, agent, _workspace|
        PromptQueueTest.with_stubbed_running_start do
          results = 2.times.map do
            Thread.new do
              process(service, agent)
            rescue HQ::RemoteService::Error => e
              e
            end
          end.map(&:value)
          assert(results.count { |result| result.is_a?(Hash) && result["status"] == "started" } == 1 &&
                 results.count { |result| result.is_a?(HQ::RemoteService::Error) && result.status == 409 } == 1 &&
                 current(store).run_count == 2, "#{status}: concurrent clicks launched duplicate work")
        end
      end
      fixture(status) do |store, service, agent, _workspace|
        PromptQueueTest.with_stubbed_start(error: "Controlled launch failure") { process(service, agent) }
        failed = current(store)
        claim = Marshal.load(Marshal.dump(failed.prompt_queue_claim))
        assert(claim && failed.prompt_queue_dispatch_error && failed.run_count == 1,
               "#{status}: launch failure lost the durable claim")
        prompts = []
        PromptQueueTest.with_stubbed_start(prompts:) do
          2.times { store.load }
          begin
            process(service, agent)
            raise "failed claim must use the recovery action"
          rescue HQ::RemoteService::Error => e
            assert(e.status == 409 && e.message.include?("Retry queue"), "expected exact failure blocker")
          end
          assert(prompts.empty? && current(store).prompt_queue_claim == claim, "failed claim was changed or relaunched")
          response = service.retry_prompt_queue(agent.key, "expected_entry_ids" => %w[first later], "expected_batch_id" => claim["id"])
          assert(prompts.length == 1 && response["processed_entry_ids"] == ["first"], "retry must reuse selected claim once")
          2.times { store.load }
          assert(prompts.length == 1, "automatic poll restarted the recovered batch")
        end
      end
    end
  end

  def assert_blockers_preserve_queue_and_inquiry
    %w[paused stopped].product(%w[inquiry suspended workspace recovery missing]).each do |status, condition|
      fixture(status) do |store, service, agent, workspace|
        agents = [agent]
        expected = case condition
                   when "inquiry", "suspended"
                     inquiry = { "message" => "Choose a target", "fields" => [] }
                     HQ::AgentMemory.new(agent).append_inquiry_request!(inquiry, inquiry_id: "keep-inquiry")
                     # Persist the inquiry in the same shape used by a finished harness.
                     agent.instance_variable_set(:@structured_result, { "status" => "input_required", "inquiry" => inquiry })
                     agent.last_run.status = "input_required"
                     agent.suspend_inquiry!("keep-inquiry") if condition == "suspended"
                     "Answer the inquiry"
                   when "workspace"
                     busy, pid = PromptQueueTest.running_agent(workspace)
                     busy.instance_variable_set(:@key, "busy-agent")
                     agents << busy
                     "Another agent is running"
                   when "recovery"
                     agent.instance_variable_set(:@context_replacement_recovery, { "stage" => "pending" })
                     "Context replacement recovery"
                   when "missing"
                     agent.instance_variable_set(:@workspace, File.join(workspace, "unavailable"))
                     "Queue workspace is unavailable"
                   end
        store.save(agents)
        loaded = current(store)
        capability = service.send(:prompt_queue_payload, loaded).dig("processing", "manual_once")
        assert(capability["blocker"].include?(expected), "#{condition}: UI must report the exact blocker")
        begin
          PromptQueueTest.with_stubbed_start(error: "Unexpected launch in blocker test") { process(service, agent) }
          raise "#{condition}: expected a blocker"
        rescue HQ::RemoteService::Error => e
          assert(e.status == 409 && e.message.include?(expected), "#{condition}: wrong blocker: #{e.message}")
        end
        loaded = current(store)
        assert(!loaded.active_queue_work && !loaded.prompt_queue_claim &&
               loaded.prompt_queue.map { |entry| entry["id"] } == %w[first later] && loaded.run_count == 1,
               "#{condition}: blocked request changed the queue")
        if %w[inquiry suspended].include?(condition)
          inquiry_id = condition == "suspended" ? loaded.suspended_inquiry_id : loaded.latest_inquiry_id
          assert(inquiry_id == "keep-inquiry" &&
                 HQ::AgentMemory.new(loaded).events.none? { |event| event["type"] == "inquiry_cancelled" },
                 "blocked manual request cancelled the inquiry")
        end
      ensure
        PromptQueueTest.stop_process(pid) if pid
      end
    end
  end

  def assert_ownership_is_preserved
    %w[parent user].each do |owner|
      fixture("stopped") do |store, service, agent, workspace|
        parent_workspace = File.join(workspace, "parent")
        FileUtils.mkdir_p(parent_workspace)
        parent = PromptQueueTest.terminal_agent(parent_workspace)
        parent.instance_variable_set(:@key, "parent-agent")
        agents = [agent, parent]
        store.associate_delegation!(agents:, child: agent, parent_key: parent.key)
        store.save(agents)
        actor = owner == "parent" ? HQ::DelegationActor.parent_actor(parent.key) : HQ::DelegationActor.user_actor
        store.enqueue_prompt_from!(agent.key, prompt: "Owned work", actor:, id: "owned", require_running: false)
        before = HQ::DelegationStore.new.ownership_stamp(agent.key)
        PromptQueueTest.with_stubbed_running_start do
          result = service.process_prompt_queue(agent.key, "entry_ids" => ["owned"], "expected_entry_ids" => %w[first later owned])
          loaded = current(store)
          assert(result["status"] == "started" &&
                 [loaded.last_run.delegation_owner, loaded.last_run.delegation_generation] == [owner, before["generation"]] &&
                 HQ::DelegationStore.new.ownership_stamp(agent.key) == before,
                 "manual delivery changed #{owner} ownership or generation")
        end
      end
    end
  end

  def assert_supported_cli
    fixture("stopped") do |store, _service, agent, _workspace|
      original = HQ::CLICommand.method(:agent_store_for_all)
      HQ::CLICommand.define_singleton_method(:agent_store_for_all) { store }
      out = StringIO.new
      PromptQueueTest.with_stubbed_start do
        code = HQ::CLICommand.process_agent_queue_work(agent.key,
          { entry_ids: "first", expected_entry_ids: "first,later", json: true }, out:)
        assert(code.zero? && JSON.parse(out.string)["processed_entry_ids"] == ["first"], "supported CLI failed")
      end
    ensure
      HQ::CLICommand.define_singleton_method(:agent_store_for_all, original) if original
    end
  end

  def run!
    assert_one_delivery_and_automatic_suppression
    assert_concurrent_clicks_and_failure_recovery
    assert_blockers_preserve_queue_and_inquiry
    assert_ownership_is_preserved
    assert_supported_cli
    puts "manual_schedule_queue_test: ok"
  end
end

ManualScheduleQueueTest.run! if $PROGRAM_NAME == __FILE__
