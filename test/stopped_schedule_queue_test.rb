# frozen_string_literal: true

require_relative "manual_schedule_queue_test"
require_relative "../lib/hq/domain/scheduler"

module StoppedScheduleQueueTest
  module_function

  def assert(condition, message)
    raise message unless condition
  end

  def assert_due_queue_runs_without_scheduled_ticks
    %w[paused stopped].each do |status|
      ManualScheduleQueueTest.fixture(status) do |store, service, agent, workspace|
        path = File.join(workspace, "schedules.yml")
        File.write(path, YAML.dump("schedules" => [{
          "key" => "manual-schedule", "cron" => "* * * * *",
          "target" => { "type" => "agent", "project_key" => "web", "agent_key" => agent.key,
                        "message" => "FORBIDDEN SCHEDULED TICK" }
        }]))
        registry = service.registry
        schedules = HQ::ScheduleRegistry.new(path:, projects: registry.projects.map { |config| HQ::Project.new(config) })
        agent.instance_variable_set(:@prompt_queue, [])
        agent.enqueue_prompt!(id: "future", prompt: "Future work", not_before: Time.now + 3600)
        agent.enqueue_prompt!(id: "first", prompt: "First due instruction")
        agent.enqueue_prompt!(id: "reply", prompt: "Due delegated reply", source: "delegation_callback")
        agent.enqueue_prompt!(id: "last", prompt: "Last due instruction")
        store.save([agent])
        now = Time.now
        before = File.binread(HQ::SCHEDULES_STATE_FILE)
        processing = service.agent(agent.key).dig(:prompt_queue, "processing")
        assert(processing["state"] == (status == "stopped" ? "ready" : "schedule"), "wrong queue wait state for #{status}")
        PromptQueueTest.with_stubbed_running_start do
          2.times do |i|
            scheduler = HQ::Scheduler.new(registry:, schedule_registry: schedules)
            result = scheduler.tick(now: now + i * 60)
            assert(result[:started].zero? && result[:queued].zero?, "#{status}: scheduled tick accepted work")
          end
          2.times.map { Thread.new { store.load } }.each(&:value)
          loaded = ManualScheduleQueueTest.current(store)
          if status == "stopped"
            assert(loaded.running? && loaded.run_count == 2, "stopped schedule must automatically start one due queue delivery")
            assert(loaded.last_run.metadata["prompt_queue_entry_ids"] == %w[first reply last], "due batch lost FIFO or delayed filtering")
            assert(loaded.prompt_queue.map { |entry| entry["id"] } == ["future"], "future entry was consumed")
            assert(!loaded.runs.any? { |run| run.metadata&.key?("schedule_due_at") }, "queue launch became a scheduled run")
            assert(!HQ::AgentMemory.new(loaded).events.any? { |event| event["content"].to_s.include?("FORBIDDEN SCHEDULED TICK") },
                   "stopped schedule accepted a tick message")
          else
            assert(!loaded.running? && loaded.run_count == 1 && loaded.prompt_queue.length == 4, "paused schedule must still suppress automatic queues")
          end
          assert(File.binread(HQ::SCHEDULES_STATE_FILE) == before, "queue dispatch changed schedule controls or history")
        end
      end
    end
  end

  def assert_stopped_queue_blockers
    %w[inquiry suspended recovery failed blocked].each do |condition|
      ManualScheduleQueueTest.fixture("stopped") do |store, _service, agent, workspace|
        agents = [agent]
        case condition
        when "inquiry", "suspended"
          inquiry = { "message" => "Choose", "fields" => [] }
          HQ::AgentMemory.new(agent).append_inquiry_request!(inquiry, inquiry_id: "keep")
          agent.structured_result = { "status" => "input_required", "inquiry" => inquiry }
          agent.last_run.status = "input_required"
          agent.suspend_inquiry!("keep") if condition == "suspended"
        when "recovery"
          agent.instance_variable_set(:@context_replacement_recovery, { "stage" => "pending" })
        else
          agent.structured_result = { "status" => condition }
          agent.last_run.status = condition
        end
        store.save(agents)
        PromptQueueTest.with_stubbed_start(error: "Unexpected blocked launch") { 2.times { store.load } }
        loaded = ManualScheduleQueueTest.current(store)
        assert(loaded.run_count == 1 && !loaded.prompt_queue_claim && !loaded.prompt_queue_dispatch_error &&
               loaded.prompt_queue.map { |entry| entry["id"] } == %w[first later], "#{condition}: automatic dispatch bypassed the blocker")
        assert(HQ::AgentMemory.new(loaded).events.none? { |event| event["type"] == "inquiry_cancelled" }, "automatic dispatch cancelled inquiry")
      end
    end
  end

  def assert_stopped_launch_failure_and_retry
    ManualScheduleQueueTest.fixture("stopped") do |store, service, agent, _workspace|
      PromptQueueTest.with_stubbed_start(error: "Controlled launch failure") { store.load }
      failed = ManualScheduleQueueTest.current(store)
      claim = Marshal.load(Marshal.dump(failed.prompt_queue_claim))
      assert(claim && failed.prompt_queue_dispatch_error && failed.run_count == 1, "automatic failure lost durable claim")
      prompts = []
      PromptQueueTest.with_stubbed_start(prompts:) do
        3.times { store.load }
        assert(prompts.empty? && ManualScheduleQueueTest.current(store).prompt_queue_claim == claim, "failed claim was automatically relaunched")
        result = service.retry_prompt_queue(agent.key, "expected_entry_ids" => %w[first later], "expected_batch_id" => claim["id"])
        assert(result["processed_entry_ids"] == %w[first later] && prompts.length == 1, "explicit retry did not recover the same claim")
        3.times { store.load }
        assert(prompts.length == 1, "recovered claim launched more than once")
      end
    end
  end

  def assert_manual_and_automatic_dispatch_share_one_claim
    ManualScheduleQueueTest.fixture("stopped") do |store, service, agent, _workspace|
      PromptQueueTest.with_stubbed_running_start do
        results = [Thread.new { store.load }, Thread.new do
          ManualScheduleQueueTest.process(service, agent)
        rescue HQ::RemoteService::Error => e
          e
        end].map(&:value)
        loaded = ManualScheduleQueueTest.current(store)
        assert(loaded.run_count == 2 && loaded.running?, "manual/automatic race launched duplicate work")
        ids = loaded.last_run.metadata.fetch("prompt_queue_entry_ids")
        assert([%w[first], %w[first later]].include?(ids), "racing delivery lost FIFO selection")
        assert(results.none? { |result| result.is_a?(HQ::RemoteService::Error) && result.status != 409 }, "unexpected race error")
      end
    end
  end

  def assert_native_failure_reloads_and_delivers_once
    ManualScheduleQueueTest.fixture("stopped") do |store, service, agent, workspace|
      previous = ENV["TYCHO_CODEX_BIN"]
      invalid = File.join(workspace, "invalid-harness")
      File.write(invalid, "#!/missing/tycho-test-interpreter\n")
      File.chmod(0o755, invalid)
      ENV["TYCHO_CODEX_BIN"] = invalid
      store.load
      failed = ManualScheduleQueueTest.current(store)
      claim = failed.prompt_queue_claim
      assert(claim && failed.prompt_queue_dispatch_error && failed.last_run.metadata["native_start_acknowledged"] == false,
             "native failure did not retain its unacknowledged claim")
      assert(PromptQueueTest.queue_read_events(failed, claim["id"]).empty?, "failed native spawn recorded a false delivery")
      ENV["TYCHO_CODEX_BIN"] = PromptQueueTest.queue_capture_harness(workspace)
      capture = File.join(workspace, "capture.txt")
      ENV["TYCHO_TEST_QUEUE_CAPTURE"] = capture
      reloaded = HQ::AgentStore.new(service.registry.projects)
      2.times { reloaded.load }
      assert(!File.exist?(capture), "fresh store automatically retried a failed native claim")
      service.retry_prompt_queue(agent.key, "expected_entry_ids" => %w[first later], "expected_batch_id" => claim["id"])
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 10
      until File.file?(capture) && !ManualScheduleQueueTest.current(reloaded).running?
        raise "native queue retry did not finish" if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

        sleep 0.01
      end
      3.times { reloaded.load }
      delivered = ManualScheduleQueueTest.current(reloaded)
      assert(File.read(capture).include?("TYCHO QUEUE WORK CONTRACT") &&
             PromptQueueTest.queue_read_events(delivered, claim["id"]).length == 1 &&
             delivered.queue_work_batch(claim["id"])["delivery_count"] == 1 && delivered.run_count == 3,
             "native retry did not retain one durable delivery after reload")
    ensure
      previous ? ENV["TYCHO_CODEX_BIN"] = previous : ENV.delete("TYCHO_CODEX_BIN")
      ENV.delete("TYCHO_TEST_QUEUE_CAPTURE")
    end
  end

  def run!
    assert_due_queue_runs_without_scheduled_ticks
    assert_stopped_queue_blockers
    assert_stopped_launch_failure_and_retry
    assert_manual_and_automatic_dispatch_share_one_claim
    assert_native_failure_reloads_and_delivers_once
    ManualScheduleQueueTest.assert_ownership_is_preserved(automatic: true)
    puts "stopped_schedule_queue_test: ok"
  end
end

StoppedScheduleQueueTest.run! if $PROGRAM_NAME == __FILE__
