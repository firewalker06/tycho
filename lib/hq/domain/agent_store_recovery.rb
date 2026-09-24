# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require "securerandom"
require "time"

require_relative "file_store"

module HQ
  class AgentStoreRecovery
    DEFAULT_RETENTION_DAYS = 30
    STATE_VERSION = 1

    attr_reader :store_path

    def initialize(store_path:, now: -> { Time.now }, retention_days: nil)
      @store_path = store_path
      @now = now
      configured_retention = retention_days || HQ.env_present(
        "AGENT_STORE_BACKUP_RETENTION_DAYS", DEFAULT_RETENTION_DAYS
      )
      @retention_days = normalize_retention(configured_retention)
    end

    def prepare(records, current_records:, allow_retired_keys: false)
      candidate = validate_records!(records)
      current = validate_records!(current_records)
      state = read_state
      previous_sessions = state.fetch("sessions", {}).merge(session_index(current))
      current_keys = current.map { |record| record.fetch("key") }
      candidate_keys = candidate.map { |record| record.fetch("key") }
      retired = Array(state["retired_keys"]) - current_keys
      resurrected = candidate_keys & retired
      unless resurrected.empty? || allow_retired_keys
        raise IOError, "managed-agent store would resurrect archived keys: #{resurrected.sort.join(", ")}"
      end

      recovered = []
      candidate.each do |record|
        next unless record["session_id"].to_s.empty?

        identity = previous_sessions[record.fetch("key")]
        next unless identity.is_a?(Hash) && !identity["session_id"].to_s.empty?

        record["session_id"] = identity.fetch("session_id")
        record["session_bootstrapped"] = identity["session_bootstrapped"] != false
        recovered << record.fetch("key")
      end
      warn_regressions(current, candidate, recovered:)
      candidate
    end

    def reconcile_loaded(records)
      candidate = validate_records!(records)
      state = read_state
      sessions = state.fetch("sessions", {})
      retired = Array(state["retired_keys"])
      recovered = []
      removed = []

      candidate.reject! do |record|
        next false unless retired.include?(record.fetch("key"))

        removed << record.fetch("key")
        true
      end
      candidate.each do |record|
        next unless record["session_id"].to_s.empty?

        identity = sessions[record.fetch("key")]
        next unless identity.is_a?(Hash) && !identity["session_id"].to_s.empty?

        record["session_id"] = identity.fetch("session_id")
        record["session_bootstrapped"] = identity["session_bootstrapped"] != false
        recovered << record.fetch("key")
      end
      log_warning("Removed unexpectedly restored archived agents: #{removed.sort.join(", ")}") unless removed.empty?
      log_warning("Recovered missing native session identity for: #{recovered.sort.join(", ")}") unless recovered.empty?
      previous_count = state["record_count"]
      if previous_count.is_a?(Integer)
        difference = (candidate.length - previous_count).abs
        baseline = [previous_count, 1].max
        if difference >= 5 && difference.fdiv(baseline) >= 0.5
          log_warning("Large managed-agent record-count change on load: #{previous_count} -> #{candidate.length}")
        end
      end
      [candidate, !removed.empty? || !recovered.empty?]
    end

    def after_save(records, allow_retired_keys: false)
      valid = validate_records!(records)
      state_saved = begin
        update_state(valid, allow_retired_keys:)
        true
      rescue StandardError => e
        log_warning("Managed-agent recovery metadata failed without changing the active store: #{e.class} - #{e.message}")
        false
      end
      backup_saved = begin
        create_daily_backup(valid)
        true
      rescue StandardError => e
        log_warning("Managed-agent backup failed without changing the active store or prior backups: #{e.class} - #{e.message}")
        false
      end
      state_saved && backup_saved
    end

    def backups
      Dir.glob(File.join(backup_dir, "*.metadata.json")).filter_map do |metadata_path|
        metadata = FileStore.read_json(metadata_path, fallback: nil)
        next unless metadata.is_a?(Hash)

        data_path = metadata_path.sub(/\.metadata\.json\z/, ".json")
        next unless valid_snapshot?(data_path, metadata)

        metadata.merge("path" => data_path, "metadata_path" => metadata_path)
      end.sort_by { |entry| entry.fetch("created_at", "") }.reverse
    end

    def restore!(snapshot_path)
      data_path = File.expand_path(snapshot_path.to_s)
      metadata_path = data_path.sub(/\.json\z/, ".metadata.json")
      raise ArgumentError, "Backup must be a .json snapshot" if metadata_path == data_path

      metadata = FileStore.read_json(metadata_path, fallback: nil)
      raise IOError, "Missing or invalid backup metadata: #{metadata_path}" unless metadata.is_a?(Hash)
      raise IOError, "Backup checksum or contents are invalid: #{data_path}" unless valid_snapshot?(data_path, metadata)

      records = validate_records!(JSON.parse(FileStore.read_text(data_path)))
      emergency_path = emergency_backup!
      begin
        FileStore.write_json(store_path, records)
        installed = validate_records!(JSON.parse(FileStore.read_text(store_path)))
        raise IOError, "restored store did not match the selected snapshot" unless installed == records
      rescue StandardError
        emergency = validate_records!(JSON.parse(FileStore.read_text(emergency_path))) if emergency_path
        FileStore.write_json(store_path, emergency) if emergency
        raise
      end
      begin
        update_state(records, allow_retired_keys: true)
      rescue StandardError => e
        log_warning("Restored the managed-agent store but could not update recovery metadata: #{e.class} - #{e.message}")
      end
      records
    end

    private

    def create_daily_backup(records)
      today = @now.call.utc.strftime("%Y-%m-%d")
      return false if backups.any? { |entry| entry["kind"] == "daily" && entry["backup_date"] == today }

      timestamp = @now.call.utc.strftime("%Y%m%dT%H%M%S%6NZ")
      data_path = File.join(backup_dir, "managed_agents-#{timestamp}-#{SecureRandom.hex(4)}.json")
      metadata_path = data_path.sub(/\.json\z/, ".metadata.json")
      FileUtils.mkdir_p(backup_dir)
      FileStore.write_json(data_path, records, backup: false)
      bytes = File.binread(data_path)
      parsed = validate_records!(JSON.parse(bytes))
      metadata = snapshot_metadata(data_path, bytes, parsed, backup_date: today)
      FileStore.write_json(metadata_path, metadata, backup: false)
      raise IOError, "new backup did not validate" unless valid_snapshot?(data_path, metadata)

      rotate_backups!
      true
    rescue StandardError
      FileUtils.rm_f(data_path) if data_path
      FileUtils.rm_f(metadata_path) if metadata_path
      raise
    end

    def emergency_backup!
      return nil unless File.exist?(store_path)

      records = validate_records!(JSON.parse(FileStore.read_text(store_path)))
      timestamp = @now.call.utc.strftime("%Y%m%dT%H%M%S%6NZ")
      data_path = File.join(backup_dir, "pre-restore-#{timestamp}-#{SecureRandom.hex(4)}.json")
      metadata_path = data_path.sub(/\.json\z/, ".metadata.json")
      FileUtils.mkdir_p(backup_dir)
      FileStore.write_json(data_path, records, backup: false)
      bytes = File.binread(data_path)
      metadata = snapshot_metadata(
        data_path,
        bytes,
        records,
        backup_date: @now.call.utc.strftime("%Y-%m-%d"),
        kind: "pre_restore"
      )
      FileStore.write_json(metadata_path, metadata, backup: false)
      raise IOError, "pre-restore backup did not validate" unless valid_snapshot?(data_path, metadata)
      data_path
    rescue StandardError
      FileUtils.rm_f(data_path) if data_path
      FileUtils.rm_f(metadata_path) if metadata_path
      raise
    end

    def rotate_backups!
      cutoff = @now.call.utc - (@retention_days * 86_400)
      valid = backups
      keep = valid.first
      valid.each do |entry|
        next if entry.equal?(keep)
        next unless Time.iso8601(entry.fetch("created_at")) < cutoff

        FileUtils.rm_f(entry.fetch("path"))
        FileUtils.rm_f(entry.fetch("metadata_path"))
      end
    end

    def valid_snapshot?(path, metadata)
      return false unless File.file?(path)

      bytes = File.binread(path)
      return false unless Digest::SHA256.hexdigest(bytes) == metadata["sha256"]
      return false unless bytes.bytesize == metadata["byte_size"]

      records = validate_records!(JSON.parse(bytes))
      records.length == metadata["record_count"] && session_index(records).length == metadata["session_count"]
    rescue StandardError
      false
    end

    def snapshot_metadata(path, bytes, records, backup_date:, kind: "daily")
      {
        "schema_version" => STATE_VERSION,
        "kind" => kind,
        "created_at" => @now.call.utc.iso8601(6),
        "backup_date" => backup_date,
        "source" => File.basename(store_path),
        "snapshot" => File.basename(path),
        "sha256" => Digest::SHA256.hexdigest(bytes),
        "byte_size" => bytes.bytesize,
        "record_count" => records.length,
        "session_count" => session_index(records).length
      }
    end

    def update_state(records, allow_retired_keys:)
      state = read_state
      previous_keys = Array(state["active_keys"])
      active_keys = records.map { |record| record.fetch("key") }
      retired = Array(state["retired_keys"]) | (previous_keys - active_keys)
      retired -= active_keys if allow_retired_keys
      value = {
        "schema_version" => STATE_VERSION,
        "updated_at" => @now.call.utc.iso8601(6),
        "record_count" => records.length,
        "active_keys" => active_keys,
        "retired_keys" => retired,
        "sessions" => state.fetch("sessions", {}).merge(session_index(records))
      }
      FileStore.write_json(state_path, value)
    end

    def read_state
      value = FileStore.read_json(state_path, fallback: {})
      value.is_a?(Hash) ? value : {}
    end

    def session_index(records)
      records.each_with_object({}) do |record, result|
        session_id = record["session_id"].to_s.strip
        next if session_id.empty?

        result[record.fetch("key")] = {
          "session_id" => session_id,
          "session_bootstrapped" => record["session_bootstrapped"] != false
        }
      end
    end

    def validate_records!(records)
      raise IOError, "managed-agent store must contain a JSON array" unless records.is_a?(Array)

      copy = records.map do |record|
        raise IOError, "managed-agent record must be an object" unless record.is_a?(Hash)

        normalized = record.transform_keys(&:to_s)
        raise IOError, "managed-agent record is missing key" if normalized["key"].to_s.strip.empty?

        normalized
      end
      keys = copy.map { |record| record.fetch("key") }
      raise IOError, "managed-agent store contains duplicate keys" unless keys.uniq.length == keys.length

      copy
    end

    def warn_regressions(current, candidate, recovered:)
      log_warning("Prevented native session identity loss for: #{recovered.sort.join(", ")}") unless recovered.empty?
      difference = (candidate.length - current.length).abs
      baseline = [current.length, 1].max
      if difference >= 5 && difference.fdiv(baseline) >= 0.5
        log_warning("Large managed-agent record-count change: #{current.length} -> #{candidate.length}")
      end
    end

    def normalize_retention(value)
      days = Integer(value)
      days.positive? ? days : DEFAULT_RETENTION_DAYS
    rescue ArgumentError, TypeError
      DEFAULT_RETENTION_DAYS
    end

    def backup_dir
      "#{store_path}.backups"
    end

    def state_path
      "#{store_path}.recovery.json"
    end

    def log_warning(message)
      HQ.logger.warn("AgentStoreRecovery") { message }
    rescue StandardError
      nil
    end
  end
end
