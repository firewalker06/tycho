# frozen_string_literal: true

require "tmpdir"
require_relative "../lib/hq/domain/agent_store"
require_relative "../lib/hq/domain/agent_list_cache"

module QueueStoreTest
  module_function

  def run!
    assert_lossless_migration
    assert_restart_boundaries
    assert_concurrent_mutations
    assert_failed_write_rollback
    assert_corrupt_store_fails_closed
    assert_stale_save_and_backup_are_rejected
    assert_legacy_empty_queue_placeholders
    puts "queue_store_test passed"
  end

  def with_store
    Dir.mktmpdir("tycho-central-queue-") do |dir|
      original = HQ::AGENTS_FILE
      HQ.send(:remove_const, :AGENTS_FILE)
      HQ.const_set(:AGENTS_FILE, File.join(dir, "managed_agents.json"))
      yield HQ::QueueStore.new, HQ::AgentStore.new([]), dir
    ensure
      HQ.send(:remove_const, :AGENTS_FILE)
      HQ.const_set(:AGENTS_FILE, original)
    end
  end

  def legacy_record
    {
      "key" => "migration-target", "name" => "Migration fixture", "project_key" => "fixture",
      "workspace" => Dir.tmpdir, "prompt" => "Fixture",
      "prompt_queue" => [
        { "id" => "later", "prompt" => "Future", "not_before" => "2099-01-01T00:00:00Z", "source" => "user" },
        { "id" => "report", "prompt" => "Report", "source" => "delegation_callback",
          "authority" => { "owner" => "parent", "generation" => 4 },
          "message_metadata" => { "delegation_reports" => [{ "id" => "report-id" }] } }
      ],
      "prompt_queue_claim" => { "id" => "claim", "entries" => [{ "id" => "claimed" }],
                                "claimed_at" => "2026-11-11T00:00:00Z", "state" => "prepared" },
      "prompt_queue_dispatch_error" => { "retryable" => true, "message" => "Fixture error" },
      "queue_work" => { "version" => 1, "batches" => [
        { "id" => "batch", "entries" => [{ "id" => "delivered" }], "delivery_count" => 1,
          "dispositions" => { "done" => { "outcome" => "completed" } }, "state" => "in_progress" }
      ] },
      "runs" => [{ "run_id" => "run", "metadata" => {
        "queue_delivery_staged" => { "queue_work" => { "batches" => [] }, "read_id" => "read" },
        "queue_delivery_rollback" => { "prompt_queue_claim" => { "id" => "claim" } },
        "native_start_acknowledged" => true
      } }]
    }
  end

  def assert_legacy_empty_queue_placeholders
    with_store do |queues, store, dir|
      agents = %w[idle pending claimed].map do |key|
        HQ::ManagedAgent.new(key:, name: key, project_key: "fixture", template_key: "custom",
                             workspace: dir, prompt: "Synthetic existing-store fixture")
      end
      agents[1].enqueue_prompt!(id: "pending-user", prompt: "Delayed instruction", not_before: Time.now + 3600)
      agents[1].enqueue_prompt!(id: "pending-report", prompt: "Delegated report", source: "delegation_callback",
                                authority: { "owner" => "parent", "generation" => 7, "relationship_id" => "fixture-edge" })
      agents[2].enqueue_prompt!(id: "claimed-entry", prompt: "Unresolved work")
      agents[2].claim_pending_prompts!
      original = agents.map { |agent| HQ::ManagedAgent.from_hash(agent.to_hash).to_hash }
      HQ::FileStore.write_json(HQ::AGENTS_FILE, original)
      HQ::FileStore.write_json(HQ::QueueStore.path, { "version" => 1, "agents" => agents.to_h { |agent| [agent.key, {}] } })
      before = [HQ::AGENTS_FILE, HQ::QueueStore.path].to_h { |path| [path, File.binread(path)] }

      snapshot, = store.read_snapshot
      assert(snapshot.map(&:key) == agents.map(&:key), "existing placeholders hid known agents")
      assert(snapshot.map(&:to_hash) == original, "read-only compatibility changed inline queue evidence")
      assert(before.all? { |path, bytes| File.binread(path) == bytes } && !File.exist?(HQ::QueueStore.journal_path),
             "read-only compatibility wrote or migrated existing data")

      # Migrate only this synthetic fixture. Never use operator data for this test.
      store.send(:with_exclusive_lock) { queues.write(original) }
      migrated = JSON.parse(File.read(HQ::AGENTS_FILE))
      assert(migrated.map { |record| queues.hydrate(record) } == original,
             "empty placeholders lost pending entries, claims, ownership, or unresolved batches")
      state = queues.read
      assert(state.fetch("migrations").fetch("pending").fetch("entry_ids") == %w[pending-user pending-report],
             "placeholder migration omitted the original identifiers")
      loaded, = store.load_with_poll_events(process_delegations: false, dispatch_prompt_queues: false)
      assert(loaded.map(&:key) == agents.map(&:key) && loaded.find { |agent| agent.key == "pending" }.prompt_queue.length == 2,
             "lifecycle lookup lost a known agent or its queued work after placeholder migration")
      assert(loaded.find { |agent| agent.key == "claimed" }.prompt_queue_claim.fetch("id") ==
             original[2].fetch("prompt_queue_claim").fetch("id"), "migration replaced an existing dispatch claim")
      state = queues.read

      bad = migrated.fetch(0).merge("queue_ref" => "empty", "key" => "empty", "queue_generation" => nil)
      HQ::FileStore.write_json(HQ::QueueStore.path, state.merge("agents" => state.fetch("agents").merge("empty" => {})))
      begin
        queues.hydrate(bad)
        raise "an authoritative reference to an empty queue was accepted"
      rescue IOError
        # A placeholder is safe only while agent records still contain the queue.
      end
      corrupt = state.merge("agents" => state.fetch("agents").merge("invalid" => { "prompt_queue" => [] }))
      HQ::FileStore.write_json(HQ::QueueStore.path, corrupt)
      begin
        queues.read
        raise "a non-empty queue without a generation was silently accepted"
      rescue IOError
        assert(JSON.parse(File.read(HQ::QueueStore.path)) == corrupt, "invalid queue state was repaired during a read")
      end
    end
  end

  def assert_lossless_migration
    with_store do |queues, _store, dir|
      original = legacy_record
      HQ::FileStore.write_json(HQ::AGENTS_FILE, [original])
      queues.write([original])
      persisted = JSON.parse(File.read(HQ::AGENTS_FILE)).fetch(0)
      assert((HQ::QueueStore::FIELDS & persisted.keys).empty?, "agent records retained queue authority")
      assert(persisted.dig("runs", 0, "metadata").keys == ["native_start_acknowledged"],
             "staged queue recovery state remained in agent runs")
      assert(queues.hydrate(persisted) == original, "migration changed queue bytes, order, or evidence")
      state = queues.read
      evidence = state.fetch("migrations").fetch(original.fetch("key"))
      assert(evidence.fetch("entry_ids") == %w[later report] && evidence.fetch("claim_id") == "claim" &&
             evidence.fetch("batch_ids") == ["batch"], "migration identifiers were not retained")
      queues.write([queues.hydrate(persisted)])
      repeated = queues.read
      repeated.fetch("agents").each_value { |queue| queue.delete("generation") }
      state.fetch("agents").each_value { |queue| queue.delete("generation") }
      assert(repeated == state, "repeated migration changed accepted work or migration evidence")
      archive = File.join(dir, "agent_manifest.json")
      queues.write([original], target: archive)
      queues.write([])
      assert(queues.hydrate(JSON.parse(File.read(archive))) == original,
             "removed active target lost archived completion evidence")
    end
  end

  def assert_restart_boundaries
    %i[journal queues agents].each do |boundary|
      with_store do |queues, store, _dir|
        old = legacy_record.merge("prompt_queue" => [])
        queues.write([old])
        expected = legacy_record
        pid = fork do
          original = HQ::FileStore.method(:write_json)
          HQ::FileStore.define_singleton_method(:write_json) do |path, value, **options|
            result = original.call(path, value, **options)
            stop = { journal: HQ::QueueStore.journal_path, queues: HQ::QueueStore.path,
                     agents: HQ::AGENTS_FILE }.fetch(boundary)
            Process.exit!(86) if path == stop
            result
          end
          queues.write([expected])
          Process.exit!(87)
        end
        _, status = Process.wait2(pid)
        assert(status.exitstatus == 86, "fixture did not crash at #{boundary}")
        # A read-only view can use the durable intent without completing it.
        assert(File.exist?(HQ::QueueStore.journal_path), "missing durable intent")
        store.send(:with_exclusive_lock) { nil }
        actual = JSON.parse(File.read(HQ::AGENTS_FILE)).map { |record| queues.hydrate(record) }
        assert(actual == [expected], "restart mixed agent and queue state at #{boundary}")
        assert(!File.exist?(HQ::QueueStore.journal_path) && !queues.recover!, "recovery was not idempotent")
      end
    end
  end

  def assert_concurrent_mutations
    with_store do |queues, store, dir|
      agent = HQ::ManagedAgent.new(key: "concurrent", name: "Fixture", project_key: "fixture",
                                   template_key: "custom", workspace: dir, prompt: "Fixture")
      store.save([agent])
      workers = 4.times.map do |index|
        fork do
          own_store = HQ::AgentStore.new([])
          own_store.send(:with_exclusive_lock) do
            records = JSON.parse(File.read(HQ::AGENTS_FILE))
            current = HQ::ManagedAgent.from_hash(records.fetch(0))
            current.enqueue_prompt!(id: "entry-#{index}", prompt: "Fixture #{index}", not_before: Time.now + 3600)
            own_store.save_unlocked([current])
          end
          Process.exit!(0)
        end
      end
      workers.each { |pid| assert(Process.wait2(pid).last.success?, "concurrent queue writer failed") }
      current = store.read_snapshot.first.fetch(0)
      assert(current.prompt_queue.map { |entry| entry["id"] }.sort == %w[entry-0 entry-1 entry-2 entry-3],
             "concurrent processes lost or duplicated entries")
      cache = HQ::AgentListCache.new(max_age: 60)
      cache.replace!([current], signature: cache.signature)
      state = queues.read
      state.fetch("agents").fetch("concurrent")["prompt_queue"].shift
      HQ::FileStore.write_json(HQ::QueueStore.path, state)
      assert(cache.fetch(current.key).nil?, "queue-only mutation did not invalidate read caches")
    end
  end

  def assert_failed_write_rollback
    with_store do |queues, _store, _dir|
      queues.write([legacy_record])
      paths = [HQ::AGENTS_FILE, *HQ::QueueStore.transaction_paths]
      before = paths.to_h { |path| [path, File.exist?(path) ? File.binread(path) : nil] }
      begin
        HQ::FileTransaction.run([HQ::AGENTS_FILE]) do
          queues.write([legacy_record.merge("prompt_queue" => [])])
          raise "synthetic rollback"
        end
      rescue RuntimeError => e
        raise unless e.message == "synthetic rollback"
      end
      after = paths.to_h { |path| [path, File.exist?(path) ? File.binread(path) : nil] }
      assert(before == after, "lifecycle rollback left a newer central queue or replayable journal")
    end
  end

  def assert_corrupt_store_fails_closed
    with_store do |queues, store, _dir|
      queues.write([legacy_record])
      queues.write([legacy_record.merge("prompt_queue" => [])])
      File.write(HQ::QueueStore.path, "invalid JSON")
      begin
        store.read_snapshot
        raise "corrupt queues were accepted"
      rescue IOError
        assert(File.read(HQ::QueueStore.path) == "invalid JSON", "snapshot restored stale queue claims")
      end
    end
  end

  def assert_stale_save_and_backup_are_rejected
    with_store do |queues, store, dir|
      agent = HQ::ManagedAgent.new(key: "stale", name: "Fixture", project_key: "fixture",
                                   template_key: "custom", workspace: dir, prompt: "Fixture")
      store.save([agent])
      stale = store.read_snapshot.first.fetch(0)
      backup = File.binread(HQ::AGENTS_FILE)
      agent.enqueue_prompt!(id: "new", prompt: "Keep this entry", not_before: Time.now + 3600)
      store.save([agent])
      begin
        store.save([stale])
        raise "stale save removed accepted queue work"
      rescue IOError
        assert(store.read_snapshot.first.first.prompt_queue.first["id"] == "new", "new entry was lost")
      end
      File.binwrite(HQ::AGENTS_FILE, backup)
      begin
        store.read_snapshot
        raise "stale backup was mixed with newer queue claims"
      rescue IOError
        assert(queues.read.dig("agents", "stale", "prompt_queue", 0, "id") == "new", "backup rewound queues")
      end
    end
  end

  def assert(condition, message)
    raise message unless condition
  end
end

QueueStoreTest.run!
