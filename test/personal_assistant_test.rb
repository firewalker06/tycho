# frozen_string_literal: true

require "fileutils"
require "json"
require "tmpdir"

require_relative "../lib/hq/remote_server"

class PersonalAssistantTest
  class Clock
    attr_accessor :now

    def initialize(now) = @now = now
    def call = @now
  end

  FakeStore = Struct.new(:agents, :starts, :fail_start, keyword_init: true) do
    def load = agents

    def mutate
      yield agents, []
    end

    def create_personal_assistant!(agent)
      raise "already active" if agents.any?(&:personal_assistant?)

      agents.unshift(agent)
      agent
    end

    def archive_personal_assistant!(key)
      agents.reject! { |agent| agent.key == key }
    end

    def start_agent!(key)
      self.starts = starts.to_i + 1
      raise "start failed" if fail_start

      agent = agents.find { |candidate| candidate.key == key }
      agent.instance_variable_set(:@fake_running, true)
      agent.define_singleton_method(:running?) { @fake_running == true }
      agent
    end

    def finish!(key, handoff: nil)
      agent = agents.find { |candidate| candidate.key == key }
      agent.instance_variable_set(:@fake_running, false)
      agent.structured_result = { "memory_handoff" => handoff } if handoff
      agent
    end
  end

  def self.run
    Dir.mktmpdir do |dir|
      registry = registry(dir)
      clock = Clock.new(Time.utc(2026, 3, 8, 15, 0, 0))
      store = FakeStore.new(agents: [], starts: 0)
      archive_attempts = 0
      lifecycle = HQ::PersonalAssistantLifecycle.new(
        registry:, agent_store: store, clock:, state_path: File.join(dir, "state.json"),
        archiver: lambda { |agent|
          archive_attempts += 1
          store.agents.delete(agent)
        }
      )

      assert_raises { lifecycle.setup!("model" => "gpt-5.6-sol", "reasoning_effort" => "medium", "timezone" => "Asia/Jakarta") }
      lifecycle.setup!("confirmed" => true, "model" => "gpt-5.6-sol", "reasoning_effort" => "medium", "timezone" => "Asia/Jakarta")
      first = lifecycle.open!
      assert(first[:state] == "active" && first[:active_key], "expected configured daily session")
      assert(first.dig(:agent, "prompt").include?("Tycho Personal Assistant"), "expected fixed introduction before any model run")
      assert(HQ::ManagedAgent.from_hash(first.fetch(:agent)).personal_assistant?, "expected protected daily role")
      assert(lifecycle.open![:active_key] == first[:active_key], "expected lazy open to avoid overlap")

      # Keep the configured timezone on the active session. A setup change cannot
      # force an early rollover for a conversation that already started.
      registry.update_personal_assistant!(registry.personal_assistant.merge("timezone" => "UTC"))
      assert(lifecycle.status[:state] == "active", "expected active timezone to be stable")
      registry.update_personal_assistant!(registry.personal_assistant.merge("timezone" => "Asia/Jakarta"))

      agent = store.agents.fetch(0)
      agent.instance_variable_set(:@session_id, "native-session-1")
      clock.now = Time.utc(2026, 3, 8, 17, 1, 0)
      agent.instance_variable_set(:@fake_running, true)
      agent.define_singleton_method(:running?) { @fake_running == true }
      assert(lifecycle.reconcile[:state] == "closing", "expected running work to delay midnight handoff")
      assert(store.starts.zero?, "expected no summary while active work is running")

      store.finish!(agent.key)
      assert(lifecycle.reconcile[:state] == "summarizing", "expected exactly one internal summary turn")
      assert(store.starts == 1, "expected summary dispatch once")
      internal = agent.messages.select { |message| message.metadata&.fetch("personal_assistant_summary", false) }
      assert(internal.length == 1, "expected one durable internal summary message")
      assert(agent.session_id == "native-session-1", "expected the native session to remain unchanged")

      store.finish!(agent.key, handoff: { "outcome" => "Completed day", "decisions" => ["Use Codex"], "continuing_context" => "Tomorrow", "references" => [] })
      completed = lifecycle.reconcile
      assert(completed[:state] == "dormant" && store.agents.empty?, "expected successful handoff then internal archive")
      handoff = JSON.parse(File.read(completed.fetch(:config) && Dir.glob(File.join(dir, "handoffs", "*.json")).fetch(0)))
      assert(handoff["summary"] == "Completed day" && handoff["open_items"].join.bytesize <= 7_200, "expected bounded successful handoff")
      assert(archive_attempts == 1, "expected exactly one archive")

      # Catch-up opens the new date only after the old session has been archived.
      next_day = lifecycle.open!
      assert(next_day[:active_date] == "2026-03-09" && next_day[:active_key] != first[:active_key], "expected offline date catch-up without overlap")
      second_agent = store.agents.fetch(0)
      clock.now = Time.utc(2026, 3, 9, 17, 1, 0)
      assert(lifecycle.reconcile[:state] == "summarizing", "expected second rollover without scheduler daemon")
      store.finish!(second_agent.key, handoff: { "outcome" => "Completed second day", "decisions" => [], "continuing_context" => "", "references" => [] })
      assert(lifecycle.reconcile[:state] == "dormant" && store.agents.empty?, "expected second full rollover to archive before another open")
      assert(archive_attempts == 2 && Dir.glob(File.join(dir, "handoffs", "*.json")).length == 2, "expected two bounded daily handoffs")

      assert_archive_retry_without_resummary(registry, dir)
      assert_start_failure_falls_back_once(registry, dir)
      assert_disabled_preserves_no_session(registry, dir)
      assert_dst_and_threaded_reconcile(registry, dir)
    end
    puts "personal_assistant_test: OK"
  end

  def self.assert_archive_retry_without_resummary(registry, dir)
    clock = Clock.new(Time.utc(2026, 3, 10, 15, 0, 0)); store = FakeStore.new(agents: [], starts: 0); attempts = 0
    lifecycle = HQ::PersonalAssistantLifecycle.new(registry:, agent_store: store, clock:, state_path: File.join(dir, "retry.json"), archiver: lambda { |agent|
      attempts += 1; raise "archive unavailable" if attempts == 1; store.agents.delete(agent)
    })
    opened = lifecycle.open!; agent = store.agents.fetch(0); clock.now += 7200
    lifecycle.reconcile; store.finish!(agent.key, handoff: { "outcome" => "handoff", "decisions" => [], "continuing_context" => "", "references" => [] })
    assert(lifecycle.reconcile[:state] == "archiving", "expected archive error to retain handoff")
    assert(lifecycle.reconcile[:state] == "dormant", "expected archive retry")
    assert(store.starts == 1 && attempts == 2 && opened[:active_key] != "", "expected retry without another summary")
  end

  def self.assert_start_failure_falls_back_once(registry, dir)
    clock = Clock.new(Time.utc(2026, 3, 11, 15, 0, 0)); store = FakeStore.new(agents: [], starts: 0, fail_start: true)
    lifecycle = HQ::PersonalAssistantLifecycle.new(registry:, agent_store: store, clock:, state_path: File.join(dir, "fallback.json"), archiver: ->(agent) { store.agents.delete(agent) })
    opened = lifecycle.open!; clock.now += 7200
    assert(lifecycle.reconcile[:state] == "archiving", "expected failed launch to record fallback handoff")
    assert(lifecycle.reconcile[:state] == "dormant", "expected fallback continuity after launch failure")
    agent = HQ::ManagedAgent.from_hash(opened.fetch(:agent))
    assert(store.starts == 1 && store.agents.empty? && agent.session_id == "", "expected at-most-once failed summary dispatch")
    handoff = JSON.parse(File.read(Dir.glob(File.join(dir, "handoffs", "*.json")).max))
    assert(handoff["summary"].include?("Fallback"), "expected fallback handoff")
  end

  def self.assert_disabled_preserves_no_session(registry, dir)
    registry.update_personal_assistant!(registry.personal_assistant.merge("enabled" => false))
    lifecycle = HQ::PersonalAssistantLifecycle.new(registry:, agent_store: FakeStore.new(agents: [], starts: 0), state_path: File.join(dir, "disabled.json"))
    assert(lifecycle.status[:state] == "unconfigured" && !lifecycle.status[:configured], "expected disabled feature to stay dormant")
    assert_raises { lifecycle.open! }
    registry.update_personal_assistant!(registry.personal_assistant.merge("enabled" => true))
  end

  def self.assert_dst_and_threaded_reconcile(registry, dir)
    clock = Clock.new(Time.utc(2026, 3, 8, 6, 59, 59)); store = FakeStore.new(agents: [], starts: 0)
    lifecycle = HQ::PersonalAssistantLifecycle.new(registry:, agent_store: store, clock:, state_path: File.join(dir, "threaded.json"), archiver: ->(agent) { store.agents.delete(agent) })
    assert(lifecycle.send(:local_date, clock.now, "America/New_York") == lifecycle.send(:local_date, clock.now + 1, "America/New_York"), "expected DST local date stability")
    lifecycle.open!; clock.now = Time.utc(2026, 3, 9, 0, 0, 1)
    threads = 4.times.map { Thread.new { lifecycle.reconcile } }; threads.each(&:join)
    assert(store.starts == 1, "expected locked reconcile to dispatch one summary")
  end

  def self.registry(dir)
    config = File.join(dir, "hq.yml"); prompts = File.join(dir, "prompts.yml")
    File.write(config, "---\nprojects: []\n"); File.write(prompts, "---\n")
    HQ::Registry.new(path: config, system_prompts_path: prompts)
  end

  def self.assert(condition, message)
    raise message unless condition
  end

  def self.assert_raises
    yield
    raise "expected failure"
  rescue ArgumentError
    true
  end
end

PersonalAssistantTest.run if $PROGRAM_NAME == __FILE__
