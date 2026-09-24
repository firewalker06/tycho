# frozen_string_literal: true

require "fileutils"
require "json"
require "tmpdir"

require_relative "../lib/hq/domain/agent_store"

module AgentStoreRecoveryTest
  module_function

  def run!
    assert_restart_and_legacy_migration_preserve_session_identity
    assert_recovery_ledger_repairs_session_loss_and_archived_key_reappearance
    assert_missing_native_identity_is_detected
    assert_daily_backup_rotation_and_failure_safety
    assert_validated_restore_and_corruption_rejection
    puts "agent_store_recovery_test: ok"
  end

  def assert_restart_and_legacy_migration_preserve_session_identity
    with_store do |store, _recovery, _clock, _dir|
      agent = build_agent("restart-agent", session_id: "native-restart", session_bootstrapped: false)
      store.save([agent])
      restarted = store.load.fetch(0)
      assert(restarted.session_id == "native-restart", "expected session ID to survive save and restart")
      assert(restarted.session_bootstrapped == false, "expected bootstrap state to survive save and restart")

      legacy = agent.to_hash
      legacy.delete("session_id")
      legacy.delete("session_bootstrapped")
      migrated = HQ::ManagedAgent.from_hash(legacy)
      assert(migrated.session_id == "native-restart", "expected migration to recover run-level session identity")
      assert(migrated.session_bootstrapped,
             "expected a completed Claude run to migrate as a bootstrapped session")
    end
  end

  def assert_recovery_ledger_repairs_session_loss_and_archived_key_reappearance
    with_store do |store, _recovery, _clock, dir|
      agent = build_agent("guarded-agent", session_id: "native-guarded")
      store.save([agent])
      broken = agent.to_hash
      broken.delete("session_id")
      broken.delete("session_bootstrapped")
      HQ::FileStore.write_json(File.join(dir, "managed_agents.json"), [broken])

      recovered = store.load.fetch(0)
      assert(recovered.session_id == "native-guarded", "expected last-known identity to repair a regressed store")
      assert(recovered.session_bootstrapped, "expected last-known bootstrap state to be repaired")

      store.save([])
      HQ::FileStore.write_json(File.join(dir, "managed_agents.json"), [agent.to_hash])
      assert(store.load.empty?, "expected an unexpectedly restored archived key to be removed")
    end
  end

  def assert_missing_native_identity_is_detected
    run = HQ::ManagedAgent::AgentRun.new(
      started_at: Time.utc(2026, 9, 20, 10),
      finished_at: Time.utc(2026, 9, 20, 11),
      status: "succeeded"
    )
    agent = HQ::ManagedAgent.new(
      key: "missing-session-agent",
      name: "Missing session",
      project_key: "demo",
      template_key: "custom",
      workspace: Dir.tmpdir,
      prompt: "Prompt",
      agent: "codex",
      runs: [run]
    )
    assert(agent.send(:missing_native_session_identity?),
           "expected completed native history without identity to require a fresh session")
  end

  def assert_daily_backup_rotation_and_failure_safety
    with_store(retention_days: 2) do |store, recovery, clock, dir|
      store.save([build_agent("day-one", session_id: "session-one")])
      first_backup = recovery.backups.fetch(0)
      assert(recovery.backups.length == 1, "expected one daily backup")

      clock.replace(Time.utc(2026, 9, 22, 8))
      store.save([build_agent("day-two", session_id: "session-two")])
      clock.replace(Time.utc(2026, 9, 25, 8))
      store.save([build_agent("day-four", session_id: "session-four")])
      daily = recovery.backups.select { |entry| entry["kind"] == "daily" }
      assert(daily.length == 1 && daily.fetch(0)["backup_date"] == "2026-09-25",
             "expected expired daily backups to rotate only after a valid replacement")

      retained_path = daily.fetch(0).fetch("path")
      recovery.define_singleton_method(:create_daily_backup) { |_records| raise IOError, "simulated backup failure" }
      clock.replace(Time.utc(2026, 9, 26, 8))
      replacement = build_agent("backup-failure", session_id: "session-safe")
      store.save([replacement])
      active = JSON.parse(File.read(File.join(dir, "managed_agents.json")))
      assert(active.fetch(0).fetch("key") == "backup-failure", "expected backup failure not to corrupt the active store")
      assert(File.exist?(retained_path), "expected backup failure not to remove the last known-good snapshot")
      assert(File.exist?(first_backup.fetch("metadata_path")) == false,
             "expected the expired first backup metadata to rotate")
    end
  end

  def assert_validated_restore_and_corruption_rejection
    with_store do |store, recovery, clock, dir|
      original = build_agent("restore-source", session_id: "restore-session", session_bootstrapped: false)
      store.save([original])
      snapshot = recovery.backups.fetch(0).fetch("path")

      clock.replace(Time.utc(2026, 9, 22, 9))
      store.save([build_agent("current-agent", session_id: "current-session")])
      restored = store.restore_backup!(snapshot)
      assert(restored.fetch(0).fetch("session_id") == "restore-session",
             "expected restore to retain native session identity")
      assert(restored.fetch(0).fetch("session_bootstrapped") == false,
             "expected restore to retain bootstrap state")
      emergency = Dir.glob(File.join(dir, "managed_agents.json.backups", "pre-restore-*.json"))
        .reject { |path| path.end_with?(".metadata.json") }
      assert(emergency.length == 1,
             "expected restore to retain an emergency snapshot")

      File.open(snapshot, "a") { |file| file.write("\ncorrupt") }
      before = File.binread(File.join(dir, "managed_agents.json"))
      begin
        store.restore_backup!(snapshot)
        raise "expected corrupt restore to fail"
      rescue IOError
        nil
      end
      assert(File.binread(File.join(dir, "managed_agents.json")) == before,
             "expected rejected restore to leave the active store unchanged")
    end
  end

  def with_store(retention_days: 30)
    Dir.mktmpdir("hq-agent-store-recovery-test") do |dir|
      path = File.join(dir, "managed_agents.json")
      clock = MutableClock.new(Time.utc(2026, 9, 21, 8))
      recovery = HQ::AgentStoreRecovery.new(store_path: path, now: -> { clock.time }, retention_days:)
      old_agents_file = replace_constant(HQ, :AGENTS_FILE, path)
      store = HQ::AgentStore.new([], recovery:)
      yield store, recovery, clock, dir
    ensure
      replace_constant(HQ, :AGENTS_FILE, old_agents_file) if old_agents_file
    end
  end

  def build_agent(key, session_id:, session_bootstrapped: true)
    run = HQ::ManagedAgent::AgentRun.new(
      started_at: Time.utc(2026, 9, 20, 10),
      finished_at: Time.utc(2026, 9, 20, 11),
      status: "succeeded",
      session_id:
    )
    HQ::ManagedAgent.new(
      key:,
      name: key,
      project_key: "demo",
      template_key: "custom",
      workspace: Dir.tmpdir,
      prompt: "Prompt",
      agent: "claude",
      runs: [run],
      session_id:,
      session_bootstrapped:
    )
  end

  def assert(condition, message)
    raise message unless condition
  end

  def replace_constant(mod, name, value)
    old = mod.const_get(name)
    mod.send(:remove_const, name)
    mod.const_set(name, value)
    old
  end

  class MutableClock
    attr_reader :time

    def initialize(time)
      @time = time
    end

    def replace(time)
      @time = time
    end
  end
end

AgentStoreRecoveryTest.run! if $PROGRAM_NAME == __FILE__
