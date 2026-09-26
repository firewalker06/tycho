# frozen_string_literal: true

require "fileutils"
require "json"
require "open3"
require "rbconfig"
require "tmpdir"

require_relative "../lib/hq/domain/agent_store"

module AgentStoreRecoveryTest
  module_function

  def run!
    assert_restart_and_legacy_migration_preserve_session_identity
    assert_recovery_ledger_repairs_session_loss_and_archived_key_reappearance
    assert_large_unapproved_record_reduction_is_rejected
    assert_stale_nonempty_identity_and_bootstrap_regressions_are_blocked
    assert_missing_native_identity_is_detected
    assert_daily_backup_rotation_and_failure_safety
    assert_snapshot_record_and_metadata_schemas
    assert_validated_restore_and_corruption_rejection
    assert_restore_rolls_back_store_and_state_when_state_replacement_fails
    assert_restore_rolls_back_corrupt_store_bytes_when_state_replacement_fails
    assert_cli_restore_preserves_malformed_active_store_for_forensics
    puts "agent_store_recovery_test: ok"
  end

  def assert_large_unapproved_record_reduction_is_rejected
    with_store do |store, _recovery, _clock, dir|
      agents = 18.times.map do |index|
        build_agent("bulk-guard-#{index}", session_id: "bulk-session-#{index}")
      end
      store.save(agents)
      before = File.binread(File.join(dir, "managed_agents.json"))

      begin
        store.save([agents.first])
        raise "expected a destructive bulk reduction to be rejected"
      rescue IOError => e
        assert(e.message.include?("suspicious managed-agent record-count reduction"),
               "expected an explicit bulk-reduction safety failure")
      end

      assert(File.binread(File.join(dir, "managed_agents.json")) == before,
             "expected a rejected bulk reduction to preserve the active store")
    end
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

  def assert_stale_nonempty_identity_and_bootstrap_regressions_are_blocked
    with_store do |store, _recovery, _clock, dir|
      current = build_agent("identity-guard", session_id: "new-session", session_bootstrapped: true)
      store.save([current])

      stale_id = build_agent("identity-guard", session_id: "old-session", session_bootstrapped: true)
      begin
        store.save([stale_id])
        raise "expected stale non-empty session ID to be rejected"
      rescue IOError => e
        assert(e.message.include?("would change native session ID"), "expected explicit session drift failure")
      end
      persisted = JSON.parse(File.read(File.join(dir, "managed_agents.json"))).fetch(0)
      assert(persisted.fetch("session_id") == "new-session", "expected rejected drift to preserve the current ID")

      stale_bootstrap = build_agent("identity-guard", session_id: "new-session", session_bootstrapped: false)
      store.save([stale_bootstrap])
      restarted = store.load.fetch(0)
      assert(restarted.session_id == "new-session", "expected matching identity to remain stable")
      assert(restarted.session_bootstrapped, "expected bootstrapped state to remain monotonically true")
    end
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

  def assert_snapshot_record_and_metadata_schemas
    with_store do |store, recovery, _clock, dir|
      store.save([build_agent("schema-source", session_id: "schema-session")])
      valid_path = recovery.backups.fetch(0).fetch("path")
      valid_records = JSON.parse(File.read(valid_path))
      backup_dir = File.join(dir, "managed_agents.json.backups")

      malformed_path = write_snapshot_fixture(
        backup_dir,
        "managed_agents-malformed-record.json",
        [{ "key" => "only-a-key" }]
      )
      assert(!recovery.backups.any? { |entry| entry["path"] == malformed_path },
             "expected checksum-consistent malformed records to be excluded from listing")
      assert_restore_rejected(store, malformed_path, "expected malformed record snapshot to be rejected")

      blank_log_path_records = valid_records.map(&:dup)
      blank_log_path_records.fetch(0)["log_path"] = "   "
      blank_log_path = write_snapshot_fixture(
        backup_dir,
        "managed_agents-blank-log-path.json",
        blank_log_path_records
      )
      assert(!recovery.backups.any? { |entry| entry["path"] == blank_log_path },
             "expected a checksum-consistent blank log_path snapshot to be excluded from listing")
      assert_restore_rejected(store, blank_log_path, "expected blank log_path snapshot to be rejected")

      mutations = {
        "version" => { "schema_version" => 2 },
        "kind" => { "kind" => "unknown" },
        "source" => { "source" => "other.json" },
        "snapshot" => { "snapshot" => "different.json" },
        "timestamp" => { "created_at" => "not-a-time" }
      }
      mutations.each do |label, overrides|
        path = write_snapshot_fixture(
          backup_dir,
          "managed_agents-invalid-#{label}.json",
          valid_records,
          metadata: overrides
        )
        assert(!recovery.backups.any? { |entry| entry["path"] == path },
               "expected invalid #{label} metadata to be excluded from listing")
        assert_restore_rejected(store, path, "expected invalid #{label} metadata to be rejected")
      end
    end
  end

  def assert_restore_rolls_back_store_and_state_when_state_replacement_fails
    with_store do |store, recovery, clock, dir|
      historical = build_agent("transactional-restore", session_id: "historical-session")
      store.save([historical])
      snapshot = recovery.backups.fetch(0).fetch("path")

      clock.replace(Time.utc(2026, 9, 22, 9))
      current = build_agent("transactional-restore", session_id: "current-session")
      store_path = File.join(dir, "managed_agents.json")
      state_path = "#{store_path}.recovery.json"
      current_records = [current.to_hash]
      HQ::FileStore.write_json(store_path, current_records)
      recovery.send(:update_state, current_records, allow_retired_keys: true, replace_sessions: true)
      before_store = File.binread(store_path)
      before_state = File.binread(state_path)
      original_update_state = recovery.method(:update_state)
      recovery.define_singleton_method(:update_state) do |records, allow_retired_keys:, replace_sessions: false|
        raise IOError, "simulated recovery-state replacement failure" if replace_sessions

        original_update_state.call(records, allow_retired_keys:, replace_sessions:)
      end

      begin
        store.restore_backup!(snapshot)
        raise "expected recovery-state replacement failure to fail restore"
      rescue IOError => e
        assert(e.message.include?("simulated recovery-state replacement failure"),
               "expected state replacement failure to propagate")
      end
      assert(File.binread(store_path) == before_store,
             "expected failed restore to roll back the active store")
      assert(File.binread(state_path) == before_state,
             "expected failed restore to roll back recovery state")

      reloaded = store.load.fetch(0)
      assert(reloaded.session_id == "current-session",
             "expected AgentStore reload after failed restore to retain current identity")
      persisted = JSON.parse(File.read(store_path)).fetch(0)
      ledger = JSON.parse(File.read(state_path)).fetch("sessions").fetch("transactional-restore")
      assert(persisted.fetch("session_id") == ledger.fetch("session_id") &&
             ledger.fetch("session_id") == "current-session",
             "expected active store and recovery state to remain consistent after rollback")
    end
  end

  def assert_restore_rolls_back_corrupt_store_bytes_when_state_replacement_fails
    with_store do |store, recovery, clock, dir|
      historical = build_agent("corrupt-transactional-restore", session_id: "historical-session")
      store.save([historical])
      snapshot = recovery.backups.fetch(0).fetch("path")

      clock.replace(Time.utc(2026, 9, 22, 9))
      current = build_agent("corrupt-transactional-restore", session_id: "current-session")
      store_path = File.join(dir, "managed_agents.json")
      state_path = "#{store_path}.recovery.json"
      recovery.send(:update_state, [current.to_hash], allow_retired_keys: true, replace_sessions: true)
      corrupt_bytes = "{broken\xFFactive".b
      File.binwrite(store_path, corrupt_bytes)
      before_state = File.binread(state_path)
      original_update_state = recovery.method(:update_state)
      recovery.define_singleton_method(:update_state) do |records, allow_retired_keys:, replace_sessions: false|
        raise IOError, "simulated corrupt-store recovery-state replacement failure" if replace_sessions

        original_update_state.call(records, allow_retired_keys:, replace_sessions:)
      end

      begin
        store.restore_backup!(snapshot)
        raise "expected corrupt-store recovery-state replacement failure to fail restore"
      rescue IOError => e
        assert(e.message.include?("simulated corrupt-store recovery-state replacement failure"),
               "expected corrupt-store state replacement failure to propagate")
      end
      assert(File.binread(store_path) == corrupt_bytes,
             "expected failed restore to recover the exact non-UTF-8 active-store bytes")
      assert(File.binread(state_path) == before_state,
             "expected failed restore to recover the exact recovery-state bytes")
      ledger = JSON.parse(File.read(state_path)).fetch("sessions").fetch("corrupt-transactional-restore")
      assert(ledger.fetch("session_id") == "current-session",
             "expected corrupt-store rollback to retain the pre-restore recovery identity")
    end
  end

  def assert_cli_restore_preserves_malformed_active_store_for_forensics
    Dir.mktmpdir("hq-agent-store-cli-recovery-test") do |dir|
      logs = File.join(dir, "logs")
      path = File.join(logs, "managed_agents.json")
      clock = MutableClock.new(Time.utc(2026, 9, 21, 8))
      recovery = HQ::AgentStoreRecovery.new(store_path: path, now: -> { clock.time })
      recovery.after_save([build_agent("cli-restore", session_id: "cli-session").to_hash])
      snapshot = recovery.backups.fetch(0).fetch("path")
      invalid_bytes = "{broken\xFFactive".b
      FileUtils.mkdir_p(logs)
      File.binwrite(path, invalid_bytes)
      config_path = File.join(dir, "hq.yml")
      prompts_path = File.join(dir, "system_prompts.yml")
      File.write(config_path, "projects: []\n")
      File.write(prompts_path, "--- {}\n")
      env = {
        "TYCHO_HOME" => File.join(dir, "home"),
        "TYCHO_LOGS_ROOT" => logs,
        "TYCHO_CONFIG_PATH" => config_path,
        "TYCHO_SYSTEM_PROMPTS_PATH" => prompts_path
      }
      executable = File.expand_path("../bin/tycho", __dir__)
      stdout, stderr, status = Open3.capture3(
        env, RbConfig.ruby, executable, "agent", "store", "restore", snapshot, "--json",
        chdir: File.expand_path("..", __dir__)
      )
      assert(status.success?, "expected CLI restore over malformed active JSON to succeed: #{stderr}")
      assert(JSON.parse(stdout).fetch("restored"), "expected CLI restore result")
      restored = JSON.parse(File.read(path)).fetch(0)
      assert(restored.fetch("session_id") == "cli-session", "expected CLI restore to install the valid snapshot")
      forensic = Dir.glob(File.join("#{path}.backups", "pre-restore-invalid-*.raw"))
      assert(forensic.length == 1, "expected one clearly marked forensic pre-restore artifact")
      assert(File.binread(forensic.fetch(0)) == invalid_bytes, "expected forensic artifact to preserve exact invalid bytes")
      forensic_metadata = JSON.parse(File.read("#{forensic.fetch(0)}.metadata.json"))
      assert(forensic_metadata.fetch("kind") == "forensic_pre_restore" &&
             forensic_metadata.fetch("content_valid") == false,
             "expected forensic metadata to identify invalid active content")
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

  def write_snapshot_fixture(dir, filename, records, metadata: {})
    path = File.join(dir, filename)
    FileUtils.mkdir_p(dir)
    HQ::FileStore.write_json(path, records, backup: false)
    bytes = File.binread(path)
    value = {
      "schema_version" => 1,
      "kind" => "daily",
      "created_at" => "2026-09-21T08:00:00.000000Z",
      "backup_date" => "2026-09-21",
      "source" => "managed_agents.json",
      "snapshot" => File.basename(path),
      "sha256" => Digest::SHA256.hexdigest(bytes),
      "byte_size" => bytes.bytesize,
      "record_count" => records.length,
      "session_count" => records.count { |record| !record["session_id"].to_s.empty? }
    }.merge(metadata)
    metadata_path = path.sub(/\.json\z/, ".metadata.json")
    HQ::FileStore.write_json(metadata_path, value, backup: false)
    path
  end

  def assert_restore_rejected(store, path, message)
    begin
      store.restore_backup!(path)
      raise message
    rescue IOError
      nil
    end
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
