# frozen_string_literal: true

require "date"
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
    SNAPSHOT_SCHEMA_VERSION = 1
    RESTORABLE_SNAPSHOT_KINDS = %w[daily pre_restore].freeze
    FORENSIC_SNAPSHOT_KIND = "forensic_pre_restore"
    REQUIRED_RECORD_FIELDS = {
      "key" => String,
      "name" => String,
      "project_key" => String,
      "template_key" => String,
      "workspace" => String,
      "prompt" => String,
      "created_at" => String,
      "log_path" => String
    }.freeze
    OPTIONAL_RECORD_FIELDS = {
      "started_at" => [String, NilClass],
      "finished_at" => [String, NilClass],
      "pid" => [Integer, NilClass],
      "last_exit_code" => [Integer, NilClass],
      "runs" => Array,
      "stop_requested_at" => [String, NilClass],
      "sandbox_mode" => String,
      "agent" => String,
      "skills" => [Array, NilClass],
      "unread" => [TrueClass, FalseClass]
    }.freeze
    REQUIRED_RUN_FIELDS = {
      "started_at" => [String, NilClass],
      "finished_at" => [String, NilClass],
      "exit_code" => [Integer, NilClass],
      "status" => [String, NilClass],
      "log_path" => [String, NilClass],
      "command" => [String, NilClass]
    }.freeze

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
      ledger_sessions = normalized_sessions(state["sessions"])
      current_sessions = session_index(current)
      current_keys = current.map { |record| record.fetch("key") }
      candidate_keys = candidate.map { |record| record.fetch("key") }
      retired = Array(state["retired_keys"]) - current_keys
      resurrected = candidate_keys & retired
      unless resurrected.empty? || allow_retired_keys
        raise IOError, "managed-agent store would resurrect archived keys: #{resurrected.sort.join(", ")}"
      end

      recovered = []
      bootstrap_recovered = []
      candidate.each do |record|
        key = record.fetch("key")
        known = [current_sessions[key], ledger_sessions[key]].compact
        known_ids = known.map { |identity| identity.fetch("session_id") }.uniq
        candidate_id = record["session_id"].to_s.strip
        if !candidate_id.empty? && (known_ids - [candidate_id]).any?
          raise IOError,
                "managed-agent store would change native session ID for #{key}: " \
                "candidate=#{candidate_id.inspect}, known=#{known_ids.sort.join(", ")}"
        end
        if candidate_id.empty?
          if known_ids.length > 1
            raise IOError, "managed-agent recovery identities conflict for #{key}: #{known_ids.sort.join(", ")}"
          end
          next if known_ids.empty?

          record["session_id"] = known_ids.fetch(0)
          record["session_bootstrapped"] = known.any? { |identity| identity["session_bootstrapped"] == true }
          recovered << key
        elsif known.any? { |identity| identity["session_id"] == candidate_id && identity["session_bootstrapped"] == true } &&
              record["session_bootstrapped"] != true
          record["session_bootstrapped"] = true
          bootstrap_recovered << key
        end
      end
      warn_regressions(current, candidate, recovered:, bootstrap_recovered:)
      candidate
    end

    def reconcile_loaded(records)
      candidate = validate_records!(records)
      state = read_state
      sessions = normalized_sessions(state["sessions"])
      retired = Array(state["retired_keys"])
      recovered = []
      removed = []

      candidate.reject! do |record|
        next false unless retired.include?(record.fetch("key"))

        removed << record.fetch("key")
        true
      end
      candidate.each do |record|
        identity = sessions[record.fetch("key")]
        next unless identity.is_a?(Hash) && !identity["session_id"].to_s.empty?

        stored_id = record["session_id"].to_s.strip
        if stored_id != identity.fetch("session_id") ||
           (identity["session_bootstrapped"] == true && record["session_bootstrapped"] != true)
          record["session_id"] = identity.fetch("session_id")
          record["session_bootstrapped"] = identity["session_bootstrapped"] != false
          recovered << record.fetch("key")
        end
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
        next unless RESTORABLE_SNAPSHOT_KINDS.include?(metadata["kind"])

        data_path = File.join(backup_dir, metadata["snapshot"].to_s)
        expected_metadata_path = data_path.sub(/\.json\z/, ".metadata.json")
        next unless File.expand_path(metadata_path) == File.expand_path(expected_metadata_path)
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
      emergency = emergency_backup!
      begin
        FileStore.write_json(store_path, records)
        installed = validate_records!(JSON.parse(FileStore.read_text(store_path)))
        raise IOError, "restored store did not match the selected snapshot" unless installed == records
      rescue StandardError
        restore_emergency!(emergency) if emergency
        raise
      end
      begin
        update_state(records, allow_retired_keys: true, replace_sessions: true)
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

      bytes = File.binread(store_path)
      records = begin
        validate_records!(JSON.parse(bytes))
      rescue StandardError => e
        return forensic_backup!(bytes, error: e)
      end
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
      { "path" => data_path, "valid" => true }
    rescue StandardError
      FileUtils.rm_f(data_path) if data_path
      FileUtils.rm_f(metadata_path) if metadata_path
      raise
    end

    def forensic_backup!(bytes, error:)
      timestamp = @now.call.utc.strftime("%Y%m%dT%H%M%S%6NZ")
      data_path = File.join(backup_dir, "pre-restore-invalid-#{timestamp}-#{SecureRandom.hex(4)}.raw")
      metadata_path = "#{data_path}.metadata.json"
      FileUtils.mkdir_p(backup_dir)
      FileStore.atomic_write_bytes(data_path, bytes, backup: false)
      metadata = {
        "schema_version" => SNAPSHOT_SCHEMA_VERSION,
        "kind" => FORENSIC_SNAPSHOT_KIND,
        "created_at" => @now.call.utc.iso8601(6),
        "source" => File.basename(store_path),
        "snapshot" => File.basename(data_path),
        "sha256" => Digest::SHA256.hexdigest(bytes),
        "byte_size" => bytes.bytesize,
        "content_valid" => false,
        "parse_error" => "#{error.class}: #{utf8_text(error.message)}"
      }
      FileStore.write_json(metadata_path, metadata, backup: false)
      validate_forensic_snapshot!(data_path, metadata)
      { "path" => data_path, "valid" => false }
    rescue StandardError
      FileUtils.rm_f(data_path) if data_path
      FileUtils.rm_f(metadata_path) if metadata_path
      raise
    end

    def restore_emergency!(emergency)
      if emergency.fetch("valid")
        records = validate_records!(JSON.parse(FileStore.read_text(emergency.fetch("path"))))
        FileStore.write_json(store_path, records)
      else
        FileStore.atomic_write_bytes(store_path, File.binread(emergency.fetch("path")))
      end
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

      validate_snapshot_metadata!(metadata, path:)
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
        "schema_version" => SNAPSHOT_SCHEMA_VERSION,
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

    def update_state(records, allow_retired_keys:, replace_sessions: false)
      state = read_state
      previous_keys = Array(state["active_keys"])
      active_keys = records.map { |record| record.fetch("key") }
      retired = Array(state["retired_keys"]) | (previous_keys - active_keys)
      retired -= active_keys if allow_retired_keys
      sessions = if replace_sessions
                   session_index(records)
                 else
                   merge_session_indexes(normalized_sessions(state["sessions"]), session_index(records))
                 end
      value = {
        "schema_version" => STATE_VERSION,
        "updated_at" => @now.call.utc.iso8601(6),
        "record_count" => records.length,
        "active_keys" => active_keys,
        "retired_keys" => retired,
        "sessions" => sessions
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

    def normalized_sessions(value)
      return {} unless value.is_a?(Hash)

      value.each_with_object({}) do |(key, identity), result|
        next unless identity.is_a?(Hash)

        session_id = identity["session_id"].to_s.strip
        next if key.to_s.empty? || session_id.empty?

        result[key.to_s] = {
          "session_id" => session_id,
          "session_bootstrapped" => identity["session_bootstrapped"] == true
        }
      end
    end

    def merge_session_indexes(previous, current)
      previous.merge(current) do |key, old_identity, new_identity|
        if old_identity.fetch("session_id") != new_identity.fetch("session_id")
          raise IOError, "managed-agent recovery identity changed unexpectedly for #{key}"
        end

        new_identity.merge(
          "session_bootstrapped" => old_identity["session_bootstrapped"] == true ||
            new_identity["session_bootstrapped"] == true
        )
      end
    end

    def validate_records!(records)
      raise IOError, "managed-agent store must contain a JSON array" unless records.is_a?(Array)

      copy = records.map do |record|
        raise IOError, "managed-agent record must be an object" unless record.is_a?(Hash)

        normalized = record.transform_keys(&:to_s)
        REQUIRED_RECORD_FIELDS.each do |field, type|
          raise IOError, "managed-agent record is missing #{field}" unless normalized.key?(field)
          unless schema_type?(normalized[field], type)
            raise IOError, "managed-agent record #{field} has invalid type"
          end
        end
        OPTIONAL_RECORD_FIELDS.each do |field, type|
          next unless normalized.key?(field)
          raise IOError, "managed-agent record #{field} has invalid type" unless schema_type?(normalized[field], type)
        end
        %w[key name project_key workspace].each do |field|
          raise IOError, "managed-agent record has blank #{field}" if normalized[field].strip.empty?
        end
        parse_timestamp!(normalized.fetch("created_at"), "managed-agent created_at")
        validate_optional_timestamp!(normalized, "started_at")
        validate_optional_timestamp!(normalized, "finished_at")
        validate_optional_timestamp!(normalized, "stop_requested_at")
        Array(normalized["runs"]).each do |run|
          raise IOError, "managed-agent run must be an object" unless run.is_a?(Hash)

          REQUIRED_RUN_FIELDS.each do |field, type|
            raise IOError, "managed-agent run is missing #{field}" unless run.key?(field)
            raise IOError, "managed-agent run #{field} has invalid type" unless schema_type?(run[field], type)
          end
          validate_optional_timestamp!(run, "started_at", label: "managed-agent run")
          validate_optional_timestamp!(run, "finished_at", label: "managed-agent run")
        end
        if normalized.key?("session_id")
          unless normalized["session_id"].is_a?(String) && !normalized["session_id"].strip.empty?
            raise IOError, "managed-agent session_id must be a non-empty string"
          end
          unless [true, false].include?(normalized["session_bootstrapped"])
            raise IOError, "managed-agent session_bootstrapped must be boolean when session_id is present"
          end
        elsif normalized.key?("session_bootstrapped")
          raise IOError, "managed-agent session_bootstrapped requires session_id"
        end

        normalized
      end
      keys = copy.map { |record| record.fetch("key") }
      raise IOError, "managed-agent store contains duplicate keys" unless keys.uniq.length == keys.length

      copy
    end

    def validate_snapshot_metadata!(metadata, path:)
      raise IOError, "snapshot metadata must be an object" unless metadata.is_a?(Hash)
      unless metadata["schema_version"] == SNAPSHOT_SCHEMA_VERSION
        raise IOError, "unsupported snapshot metadata version"
      end
      unless RESTORABLE_SNAPSHOT_KINDS.include?(metadata["kind"])
        raise IOError, "unsupported snapshot metadata kind"
      end
      raise IOError, "snapshot metadata source mismatch" unless metadata["source"] == File.basename(store_path)
      raise IOError, "snapshot metadata path mismatch" unless metadata["snapshot"] == File.basename(path)
      filename = File.basename(path)
      expected_prefix = metadata["kind"] == "daily" ? "managed_agents-" : "pre-restore-"
      unless filename.start_with?(expected_prefix) && filename.end_with?(".json")
        raise IOError, "snapshot filename does not match metadata kind"
      end
      parse_timestamp!(metadata["created_at"], "snapshot created_at")
      backup_date = Date.iso8601(metadata["backup_date"].to_s)
      created_date = Time.iso8601(metadata.fetch("created_at")).utc.to_date
      raise IOError, "snapshot backup_date does not match created_at" unless backup_date == created_date
      unless metadata["sha256"].is_a?(String) && metadata["sha256"].match?(/\A[0-9a-f]{64}\z/)
        raise IOError, "snapshot sha256 is invalid"
      end
      %w[byte_size record_count session_count].each do |field|
        value = metadata[field]
        unless value.is_a?(Integer) && value >= 0
          raise IOError, "snapshot #{field} must be a non-negative integer"
        end
      end
      true
    rescue Date::Error, KeyError
      raise IOError, "snapshot metadata timestamp is invalid"
    end

    def validate_forensic_snapshot!(path, metadata)
      unless metadata["schema_version"] == SNAPSHOT_SCHEMA_VERSION && metadata["kind"] == FORENSIC_SNAPSHOT_KIND
        raise IOError, "forensic snapshot metadata schema is invalid"
      end
      raise IOError, "forensic snapshot source mismatch" unless metadata["source"] == File.basename(store_path)
      raise IOError, "forensic snapshot path mismatch" unless metadata["snapshot"] == File.basename(path)
      raise IOError, "forensic snapshot must be marked invalid" unless metadata["content_valid"] == false
      unless metadata["parse_error"].is_a?(String) && !metadata["parse_error"].empty?
        raise IOError, "forensic snapshot parse error is missing"
      end
      unless metadata["sha256"].is_a?(String) && metadata["sha256"].match?(/\A[0-9a-f]{64}\z/)
        raise IOError, "forensic snapshot sha256 is invalid"
      end
      unless metadata["byte_size"].is_a?(Integer) && metadata["byte_size"] >= 0
        raise IOError, "forensic snapshot byte_size is invalid"
      end
      parse_timestamp!(metadata["created_at"], "forensic snapshot created_at")
      raise IOError, "forensic snapshot bytes are missing" unless File.file?(path)
      bytes = File.binread(path)
      raise IOError, "forensic snapshot checksum mismatch" unless Digest::SHA256.hexdigest(bytes) == metadata["sha256"]
      raise IOError, "forensic snapshot size mismatch" unless bytes.bytesize == metadata["byte_size"]
      true
    end

    def parse_timestamp!(value, label)
      raise IOError, "#{label} must be an ISO 8601 string" unless value.is_a?(String) && !value.empty?

      Time.iso8601(value)
    rescue ArgumentError
      raise IOError, "#{label} must be an ISO 8601 string"
    end

    def validate_optional_timestamp!(record, field, label: "managed-agent")
      value = record[field]
      return if value.nil?

      parse_timestamp!(value, "#{label} #{field}")
    end

    def schema_type?(value, types)
      Array(types).any? { |type| value.is_a?(type) }
    end

    def utf8_text(value)
      value.to_s.encode(Encoding::UTF_8, invalid: :replace, undef: :replace)
    end

    def warn_regressions(current, candidate, recovered:, bootstrap_recovered:)
      log_warning("Prevented native session identity loss for: #{recovered.sort.join(", ")}") unless recovered.empty?
      unless bootstrap_recovered.empty?
        log_warning("Prevented native session bootstrap regression for: #{bootstrap_recovered.sort.join(", ")}")
      end
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
