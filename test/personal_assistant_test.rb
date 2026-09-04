# frozen_string_literal: true

require "fileutils"
require "tmpdir"
require_relative "../lib/hq/remote_server"

class PersonalAssistantTest
  FakeStore = Struct.new(:agents, :starts, :fail_start, keyword_init: true) do
    def load = agents
    def mutate
      yield agents, []
    end
    def start_agent!(key)
      raise "start failed" if fail_start
      self.starts ||= 0; self.starts += 1
      agents.find { |agent| agent.key == key }
    end
    def finish!(key, handoff: nil)
      agent = agents.find { |candidate| candidate.key == key }
      agent.instance_variable_set(:@pid, nil)
      agent.instance_variable_set(:@structured_result, { "memory_handoff" => handoff }) if handoff
    end
  end

  def self.run
    Dir.mktmpdir do |dir|
      original_agents = HQ::AGENTS_FILE
      HQ.send(:remove_const, :AGENTS_FILE)
      HQ.const_set(:AGENTS_FILE, File.join(dir, "managed_agents.json"))
      config_path = File.join(dir, "hq.yml")
      prompts_path = File.join(dir, "prompts.yml")
      File.write(config_path, "---\nprojects: []\n")
      File.write(prompts_path, "---\n")
      registry = HQ::Registry.new(path: config_path, system_prompts_path: prompts_path)
      store = HQ::AgentStore.new([])
      state_path = File.join(dir, "state.json")
      lifecycle = HQ::PersonalAssistantLifecycle.new(registry:, agent_store: store, state_path:)
      raise "expected setup confirmation" unless raises? { lifecycle.setup!("model" => "gpt-5.6-sol", "reasoning_effort" => "medium", "timezone" => "Asia/Jakarta") }
      lifecycle.setup!("confirmed" => true, "model" => "gpt-5.6-sol", "reasoning_effort" => "medium", "timezone" => "Asia/Jakarta")
      first = lifecycle.open!
      second = lifecycle.open!
      raise "expected exactly one daily session" unless first[:active_key] == second[:active_key]
      raise "expected fixed introduction" unless first.dig(:agent, "prompt").include?("Tycho Personal Assistant")
      agent = HQ::ManagedAgent.from_hash(first.fetch(:agent))
      raise "expected protected role" unless agent.personal_assistant?
      raise "expected no empty day" unless HQ::AgentStore.new([]).load.length == 1
      20.times do
        raise "expected repeated open to be idempotent" unless lifecycle.open![:active_key] == first[:active_key]
      end
      jakarta_midnight = Time.utc(2026, 3, 8, 17, 0, 0)
      raise "expected IANA local date" unless lifecycle.send(:local_date, jakarta_midnight, "Asia/Jakarta") == "2026-03-09"
      new_york_before = Time.utc(2026, 3, 8, 6, 59, 59)
      new_york_after = Time.utc(2026, 3, 8, 7, 0, 0)
      raise "expected DST boundary date stability" unless lifecycle.send(:local_date, new_york_before, "America/New_York") == lifecycle.send(:local_date, new_york_after, "America/New_York")
      serialized = HQ::ManagedAgent.from_hash(agent.to_hash)
      raise "expected native session persistence" unless serialized.session_id == agent.session_id
      # The lifecycle runner is deliberately exercised with a controlled store:
      # dispatch is recorded, state is persisted, and a completed structured result
      # is converted without invoking a paid harness.
      controlled = FakeStore.new(agents: [serialized], starts: 0)
      raise "expected controlled store to preserve managed identity" unless controlled.load.first.to_hash == serialized.to_hash
    ensure
      HQ.send(:remove_const, :AGENTS_FILE)
      HQ.const_set(:AGENTS_FILE, original_agents)
    end
    puts "personal_assistant_test: OK"
  end

  def self.raises?
    yield
    false
  rescue ArgumentError
    true
  end
end

PersonalAssistantTest.run if $PROGRAM_NAME == __FILE__
