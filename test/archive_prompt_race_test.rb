# frozen_string_literal: true

require "fileutils"
require "stringio"
require "timeout"
require "tmpdir"

require_relative "../lib/hq/cli_command"
require_relative "../lib/hq/remote_server"

module ArchivePromptRaceTest
  module_function

  def run!
    with_runtime do |dir, registry|
      assert_api_active_uuid_replay(dir, registry)
      assert_api_acceptance_wins_then_uuid_replay_aborts(dir, registry)
      assert_api_archive_wins(dir, registry)
      assert_cli_acceptance_wins(dir, registry)
      assert_cli_archive_wins(dir, registry)
    end
    puts "archive_prompt_race_test: ok"
  end

  def assert_api_active_uuid_replay(_dir, registry)
    service = HQ::RemoteService.new(registry:)
    key = create_agent(service, "API active replay")
    request = {
      "prompt" => "API active replay",
      "client_request_id" => "550e8400-e29b-41d4-a716-446655440000"
    }

    first = service.submit_prompt(key, request)
    replay = service.submit_prompt(key, request)
    conversation = service.conversation(key)
    assert(first[:replayed] == false && replay[:replayed] == true,
           "expected an active UUID replay to report its replay state")
    assert(conversation.count { |event| event[:content] == "API active replay" } == 1,
           "expected an active UUID replay to keep one prompt event")
  end

  def assert_api_acceptance_wins_then_uuid_replay_aborts(_dir, registry)
    service = HQ::RemoteService.new(registry:)
    key = create_agent(service, "API accept first")
    store = service.instance_variable_get(:@agent_store)
    entered = Queue.new
    release = Queue.new
    gate_after(store, :accept_active_prompt_unlocked!, entered, release)
    request_id = "550e8400-e29b-41d4-a716-446655440001"

    submit = Thread.new do
      service.submit_prompt(key, "prompt" => "API accepted before archive", "client_request_id" => request_id)
    end
    await(entered)
    archive = Thread.new { service.archive_agent(key) }
    release << true
    result = thread_value(submit)
    thread_value(archive)
    assert(result[:replayed] == false, "expected the first API request to be accepted once")

    2.times do
      error = assert_remote_error do
        service.submit_prompt(key, "prompt" => "API accepted before archive", "client_request_id" => request_id)
      end
      assert(error.status == 409 && error.message == HQ::ManagedAgent::ARCHIVE_ABORT_MESSAGE,
             "expected replay after archive to return the exact abort")
    end
    conversation = service.conversation(key)
    assert(conversation.count { |event| event[:content] == "API accepted before archive" } == 1,
           "expected UUID replay to keep one API prompt event")
    assert(conversation.count { |event| event[:content] == HQ::ManagedAgent::ARCHIVE_ABORT_MESSAGE } == 1,
           "expected UUID replay to keep one durable API abort event")
  end

  def assert_api_archive_wins(_dir, registry)
    service = HQ::RemoteService.new(registry:)
    key = create_agent(service, "API archive first")
    store = service.instance_variable_get(:@agent_store)
    entered = Queue.new
    release = Queue.new
    gate_before(store, :accept_or_abort_prompt!, entered, release)

    submit = Thread.new do
      assert_remote_error { service.submit_prompt(key, "prompt" => "API arrived after archive") }
    end
    await(entered)
    service.archive_agent(key)
    release << true
    error = thread_value(submit)
    assert(error.status == 409 && error.message == HQ::ManagedAgent::ARCHIVE_ABORT_MESSAGE,
           "expected archive-first API request to return the exact abort")
    conversation = service.conversation(key)
    assert(conversation.count { |event| event[:content] == "API arrived after archive" } == 1 &&
           conversation.count { |event| event[:content] == HQ::ManagedAgent::ARCHIVE_ABORT_MESSAGE } == 1,
           "expected archive-first API evidence exactly once")
  end

  def assert_cli_acceptance_wins(_dir, registry)
    store, agent = stored_agent(registry, "cli-accept-first")
    entered = Queue.new
    release = Queue.new
    gate_after(store, :accept_active_prompt_unlocked!, entered, release)

    with_cli_store(store) do
      out = StringIO.new
      err = StringIO.new
      send_thread = Thread.new do
        HQ::CLICommand.send_agent_message(agent.key, "CLI accepted before archive", { delay: 60 }, out:, err:)
      end
      await(entered)
      archive = Thread.new { HQ::AgentStore.new(projects(registry)).archive_agent!(agent.key) }
      release << true
      assert(thread_value(send_thread).zero?, "expected acceptance-first CLI send to succeed")
      thread_value(archive)
      events = archived_events(agent.key)
      assert(events.count { |event| event["content"] == "CLI accepted before archive" } == 1 &&
             events.count { |event| event["content"] == HQ::ManagedAgent::ARCHIVE_ABORT_MESSAGE } == 1,
             "expected acceptance-first CLI queue evidence and exact abort")
    end
  end

  def assert_cli_archive_wins(_dir, registry)
    store, agent = stored_agent(registry, "cli-archive-first")
    entered = Queue.new
    release = Queue.new
    gate_before(store, :accept_or_abort_prompt!, entered, release)

    with_cli_store(store) do
      out = StringIO.new
      err = StringIO.new
      send_thread = Thread.new do
        code = HQ::CLICommand.send_agent_message(agent.key, "CLI arrived after archive", { delay: 60 }, out:, err:)
        [code, err.string]
      end
      await(entered)
      HQ::AgentStore.new(projects(registry)).archive_agent!(agent.key)
      release << true
      code, error_text = thread_value(send_thread)
      assert(code == 1 && error_text.include?(HQ::ManagedAgent::ARCHIVE_ABORT_MESSAGE),
             "expected archive-first CLI send to return the exact abort")
      events = archived_events(agent.key)
      assert(events.count { |event| event["content"] == "CLI arrived after archive" } == 1 &&
             events.count { |event| event["content"] == HQ::ManagedAgent::ARCHIVE_ABORT_MESSAGE } == 1,
             "expected archive-first CLI evidence exactly once")
    end
  end

  def gate_before(store, method_name, entered, release)
    original = store.method(method_name)
    fired = false
    mutex = Mutex.new
    store.define_singleton_method(method_name) do |*args, **kwargs, &block|
      first = mutex.synchronize do
        next false if fired

        fired = true
      end
      if first
        entered << true
        release.pop
      end
      original.call(*args, **kwargs, &block)
    end
  end

  def gate_after(store, method_name, entered, release)
    original = store.method(method_name)
    fired = false
    mutex = Mutex.new
    store.define_singleton_method(method_name) do |*args, **kwargs, &block|
      result = original.call(*args, **kwargs, &block)
      first = mutex.synchronize do
        next false if fired

        fired = true
      end
      if first
        entered << true
        release.pop
      end
      result
    end
  end

  def with_cli_store(store)
    original = HQ::CLICommand.method(:agent_store_for_all)
    HQ::CLICommand.define_singleton_method(:agent_store_for_all) { store }
    yield
  ensure
    HQ::CLICommand.define_singleton_method(:agent_store_for_all, original)
  end

  def create_agent(service, name)
    service.create_agent(
      "project_key" => "web", "template_key" => "custom", "name" => name,
      "prompt" => "Race fixture", "agent" => "codex"
    ).fetch(:key)
  end

  def stored_agent(registry, key)
    project = projects(registry).fetch(0)
    agent = HQ::ManagedAgent.new(
      key:, name: key, project_key: project.key, template_key: "custom",
      workspace: project.path, prompt: "Race fixture", agent: "codex"
    )
    store = HQ::AgentStore.new(projects(registry))
    store.save(store.load.unshift(agent))
    [store, agent]
  end

  def archived_events(key)
    archived = HQ::AgentArchiveStore.new(root: HQ::AGENT_ARCHIVE_DIR).find(key)&.agent
    raise "expected archived fixture #{key}" unless archived

    HQ::AgentMemory.new(archived).events
  end

  def projects(registry)
    registry.projects.map { |config| HQ::Project.new(config) }
  end

  def assert_remote_error
    yield
    raise "expected Remote API error"
  rescue HQ::RemoteServer::Error => e
    e
  end

  def await(queue)
    Timeout.timeout(5) { queue.pop }
  end

  def thread_value(thread)
    Timeout.timeout(5) do
      thread.join
      thread.value
    end
  end

  def with_runtime
    Dir.mktmpdir("tycho-archive-prompt-race") do |dir|
      constants = {
        AGENTS_FILE: File.join(dir, "managed_agents.json"),
        DELEGATIONS_FILE: File.join(dir, "agent_delegations.json"),
        SERVER_IDENTITY_FILE: File.join(dir, "server_identity.json"),
        USAGE_METRICS_FILE: File.join(dir, "usage_metrics.json"),
        SCHEDULES_FILE: File.join(dir, "schedules.yml"),
        SCHEDULES_STATE_FILE: File.join(dir, "schedule_states.json"),
        AGENT_LOGS_DIR: File.join(dir, "agents"),
        AGENT_ARCHIVE_DIR: File.join(dir, "agents", "archive"),
        PROJECT_LOGS_DIR: File.join(dir, "projects"),
        PROJECT_ARCHIVE_DIR: File.join(dir, "projects", "archive")
      }
      old = constants.to_h { |name, value| [name, replace_constant(HQ, name, value)] }
      FileUtils.mkdir_p([HQ::AGENT_LOGS_DIR, HQ::AGENT_ARCHIVE_DIR, HQ::PROJECT_LOGS_DIR, HQ::PROJECT_ARCHIVE_DIR])
      workspace = File.join(dir, "workspace")
      FileUtils.mkdir_p(workspace)
      config = File.join(dir, "hq.yml")
      prompts = File.join(dir, "system_prompts.yml")
      File.write(config, <<~YAML)
        projects:
          - key: web
            name: Web
            path: #{workspace}
            agent: codex
      YAML
      File.write(prompts, "custom: Work safely.\n")
      yield dir, HQ::Registry.new(path: config, system_prompts_path: prompts)
    ensure
      old&.each { |name, value| replace_constant(HQ, name, value) }
    end
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
end

ArchivePromptRaceTest.run! if $PROGRAM_NAME == __FILE__
