# frozen_string_literal: true

require "json"
require "fileutils"
require "open3"
require "rbconfig"
require "tmpdir"

require_relative "../lib/hq/domain/agent_store"
require_relative "../lib/hq/domain/agent_archive_store"
require_relative "../lib/hq/remote_server"

module ArchiveDelegationCallbacksTest
  module_function

  Snapshot = Struct.new(:unused) do
    def remove!(*) = true
  end

  def run!
    Dir.mktmpdir("tycho-archive-callbacks") do |dir|
      with_paths(dir) do
        assert_ordinary_queue_is_protected(dir)
        assert_callback_queue_archives_with_history(dir)
        assert_mixed_queue_is_protected(dir)
        assert_cli_reports_preserved_callbacks(dir)
        assert_remote_conflict_is_not_internal_server_error(dir)
      end
    end
    assert_remote_ui_contract
    puts "archive_delegation_callbacks_test: ok"
  end

  def assert_ordinary_queue_is_protected(dir)
    store, agent = stored_agent(dir, "ordinary")
    agent.enqueue_prompt!(prompt: "Keep this user request", source: "user")
    store.save([agent])

    error = capture_error { store.archive_agent!(agent.key) }
    assert(error.message.include?("protect queued user work") && error.message.include?("1 ordinary queued prompt"),
           "expected an actionable ordinary-work conflict")
    current, = store.load_with_poll_events(process_delegations: false, dispatch_prompt_queues: false)
    assert(current.any? { |item| item.key == agent.key }, "expected ordinary queued work to remain active")
  end

  def assert_callback_queue_archives_with_history(dir)
    store, agent = stored_agent(dir, "callbacks")
    2.times do |index|
      agent.enqueue_prompt!(
        prompt: "Delegated callback #{index + 1}", id: "callback-#{index + 1}", source: "delegation_callback",
        message_metadata: { "delegation_callback" => true, "delegation_reports" => [] }
      )
    end
    agent.claim_pending_prompts!
    agent.fail_prompt_queue_dispatch!("Queued work is paused after Stop. Choose Retry queue to continue without losing it.")
    store.save([agent])

    archive_path = store.archive_agent!(agent.key)
    current, = store.load_with_poll_events(process_delegations: false, dispatch_prompt_queues: false)
    assert(current.none? { |item| item.key == agent.key }, "expected callback-only agent to leave active state")
    archived = HQ::AgentArchiveStore.new(root: HQ::AGENT_ARCHIVE_DIR).find(agent.key)&.agent
    assert(archived && archived.queued_prompts.empty?, "expected callbacks to leave the executable queue")
    events = File.readlines(archived.memory_path, chomp: true).reject(&:empty?).map { |line| JSON.parse(line) }
    preserved = events.select { |event| event.dig("metadata", "archived_without_run") == true }
    assert(preserved.map { |event| event["content"] } == ["Delegated callback 1", "Delegated callback 2"],
           "expected full callback messages in read-only archived history")
    assert(File.directory?(archive_path), "expected archive artifacts to be durable")
  end

  def assert_mixed_queue_is_protected(dir)
    store, agent = stored_agent(dir, "mixed")
    agent.enqueue_prompt!(prompt: "Delegated result", source: "delegation_callback")
    agent.enqueue_prompt!(prompt: "User follow-up", source: "user")
    store.save([agent])

    error = capture_error { store.archive_agent!(agent.key) }
    assert(error.message.include?("mixed queue (1 ordinary, 1 delegation callbacks)"),
           "expected a specific mixed-queue conflict")
    current, = store.load_with_poll_events(process_delegations: false, dispatch_prompt_queues: false)
    restored = current.find { |item| item.key == agent.key }
    assert(restored&.queued_prompts&.length == 2, "expected every mixed-queue entry to remain durable")
  end

  def assert_remote_conflict_is_not_internal_server_error(dir)
    _store, agent = stored_agent(dir, "remote")
    agent.enqueue_prompt!(prompt: "User request", source: "user")
    fake_store = Object.new
    fake_store.define_singleton_method(:archive_agent!) { |_key| raise ArgumentError, "Archive blocked to protect queued user work" }
    service = HQ::RemoteService.allocate
    service.instance_variable_set(:@agent_store, fake_store)
    service.instance_variable_set(:@agent_activity_snapshot, Snapshot.new)
    service.define_singleton_method(:find_agent!) { |_key| agent }
    service.define_singleton_method(:reject_personal_assistant_control!) { |_target| nil }

    error = capture_error { service.archive_agent(agent.key) }
    assert(error.is_a?(HQ::RemoteServer::Error) && error.status == 409,
           "expected peer archive conflicts to map to HTTP 409")
  end

  def assert_cli_reports_preserved_callbacks(dir)
    store, agent = stored_agent(dir, "cli-callbacks")
    agent.enqueue_prompt!(prompt: "CLI delegated result", source: "delegation_callback")
    agent.fail_prompt_queue_dispatch!("Paused after Stop")
    store.save([agent])
    config_path = File.join(dir, "hq.yml")
    prompts_path = File.join(dir, "system_prompts.yml")
    schedules_path = File.join(dir, "schedules.yml")
    File.write(config_path, "projects: []\n")
    File.write(prompts_path, "{}\n")
    env = {
      "TYCHO_HOME" => File.join(dir, "home"),
      "TYCHO_CONFIG_PATH" => config_path,
      "TYCHO_SYSTEM_PROMPTS_PATH" => prompts_path,
      "TYCHO_LOGS_ROOT" => File.dirname(HQ::AGENTS_FILE),
      "TYCHO_SCHEDULES_PATH" => schedules_path
    }
    executable = File.expand_path("../bin/tycho", __dir__)
    stdout, stderr, status = Open3.capture3(env, RbConfig.ruby, executable, "agent", "archive", agent.key)
    assert(status.success? && stderr.empty? && stdout.include?("Preserved 1 unrun delegation callback"),
           "expected local CLI callback archive evidence: #{stderr}")
  end

  def assert_remote_ui_contract
    source = File.read(File.expand_path("../lib/hq/remote_ui/assets/app.js", __dir__))
    required = [
      "Archive with callback history",
      "data-confirm=\"Archive with",
      'entry.source === "delegation_callback"'
    ]
    missing = required.reject { |text| source.include?(text) }
    assert(missing.empty?, "missing callback archive UI contracts: #{missing.join(", ")}")
  end

  def stored_agent(dir, suffix)
    workspace = File.join(dir, "workspace")
    FileUtils.mkdir_p(workspace)
    agent = HQ::ManagedAgent.new(
      key: "agent-#{suffix}", name: suffix.capitalize, project_key: "demo", template_key: "custom",
      workspace:, prompt: "Prompt", log_path: File.join(HQ::AGENT_LOGS_DIR, "agent-#{suffix}.raw.log")
    )
    store = HQ::AgentStore.new([])
    store.save([agent])
    [store, agent]
  end

  def with_paths(dir)
    logs = File.join(dir, "logs")
    replacements = {
      AGENTS_FILE: File.join(logs, "managed_agents.json"),
      AGENT_LOGS_DIR: File.join(logs, "agents"),
      AGENT_ARCHIVE_DIR: File.join(logs, "agents", "archive"),
      DELEGATIONS_FILE: File.join(logs, "agent_delegations.json"),
      SERVER_IDENTITY_FILE: File.join(dir, "server_identity.json"),
      SCHEDULES_FILE: File.join(dir, "schedules.yml"),
      SCHEDULES_STATE_FILE: File.join(logs, "schedules.json")
    }
    old = replacements.to_h { |name, value| [name, replace_constant(name, value)] }
    yield
  ensure
    old&.each { |name, value| replace_constant(name, value) }
  end

  def replace_constant(name, value)
    old = HQ.const_get(name)
    HQ.send(:remove_const, name)
    HQ.const_set(name, value)
    old
  end

  def capture_error
    yield
    raise "expected failure"
  rescue StandardError => e
    e
  end

  def assert(condition, message)
    raise message unless condition
  end
end

ArchiveDelegationCallbacksTest.run! if $PROGRAM_NAME == __FILE__
