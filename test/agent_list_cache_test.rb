# frozen_string_literal: true

require "tmpdir"
require_relative "../lib/hq/domain/constants"
require_relative "../lib/hq/domain/managed_agent"
require_relative "../lib/hq/domain/agent_list_cache"

module AgentListCacheTest
  module_function

  def run!
    Dir.mktmpdir("tycho-agent-list-cache-") do |dir|
      path = File.join(dir, "managed_agents.json")
      cache = HQ::AgentListCache.new(path:, max_age: 60)
      assert(cache.fetch("a").nil?, "expected an empty cache to miss")

      File.write(path, "[]")
      agent = HQ::ManagedAgent.new(key: "a", project_key: "p", name: "Alpha", template_key: "t", workspace: dir, prompt: "x")
      cache.replace!([agent], signature: cache.signature)
      copy = cache.fetch("a")
      assert(copy.is_a?(HQ::ManagedAgent) && copy.name == "Alpha", "expected a cached agent copy")
      copy.instance_variable_set(:@name, "Changed")
      assert(cache.fetch("a").name == "Alpha", "expected request mutations not to leak into the snapshot")
      assert(cache.fetch("missing") == :unknown, "expected a valid snapshot to answer unknown keys")

      shared = cache.readonly_agents
      assert(shared.map(&:key) == ["a"] && shared.equal?(cache.readonly_agents), "expected one shared read-only list")

      File.write(path, "[{}]")
      assert(cache.fetch("a").nil?, "expected a changed agents file to invalidate the snapshot")

      stale = cache.signature
      File.write(path, "[]  ")
      cache.replace!([agent], signature: stale)
      assert(cache.fetch("a").nil?, "expected a signature taken before a write to stay stale")
      expired = HQ::AgentListCache.new(path:, max_age: 0)
      expired.replace!([agent], signature: expired.signature)
      assert(expired.fetch("a").nil?, "expected a zero max age to disable reuse")
    end
    puts "agent_list_cache_test passed"
  end

  def assert(condition, message)
    raise message unless condition
  end
end

AgentListCacheTest.run!
