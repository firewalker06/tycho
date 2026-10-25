# frozen_string_literal: true

require "json"
require "tmpdir"

require_relative "../lib/hq/domain/agent_store"
require_relative "../lib/hq/domain/agent_list_cache"

module AgentMarkReadTest
  module_function

  def run!
    with_store do |store, cache, path|
      agents = %w[a b].map { |key| build_agent(key, unread: true) }
      store.save(agents)
      store.load_with_poll_events(after_load: ->(loaded) { cache.replace!(loaded, signature: cache.signature) })

      writes = 0
      hooks = { before_write: -> { writes += 1 } }
      assert(store.mark_read!("missing").nil?, "expected nil for an unknown key")
      assert(store.mark_read!("a", **hooks) == true, "expected a write when unread changes")
      assert(read_flags(path) == { "a" => false, "b" => true }, "expected only agent a to change on disk")
      mtime = File.stat(path).mtime
      bytes = File.binread(path)
      assert(store.mark_read!("a", **hooks) == false && writes == 1, "expected no write when already read")
      assert(File.binread(path) == bytes && File.stat(path).mtime == mtime, "expected the file to stay untouched")

      # Concurrent calls: one write for the flag, no lost updates to the other agent.
      concurrent_writes = Queue.new
      results = %w[b b b b].map do |key|
        Thread.new { store.mark_read!(key, before_write: -> { concurrent_writes << 1 }) }
      end.map(&:value)
      assert(results.count(true) == 1 && results.count(false) == 3, "expected exactly one concurrent writer")
      assert(concurrent_writes.size == 1, "expected one write across concurrent calls")
      assert(read_flags(path) == { "a" => false, "b" => false }, "expected both agents read")
    end

    with_store do |store, cache, path|
      store.save([build_agent("a", unread: true), build_agent("b", unread: true)])
      store.load_with_poll_events(after_load: ->(loaded) { cache.replace!(loaded, signature: cache.signature) })
      assert(cache.fetch("a").unread?, "expected cached unread agent")
      before = nil
      store.mark_read!("a", before_write: -> { before = cache.signature },
                            after_write: ->(r) { cache.update_record!(r, before_signature: before, signature: cache.signature) })
      assert(!cache.fetch("a").unread?, "expected the cache to see the update without a reload")
      assert(cache.fetch("b").unread?, "expected other cached agents to stay unchanged")

      # A snapshot that was already stale before the write is dropped, not patched.
      File.write(path, File.read(path) + " ")
      cache.update_record!({ "key" => "b", "unread" => false }, before_signature: [0], signature: cache.signature)
      assert(cache.fetch("b").nil?, "expected a mismatched snapshot to be invalidated")
    end
    puts "agent_mark_read_test passed"
  end

  def read_flags(path)
    JSON.parse(File.read(path)).to_h { |record| [record["key"], record["unread"]] }
  end

  def with_store
    Dir.mktmpdir("tycho-mark-read-") do |dir|
      path = File.join(dir, "managed_agents.json")
      old = HQ::AGENTS_FILE
      HQ.send(:remove_const, :AGENTS_FILE)
      HQ.const_set(:AGENTS_FILE, path)
      begin
        recovery = HQ::AgentStoreRecovery.new(store_path: path)
        yield HQ::AgentStore.new([], recovery:), HQ::AgentListCache.new(path:, max_age: 60), path
      ensure
        HQ.send(:remove_const, :AGENTS_FILE)
        HQ.const_set(:AGENTS_FILE, old)
      end
    end
  end

  def build_agent(key, unread:)
    HQ::ManagedAgent.new(key:, name: key, project_key: "demo", template_key: "custom",
                         workspace: Dir.tmpdir, prompt: "Prompt", agent: "claude", unread:)
  end

  def assert(condition, message)
    raise message unless condition
  end
end

AgentMarkReadTest.run!
