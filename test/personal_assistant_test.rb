# frozen_string_literal: true

require "fileutils"
require "tmpdir"
require_relative "../lib/hq/remote_server"

class PersonalAssistantTest
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
