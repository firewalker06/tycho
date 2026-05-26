# frozen_string_literal: true

require "fileutils"
require "json"
require "open3"
require "rbconfig"
require "time"
require "tmpdir"

require_relative "../lib/hq/domain/schedule_daemon_supervisor"
require_relative "../lib/hq/domain/scheduler"

ROOT = File.expand_path("..", __dir__)

module SchedulerTest
  module_function

  def run!
    with_stubbed_agent_start do
      assert_schedule_registry_validates_scope_and_prompt_paths
      assert_schedule_store_tracks_daemon_state
      assert_scheduler_run_creates_fresh_agent_and_archives_previous
      assert_scheduler_skips_interactive_scheduled_agent_without_archiving
    end
    assert_schedule_daemon_supervisor_spawns_external_daemon
    assert_bin_schedule_list_lists_configured_schedules
    assert_bin_hq_schedule_daemon_runs_once
    assert_bin_hq_schedule_resume_updates_next_run
    assert_failed_scheduled_agent_pauses_and_notifies
    puts "scheduler_test: ok"
  end

  def assert_schedule_registry_validates_scope_and_prompt_paths
    Dir.mktmpdir("hq-scheduler-registry-test") do |dir|
      registry, schedule_path = write_registry_and_schedule(dir, <<~YAML)
        schedules:
          - key: weekday
            cron: "0 9 * * 1-5"
            target:
              type: agent
              project_key: web
              message: "Run maintenance."
      YAML
      schedules = HQ::ScheduleRegistry.new(path: schedule_path, projects: registry.projects.map { |config| HQ::AppProject.new(config) }).schedules
      assert(schedules.length == 1, "expected valid inline schedule")

      _registry, invalid_target = write_registry_and_schedule(dir, <<~YAML, suffix: "invalid-target")
        schedules:
          - key: bad
            cron: "0 9 * * *"
            target:
              type: shell
              project_key: web
              message: "Nope."
      YAML
      assert_raises(HQ::ScheduleRegistry::Error, "expected shell target to be rejected") do
        HQ::ScheduleRegistry.new(path: invalid_target, projects: registry.projects.map { |config| HQ::AppProject.new(config) }).schedules
      end

      _registry, invalid_file = write_registry_and_schedule(dir, <<~YAML, suffix: "invalid-file")
        schedules:
          - key: bad-file
            cron: "0 9 * * *"
            target:
              type: agent
              project_key: web
              message_file: "../secret.md"
      YAML
      assert_raises(HQ::ScheduleRegistry::Error, "expected message_file outside schedules/ to be rejected") do
        HQ::ScheduleRegistry.new(path: invalid_file, projects: registry.projects.map { |config| HQ::AppProject.new(config) }).schedules
      end
    end
  end

  def assert_schedule_store_tracks_daemon_state
    with_temp_runtime do
      store = HQ::ScheduleStore.new
      now = Time.now
      store.record_daemon_start!(pid: Process.pid, mode: "daemon", interval: 30, dry_run: false, now: now)
      state = store.daemon_state(now: now + 1)
      assert(state.status == "running", "expected live daemon state")
      assert(state.pid == Process.pid, "expected daemon pid")

      store.record_daemon_tick_finished!({ started: 1, skipped: 0 }, now: now + 2)
      state = store.daemon_state(now: now + 3)
      assert(state.last_result[:started] == 1 || state.last_result["started"] == 1,
             "expected daemon last result")

      state = store.daemon_state(now: now + 300)
      assert(state.status == "stale", "expected stale daemon state")

      store.record_daemon_stop!(signal: "TERM", now: now + 301)
      state = store.daemon_state(now: now + 302)
      assert(state.status == "stopped", "expected stopped daemon state")

      store = HQ::ScheduleStore.new(process_detector: -> { 1234 })
      state = store.daemon_state(now: now + 303)
      assert(state.status == "untracked", "expected running process without heartbeat to be untracked")
      assert(state.pid == 1234, "expected detected daemon pid")
    end
  end

  def assert_scheduler_run_creates_fresh_agent_and_archives_previous
    with_temp_runtime do |dir|
      registry, schedule_path = write_registry_and_schedule(dir, <<~YAML)
        schedules:
          - key: weekday
            cron: "0 9 * * 1-5"
            target:
              type: agent
              project_key: web
              name: Weekday maintenance
              message: "Run maintenance."
      YAML
      scheduler = build_scheduler(registry, schedule_path)
      first = scheduler.run_now("weekday")
      raise "expected schedule to start, got #{first.inspect}" unless first[:agent]

      first_agent = first.fetch(:agent)

      agents = read_agents
      assert(agents.map(&:key) == [first_agent.key], "expected first scheduled agent to be active")
      assert(File.exist?(first_agent.raw_log_path), "expected stubbed agent start to write a raw log")
      memory = File.read(first_agent.memory_path)
      assert(memory.include?("Run maintenance."), "expected scheduled message to be written to agent memory")
      assert(memory.include?(HQ::ManagedAgent::FINAL_OUTPUT_CHECKLIST),
             "expected scheduled message to include the final attachment checklist")

      second = scheduler.run_now("weekday")
      second_agent = second.fetch(:agent)
      agents = read_agents
      assert(agents.map(&:key) == [second_agent.key], "expected second run to replace active scheduled agent")
      archived = Dir.glob(File.join(HQ::AGENT_ARCHIVE_DIR, "**", File.basename(first_agent.raw_log_path)))
      assert(!archived.empty?, "expected previous scheduled agent logs to be archived")
    end
  end

  def assert_scheduler_skips_interactive_scheduled_agent_without_archiving
    with_temp_runtime do |dir|
      registry, schedule_path = write_registry_and_schedule(dir, <<~YAML)
        schedules:
          - key: weekday
            cron: "0 9 * * 1-5"
            target:
              type: agent
              project_key: web
              name: Weekday maintenance
              message: "Run maintenance."
      YAML
      scheduler = build_scheduler(registry, schedule_path)
      first = scheduler.run_now("weekday")
      first_agent = first.fetch(:agent)

      store = HQ::ScheduleStore.new
      states = store.load
      state = states.fetch("weekday")
      state.last_status = "succeeded"
      state.last_finished_at = first_agent.finished_at
      state.next_due_at = Time.now - 60
      store.save(states)

      first_agent.add_user_message!("Can you explain that result?")
      projects = registry.projects.map { |config| HQ::AppProject.new(config) }
      HQ::AgentStore.new(projects).save([first_agent])
      loaded = HQ::AgentStore.new(projects).load
      assert(loaded.length == 1, "expected interactive agent to reload from agent store")
      assert(!loaded.first.latest_user_message_after(
        state.last_started_at,
        ignored_metadata: { "scheduled_prompt" => true },
        inclusive: true
      ).to_s.empty?,
             "expected interactive user message after schedule start")

      result = scheduler.tick
      assert(result[:skipped] == 1, "expected interactive scheduled session to skip the due run, got #{result.inspect}")
      state = store.load.fetch("weekday")
      assert(state.last_status == "skipped", "expected schedule state to record a skipped run")
      assert(state.last_error == "interactive", "expected skip reason to be interactive")
      agents = read_agents
      assert(agents.map(&:key) == [first_agent.key], "expected interactive scheduled agent to remain active")
      assert(File.exist?(first_agent.raw_log_path), "expected interactive scheduled logs to remain in place")
    end
  end

  def assert_bin_schedule_list_lists_configured_schedules
    Dir.mktmpdir("hq-scheduler-bin-test") do |dir|
      registry, schedule_path = write_registry_and_schedule(dir, <<~YAML)
        schedules:
          - key: weekday
            cron: "0 9 * * 1-5"
            target:
              type: agent
              project_key: web
              message: "Run maintenance."
      YAML
      env = {
        "TYCHO_CONFIG_PATH" => registry.path,
        "TYCHO_SCHEDULES_PATH" => schedule_path,
        "TYCHO_SCHEDULES_STATE_PATH" => File.join(dir, "schedules.json"),
        "TYCHO_LOGS_ROOT" => File.join(dir, "logs")
      }
      out, err, status = Open3.capture3(env, RbConfig.ruby, "bin/schedule", "list", chdir: ROOT)
      assert(status.success?, "expected bin/schedule list to succeed, err: #{err}")
      assert(out.include?("weekday"), "expected bin/schedule list output to include schedule key")
      assert(out.include?("web"), "expected bin/schedule list output to include project key")
    end
  end

  def assert_bin_hq_schedule_daemon_runs_once
    Dir.mktmpdir("hq-scheduler-daemon-bin-test") do |dir|
      registry, schedule_path = write_registry_and_schedule(dir, <<~YAML)
        schedules:
          - key: weekday
            cron: "0 9 * * 1-5"
            target:
              type: agent
              project_key: web
              message: "Run maintenance."
      YAML
      env = {
        "TYCHO_CONFIG_PATH" => registry.path,
        "TYCHO_SCHEDULES_PATH" => schedule_path,
        "TYCHO_SCHEDULES_STATE_PATH" => File.join(dir, "schedules.json"),
        "TYCHO_SCHEDULER_DAEMON_PATH" => File.join(dir, "scheduler_daemon.json"),
        "TYCHO_LOGS_ROOT" => File.join(dir, "logs")
      }
      out, err, status = Open3.capture3(env, RbConfig.ruby, "bin/tycho", "schedule", "daemon", "--once", "--dry-run", chdir: ROOT)
      assert(status.success?, "expected bin/tycho schedule daemon --once --dry-run to succeed, err: #{err}")
      assert(out.include?("schedules: started="), "expected scheduler daemon output, got #{out.inspect}")
    end
  end

  def assert_bin_hq_schedule_resume_updates_next_run
    Dir.mktmpdir("hq-scheduler-resume-bin-test") do |dir|
      registry, schedule_path = write_registry_and_schedule(dir, <<~YAML)
        schedules:
          - key: weekday
            cron: "* * * * *"
            target:
              type: agent
              project_key: web
              message: "Run maintenance."
      YAML
      state_path = File.join(dir, "schedules.json")
      File.write(state_path, JSON.pretty_generate([
        {
          "key" => "weekday",
          "enabled" => false,
          "paused_at" => "2026-01-01T00:00:00+00:00",
          "next_due_at" => "2000-01-01T00:00:00+00:00"
        }
      ]))
      env = {
        "TYCHO_CONFIG_PATH" => registry.path,
        "TYCHO_SCHEDULES_PATH" => schedule_path,
        "TYCHO_SCHEDULES_STATE_PATH" => state_path,
        "TYCHO_LOGS_ROOT" => File.join(dir, "logs")
      }
      command_started_at = Time.now
      out, err, status = Open3.capture3(env, RbConfig.ruby, "bin/tycho", "schedule", "resume", "weekday", chdir: ROOT)
      assert(status.success?, "expected bin/tycho schedule resume to succeed, err: #{err}")
      assert(out.include?("Resumed weekday."), "expected resume output, got #{out.inspect}")

      state = JSON.parse(File.read(state_path)).first
      next_due_at = Time.parse(state.fetch("next_due_at"))
      assert(state.fetch("enabled") == true, "expected resume to enable the schedule")
      assert(!state.key?("paused_at"), "expected resume to clear paused_at")
      assert(next_due_at > command_started_at,
             "expected resume to recompute next_due_at, got #{next_due_at.iso8601}")
    end
  end

  def assert_failed_scheduled_agent_pauses_and_notifies
    with_temp_runtime do |dir|
      registry, schedule_path = write_registry_and_schedule(dir, <<~YAML)
        schedules:
          - key: weekday
            cron: "0 9 * * 1-5"
            target:
              type: agent
              project_key: web
              message: "Run maintenance."
      YAML
      projects = registry.projects.map { |config| HQ::AppProject.new(config) }
      failed = HQ::ManagedAgent.new(
        key: "web-agent-1",
        name: "Failed schedule",
        project_key: "web",
        template_key: "scheduled",
        workspace: File.join(dir, "workspace"),
        prompt: "",
        started_at: Time.now - 120,
        finished_at: Time.now - 60,
        last_exit_code: 1,
        runs: [
          HQ::ManagedAgent::AgentRun.new(
            started_at: Time.now - 120,
            finished_at: Time.now - 60,
            exit_code: 1,
            status: "failed",
            log_path: File.join(HQ::AGENT_LOGS_DIR, "failed.raw.log"),
            command: "test"
          )
        ]
      )
      HQ::AgentStore.new(projects).save([failed])

      store = HQ::ScheduleStore.new
      store.save(
        "weekday" => HQ::ScheduleState.new(
          key: "weekday",
          enabled: true,
          last_status: "started",
          last_target_kind: "agent",
          last_target_key: failed.key,
          next_due_at: Time.now + 3600
        )
      )
      notifier = FakeNotifier.new
      scheduler = build_scheduler(registry, schedule_path, web_push_notifier: notifier)
      scheduler.tick
      state = store.load.fetch("weekday")

      assert(state.paused?, "expected failed scheduled agent to pause the schedule")
      assert(state.last_status == "failed", "expected schedule state to record failed status")
      assert(notifier.payloads.any? { |payload| payload[:title] == "Schedule failed" },
             "expected failure to send a web push payload")
    end
  end

  def assert_schedule_daemon_supervisor_spawns_external_daemon
    with_temp_runtime do |dir|
      spawned = []
      detached = []
      killed = []
      alive = true
      supervisor = HQ::ScheduleDaemonSupervisor.new(
        log_path: File.join(dir, "scheduler_daemon.log"),
        spawner: lambda do |*args, **opts|
          spawned << [args, opts]
          12_345
        end,
        detacher: ->(pid) { detached << pid },
        killer: ->(signal, pid) { killed << [signal, pid]; alive = false },
        liveness: ->(_pid) { alive },
        sleeper: ->(_seconds) {}
      )

      started = supervisor.start!(interval: 17, dry_run: true)
      command = spawned.fetch(0).fetch(0)
      opts = spawned.fetch(0).fetch(1)
      assert(started.fetch(:pid) == 12_345, "expected supervisor to report spawned daemon pid")
      assert(command.include?("schedule") && command.include?("daemon"),
             "expected supervisor to spawn the scheduler daemon command, got #{command.inspect}")
      assert(command.include?("--interval") && command.include?("17") && command.include?("--dry-run"),
             "expected supervisor to pass daemon options, got #{command.inspect}")
      assert(opts[:pgroup] == true, "expected scheduler daemon to run in its own process group")
      assert(detached == [12_345], "expected supervisor to detach the daemon")
      assert(File.exist?(File.join(dir, "scheduler_daemon.log")), "expected daemon log file to be created")

      store = HQ::ScheduleStore.new
      store.record_daemon_start!(pid: 12_345, mode: "daemon", interval: 17, dry_run: true)
      stopped = supervisor.stop!
      assert(stopped.fetch(:stopped), "expected supervisor stop to observe exited daemon")
      assert(killed == [["TERM", 12_345]], "expected supervisor to terminate the daemon pid")
    end
  end

  def build_scheduler(registry, schedule_path, web_push_notifier: FakeNotifier.new)
    projects = registry.projects.map { |config| HQ::AppProject.new(config) }
    HQ::Scheduler.new(
      registry: registry,
      schedule_registry: HQ::ScheduleRegistry.new(path: schedule_path, projects: projects),
      store: HQ::ScheduleStore.new,
      push_notification_store: HQ::PushNotificationStore.new,
      web_push_notifier: web_push_notifier
    )
  end

  def write_registry_and_schedule(dir, schedule_content, suffix: "main")
    config_dir = File.join(dir, "config")
    FileUtils.mkdir_p(config_dir)
    workspace = File.join(dir, "workspace")
    FileUtils.mkdir_p(workspace)
    config_path = File.join(config_dir, "hq.yml")
    File.write(config_path, <<~YAML)
      projects:
        - key: web
          name: Web
          path: #{workspace}
          apps: false
          agent: codex
    YAML
    schedule_path = File.join(config_dir, "schedules-#{suffix}.yml")
    File.write(schedule_path, schedule_content)
    [HQ::Registry.new(path: config_path), schedule_path]
  end

  def with_temp_runtime
    Dir.mktmpdir("hq-scheduler-runtime-test") do |dir|
      old_agents_file = replace_constant(HQ, :AGENTS_FILE, File.join(dir, "managed_agents.json"))
      old_logs_dir = replace_constant(HQ, :AGENT_LOGS_DIR, File.join(dir, "agents"))
      old_archive_dir = replace_constant(HQ, :AGENT_ARCHIVE_DIR, File.join(dir, "agents", "archive"))
      old_state_file = replace_constant(HQ, :SCHEDULES_STATE_FILE, File.join(dir, "schedules.json"))
      old_daemon_file = replace_constant(HQ, :SCHEDULER_DAEMON_FILE, File.join(dir, "scheduler_daemon.json"))
      old_push_file = replace_constant(HQ, :PUSH_NOTIFICATIONS_FILE, File.join(dir, "push_notifications.json"))
      old_process_detection = ENV["TYCHO_DISABLE_SCHEDULE_PROCESS_DETECTION"]
      ENV["TYCHO_DISABLE_SCHEDULE_PROCESS_DETECTION"] = "1"

      FileUtils.mkdir_p(HQ::AGENT_LOGS_DIR)
      FileUtils.mkdir_p(HQ::AGENT_ARCHIVE_DIR)
      yield dir
    ensure
      replace_constant(HQ, :AGENTS_FILE, old_agents_file) if old_agents_file
      replace_constant(HQ, :AGENT_LOGS_DIR, old_logs_dir) if old_logs_dir
      replace_constant(HQ, :AGENT_ARCHIVE_DIR, old_archive_dir) if old_archive_dir
      replace_constant(HQ, :SCHEDULES_STATE_FILE, old_state_file) if old_state_file
      replace_constant(HQ, :SCHEDULER_DAEMON_FILE, old_daemon_file) if old_daemon_file
      replace_constant(HQ, :PUSH_NOTIFICATIONS_FILE, old_push_file) if old_push_file
      if old_process_detection
        ENV["TYCHO_DISABLE_SCHEDULE_PROCESS_DETECTION"] = old_process_detection
      else
        ENV.delete("TYCHO_DISABLE_SCHEDULE_PROCESS_DETECTION")
      end
    end
  end

  def read_agents
    JSON.parse(File.read(HQ::AGENTS_FILE)).map { |hash| HQ::ManagedAgent.from_hash(hash) }
  end

  def with_stubbed_agent_start
    original = HQ::ManagedAgent.instance_method(:start!)
    HQ::ManagedAgent.define_method(:start!) do
      now = Time.now
      FileUtils.mkdir_p(File.dirname(raw_log_path))
      File.write(raw_log_path, "scheduled test run\n")
      @started_at = now
      @finished_at = now
      @last_exit_code = 0
      @pid = nil
      @runs << HQ::ManagedAgent::AgentRun.new(
        started_at: now,
        finished_at: now,
        exit_code: 0,
        status: "succeeded",
        log_path: raw_log_path,
        command: "stubbed"
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
  rescue error_class
    true
  else
    raise message
  end

  class FakeNotifier
    attr_reader :payloads

    def initialize
      @payloads = []
    end

    def send_payload!(payload, **)
      @payloads << payload
      { sent: 1, failed: 0, attempted: 1 }
    end
  end
end

SchedulerTest.run! if $PROGRAM_NAME == __FILE__
