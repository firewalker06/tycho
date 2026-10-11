# frozen_string_literal: true

require "fileutils"
require "rbconfig"
require "tmpdir"
require "yaml"

require_relative "../lib/hq/app"
require_relative "../lib/hq/remote_server"

module ContextReplacementRecoveryTest
  module_function

  def run!
    with_stubbed_agent_start do
      assert_remote_prompt_start_is_inhibited
      assert_remote_recovery_chain_inhibits_dispatch_and_retries
      assert_clear_rejects_running_replacement_and_retry_stops_it
      assert_clear_observes_post_marker_and_concurrent_queue_arrival
      assert_remote_completion_observes_concurrent_queue_arrival
      assert_tui_recovery_chain_inhibits_dispatch
      assert_tui_completion_observes_concurrent_queue_arrival
      assert_scheduler_tick_inhibits_pending_recovery
    end
    puts "context_replacement_recovery_test: ok"
  end

  def assert_remote_prompt_start_is_inhibited
    with_temp_runtime do |dir|
      service = HQ::RemoteService.new(registry: write_registry(dir))
      target_payload = service.create_agent(agent_attributes("Prompt start target"))
      store = service.instance_variable_get(:@agent_store)
      store.record_context_replacement_recovery!(
        target_payload[:key], source_key: "source-agent", pending_actions: ["restore_schedule"],
        errors: { "restore_schedule" => "restore failed" }
      )

      assert_raises(HQ::RemoteServer::Error, "expected Remote start:true to honor recovery inhibition") do
        service.submit_prompt(target_payload[:key], "prompt" => "Do not launch", "start" => true)
      end
      target = load_without_dispatch(store).find { |agent| agent.key == target_payload[:key] }
      assert(target.run_count.zero? && target.context_replacement_recovery,
             "expected the shared start boundary not to launch a recovery-pending replacement")
      events = HQ::AgentMemory.new(target).events
      assert(events.none? { |event| event["content"] == "Do not launch" },
             "expected rejected prompt acceptance to roll back with the inhibited launch")

      store.update_agent!(target.key) do |agent|
        agent.enqueue_prompt!(prompt: "Explicit queued work", source: "user")
      end
      queued = load_without_dispatch(store).find { |agent| agent.key == target.key }
      entry_ids = queued.visible_prompt_queue_entries.map { |entry| entry.fetch("id") }
      store.process_prompt_queue_entries!(target.key, entry_ids:, expected_entry_ids: entry_ids)
      queued = load_without_dispatch(store).find { |agent| agent.key == target.key }
      assert(queued.run_count.zero? && queued.context_replacement_recovery,
             "expected explicit queue processing to use the same inhibited start boundary")
    end
  end

  def assert_clear_observes_post_marker_and_concurrent_queue_arrival
    with_temp_runtime do |dir|
      service = HQ::RemoteService.new(registry: write_registry(dir))
      source_payload = service.create_agent(agent_attributes("Clear source"))
      target_payload = service.create_agent(agent_attributes("Clear target"))
      store = service.instance_variable_get(:@agent_store)
      store.record_context_replacement_recovery!(
        target_payload[:key], source_key: source_payload[:key], pending_actions: [], errors: {},
        queue_work_retained: false
      )
      entered, release = gate_store_call_before(store, :clear_context_replacement_recovery_if_safe!)
      clear_thread = Thread.new do
        begin
          service.clear_context_replacement_recovery(target_payload[:key])
        rescue StandardError => e
          e
        end
      end
      entered.pop
      store.update_agent!(target_payload[:key]) do |agent|
        agent.enqueue_prompt!(prompt: "Concurrent retained work", source: "user")
      end
      release << true
      error = clear_thread.value

      target = load_without_dispatch(store).find { |agent| agent.key == target_payload[:key] }
      assert(error.is_a?(HQ::RemoteServer::Error) && error.status == 409,
             "expected atomic Clear to reject queue work that arrived after a false retained snapshot")
      assert(target.pending_prompts? && target.context_replacement_recovery,
             "expected unsafe Clear to retain both current queue work and the recovery marker")
    end
  end

  def assert_remote_completion_observes_concurrent_queue_arrival
    with_temp_runtime do |dir|
      service = HQ::RemoteService.new(registry: write_registry(dir))
      source_payload = service.create_agent(agent_attributes("Remote completion source"))
      target_payload = service.create_agent(agent_attributes("Remote completion target"))
      store = service.instance_variable_get(:@agent_store)
      source = load_without_dispatch(store).find { |agent| agent.key == source_payload[:key] }
      target = load_without_dispatch(store).find { |agent| agent.key == target_payload[:key] }
      store.record_context_replacement_recovery!(
        target.key, source_key: source.key, pending_actions: [], errors: {}, queue_work_retained: false
      )
      entered, release = gate_store_call_before(store, :complete_context_replacement_recovery!)
      recovery_thread = Thread.new do
        service.send(:recover_context_replacement_archive_rejection!, source, target, pending_actions: [])
      end
      entered.pop
      store.update_agent!(target.key) { |agent| agent.enqueue_prompt!(prompt: "Remote race work", source: "user") }
      release << true
      recovery_thread.value

      recovered = load_without_dispatch(store).find { |agent| agent.key == target.key }
      assert(recovered.pending_prompts? && recovered.context_replacement_recovery,
             "expected Remote completion to retain inhibition after concurrent queue arrival")
      assert(recovered.context_replacement_recovery["queue_work_retained"],
             "expected Remote completion to refresh retained-work state from the current target")
    end
  end

  def assert_clear_rejects_running_replacement_and_retry_stops_it
    with_temp_runtime do |dir|
      service = HQ::RemoteService.new(registry: write_registry(dir))
      source_payload = service.create_agent(agent_attributes("Running source"))
      store = service.instance_variable_get(:@agent_store)
      source = load_without_dispatch(store).find { |agent| agent.key == source_payload[:key] }
      target = store.clone_agent(source, existing_agents: [source])
      pid = Process.spawn(RbConfig.ruby, "-e", "sleep 30", pgroup: true, out: File::NULL, err: File::NULL)
      target.instance_variable_set(:@pid, pid)
      target.instance_variable_set(:@started_at, Time.now)
      target.instance_variable_set(:@finished_at, nil)
      target.instance_variable_set(:@last_exit_code, nil)
      store.save([source, target])
      store.record_context_replacement_recovery!(
        target.key, source_key: source.key, pending_actions: [], errors: {}
      )

      assert_raises(HQ::RemoteServer::Error, "expected clear to reject a running replacement") do
        service.clear_context_replacement_recovery(target.key)
      end
      retried = service.retry_context_replacement_recovery(target.key)
      assert(retried.dig(:agent, :context_replacement_recovery).nil?,
             "expected retry to add the missing stop step and clear recovery")
      Process.wait(pid)
      pid = nil
    ensure
      if pid
        Process.kill("TERM", -pid)
        Process.wait(pid)
      end
    end
  rescue Errno::ESRCH, Errno::ECHILD
    nil
  end

  def assert_remote_recovery_chain_inhibits_dispatch_and_retries
    with_temp_runtime do |dir|
      registry = write_registry(dir)
      service = HQ::RemoteService.new(registry:)
      source_payload = service.create_agent(agent_attributes("Remote source"))
      store = service.instance_variable_get(:@agent_store)
      original_start = store.method(:start_agent!)
      original_stop = store.method(:stop_context_replacement!)
      stop_attempts = 0

      store.define_singleton_method(:start_agent!) do |key|
        original_start.call(key).tap do
          update_agent!(source_payload[:key]) { |agent| agent.enqueue_prompt!(prompt: "Late source work", source: "user") }
          update_agent!(key) { |agent| agent.enqueue_prompt!(prompt: "Retained replacement work", source: "user") }
        end
        load_with_poll_events(process_delegations: false, dispatch_prompt_queues: false).first.find { |agent| agent.key == key }
      end
      store.define_singleton_method(:stop_context_replacement!) do |key|
        stop_attempts += 1
        raise "simulated stop failure" if stop_attempts == 1

        original_stop.call(key)
      end

      error = begin
        service.clone_agent(source_payload[:key], "archive_source" => true, "context_handoff" => true, "start" => true)
        nil
      rescue HQ::RemoteServer::Error => e
        e
      end
      agents = load_without_dispatch(store)
      replacement = agents.find { |agent| agent.key != source_payload[:key] }
      recovery = replacement.context_replacement_recovery
      assert(error&.status == 409, "expected the late source queue to reject archive")
      assert(replacement.run_count == 1 && replacement.pending_prompts?,
             "expected the pre-marker refresh not to start retained replacement work")
      assert(recovery.fetch("pending_actions") == ["stop_replacement"],
             "expected the failed stop to remain a retryable recovery step")

      assert_raises(ArgumentError, "expected manual start to be inhibited during recovery") do
        store.start_agent!(replacement.key)
      end
      assert_raises(HQ::RemoteServer::Error, "expected clear to reject pending safety recovery") do
        service.clear_context_replacement_recovery(replacement.key)
      end

      queued_ids = replacement.visible_prompt_queue_entries.map { |entry| entry.fetch("id") }
      removed = service.remove_prompt_queue(
        replacement.key,
        "entry_ids" => queued_ids,
        "expected_entry_ids" => queued_ids,
        "reason" => "Explicit recovery action"
      )
      assert((removed[:removed_entry_ids] || removed["removed_entry_ids"]) == queued_ids,
             "expected queued work to require an explicit action")
      retried = service.retry_context_replacement_recovery(replacement.key)
      assert(retried.dig(:agent, :context_replacement_recovery).nil?,
             "expected retry to complete the pending step and clear recovery")
      recovered = load_without_dispatch(store).find { |agent| agent.key == replacement.key }
      assert(recovered.run_count == 1 && !recovered.pending_prompts?,
             "expected retry not to run retained replacement work")

      ordinary_payload = service.create_agent(agent_attributes("Ordinary stop"))
      ordinary = store.start_agent!(ordinary_payload[:key])
      store.update_agent!(ordinary.key) { |agent| agent.enqueue_prompt!(prompt: "Continue normally", source: "user") }
      stopped = store.stop_agent!(ordinary.key)
      assert(stopped.run_count == 2, "expected an ordinary stop to keep normal queue dispatch behavior")
    end
  end

  def assert_tui_recovery_chain_inhibits_dispatch
    with_temp_runtime do |dir|
      registry = write_registry(dir)
      service = HQ::RemoteService.new(registry:)
      source_payload = service.create_agent(agent_attributes("TUI source"))
      store = service.instance_variable_get(:@agent_store)
      source = load_without_dispatch(store).find { |agent| agent.key == source_payload[:key] }
      target = store.clone_agent(source, existing_agents: [source])
      store.save([source, target])
      store.start_agent!(target.key)
      store.update_agent!(target.key) { |agent| agent.enqueue_prompt!(prompt: "Retain in TUI recovery", source: "user") }
      source, target = load_without_dispatch(store).sort_by { |agent| agent.key == source.key ? 0 : 1 }

      app = HQ::App.allocate
      app.instance_variable_set(:@agent_store, store)
      app.send(:recover_context_pressure_archive_rejection!, source, target)

      recovered = load_without_dispatch(store).find { |agent| agent.key == target.key }
      assert(recovered.run_count == 1 && recovered.pending_prompts?,
             "expected TUI recovery to retain queued work without starting it")
      assert(recovered.context_replacement_recovery && recovered.context_replacement_recovery["queue_work_retained"],
             "expected TUI recovery to persist queue inhibition before refresh")
    end
  end

  def assert_tui_completion_observes_concurrent_queue_arrival
    with_temp_runtime do |dir|
      service = HQ::RemoteService.new(registry: write_registry(dir))
      source_payload = service.create_agent(agent_attributes("TUI completion source"))
      target_payload = service.create_agent(agent_attributes("TUI completion target"))
      store = service.instance_variable_get(:@agent_store)
      source = load_without_dispatch(store).find { |agent| agent.key == source_payload[:key] }
      target = load_without_dispatch(store).find { |agent| agent.key == target_payload[:key] }
      app = HQ::App.allocate
      app.instance_variable_set(:@agent_store, store)
      entered, release = gate_store_call_before(store, :complete_context_replacement_recovery!)
      recovery_thread = Thread.new { app.send(:recover_context_pressure_archive_rejection!, source, target) }
      entered.pop
      store.update_agent!(target.key) { |agent| agent.enqueue_prompt!(prompt: "TUI race work", source: "user") }
      release << true
      recovery_thread.value

      recovered = load_without_dispatch(store).find { |agent| agent.key == target.key }
      assert(recovered.pending_prompts? && recovered.context_replacement_recovery,
             "expected TUI completion to retain inhibition after concurrent queue arrival")
      assert(recovered.context_replacement_recovery["queue_work_retained"],
             "expected TUI completion to refresh retained-work state from the current target")
    end
  end

  def assert_scheduler_tick_inhibits_pending_recovery
    with_temp_runtime do |dir|
      now = Time.new(2026, 10, 11, 9, 0, 0, "+07:00")
      registry, schedules_path = write_registry(dir, schedule: true)
      projects = registry.projects.map { |config| HQ::Project.new(config) }
      schedule_store = HQ::ScheduleStore.new
      scheduler = HQ::Scheduler.new(
        registry:,
        schedule_registry: HQ::ScheduleRegistry.new(path: schedules_path, projects:, store: schedule_store),
        store: schedule_store
      )
      first = scheduler.run_now("recovery-loop", now:).fetch(:agent)
      agent_store = scheduler.instance_variable_get(:@agent_store)
      agent_store.record_context_replacement_recovery!(
        first.key, source_key: "source-agent", pending_actions: ["restore_schedule"],
        errors: { "restore_schedule" => "simulated restore failure" }
      )
      states = HQ::ScheduleStore.new.load
      state = states.fetch("recovery-loop")
      state.next_due_at = now + 60
      HQ::ScheduleStore.new.save(states)

      totals = scheduler.tick(now: now + 60)
      recovered = load_without_dispatch(agent_store).find { |agent| agent.key == first.key }
      assert(totals.fetch(:failed) == 1, "expected the real scheduler tick to reject a recovery-pending target")
      assert(recovered.run_count == 1 && recovered.context_replacement_recovery,
             "expected the failed scheduler tick not to start the rejected replacement")
    end
  end

  def agent_attributes(name)
    { "project_key" => "web", "template_key" => "custom", "name" => name,
      "prompt" => "Keep this work.", "agent" => "codex" }
  end

  def load_without_dispatch(store)
    store.load_with_poll_events(process_delegations: false, dispatch_prompt_queues: false).first
  end

  def gate_store_call_before(store, method_name)
    entered = Queue.new
    release = Queue.new
    original = store.method(method_name)
    store.define_singleton_method(method_name) do |*args, **kwargs|
      entered << true
      release.pop
      original.call(*args, **kwargs)
    end
    [entered, release]
  end

  def write_registry(dir, schedule: false)
    workspace = File.join(dir, "workspace")
    FileUtils.mkdir_p(workspace)
    config_path = File.join(dir, "hq.yml")
    schedules_path = File.join(dir, "schedules.yml")
    File.write(config_path, <<~YAML)
      projects:
        - key: web
          name: Web
          path: #{workspace}
          agent: codex
    YAML
    File.write(schedules_path, schedule ? <<~YAML : "schedules: []\n")
      schedules:
        - key: recovery-loop
          cron: "* * * * *"
          target:
            type: agent
            project_key: web
            name: Recovery loop
            message: "Scheduled recovery work."
    YAML
    old_schedules = ENV["TYCHO_SCHEDULES_PATH"]
    ENV["TYCHO_SCHEDULES_PATH"] = schedules_path
    registry = HQ::Registry.new(path: config_path)
    ENV["TYCHO_SCHEDULES_PATH"] = old_schedules
    schedule ? [registry, schedules_path] : registry
  end

  def with_temp_runtime
    Dir.mktmpdir("hq-context-replacement-recovery-test") do |dir|
      replacements = {
        AGENTS_FILE: File.join(dir, "managed_agents.json"),
        DELEGATIONS_FILE: File.join(dir, "agent_delegations.json"),
        AGENT_LOGS_DIR: File.join(dir, "agents"),
        AGENT_ARCHIVE_DIR: File.join(dir, "agents", "archive"),
        SCHEDULES_STATE_FILE: File.join(dir, "schedules.json"),
        PUSH_NOTIFICATIONS_FILE: File.join(dir, "push_notifications.json")
      }
      old = replacements.to_h { |name, value| [name, replace_constant(HQ, name, value)] }
      old_schedules = ENV["TYCHO_SCHEDULES_PATH"]
      FileUtils.mkdir_p(HQ::AGENT_LOGS_DIR)
      FileUtils.mkdir_p(HQ::AGENT_ARCHIVE_DIR)
      yield dir
    ensure
      old.each { |name, value| replace_constant(HQ, name, value) } if old
      old_schedules ? ENV["TYCHO_SCHEDULES_PATH"] = old_schedules : ENV.delete("TYCHO_SCHEDULES_PATH")
    end
  end

  def with_stubbed_agent_start
    original = HQ::ManagedAgent.instance_method(:start!)
    HQ::ManagedAgent.define_method(:start!) do |delegation_stamp: nil, run_metadata: nil, **_options|
      now = Time.now
      FileUtils.mkdir_p(File.dirname(raw_log_path))
      File.write(raw_log_path, "stubbed recovery run\n")
      @started_at = now
      @finished_at = now
      @last_exit_code = 0
      @pid = nil
      @runs << HQ::ManagedAgent::AgentRun.new(
        started_at: now, finished_at: now, exit_code: 0, status: "succeeded",
        log_path: raw_log_path, command: "stubbed",
        delegation_owner: delegation_stamp&.fetch("owner", nil),
        delegation_generation: delegation_stamp&.fetch("generation", nil),
        metadata: run_metadata.is_a?(Hash) ? run_metadata : {}
      )
      self
    end
    yield
  ensure
    HQ::ManagedAgent.define_method(:start!, original)
  end

  def replace_constant(mod, name, value)
    old = mod.const_get(name) if mod.const_defined?(name, false)
    mod.send(:remove_const, name) if mod.const_defined?(name, false)
    mod.const_set(name, value)
    old
  end

  def assert(condition, message)
    raise message unless condition
  end

  def assert_raises(error_class, message)
    yield
    raise message
  rescue error_class
    nil
  end
end

ContextReplacementRecoveryTest.run!
