# frozen_string_literal: true

require "json"
require "fileutils"
require "time"

require_relative "constants"
require_relative "process_liveness"

module HQ
  ScheduleDaemonState = Struct.new(
    :status, :pid, :mode, :dry_run, :interval, :started_at, :last_tick_started_at,
    :last_tick_finished_at, :last_result, :last_error, :shutdown_at, :stale_after_seconds,
    keyword_init: true
  ) do
    def to_hash
      {
        status: status,
        pid: pid,
        mode: mode,
        dry_run: dry_run,
        interval: interval,
        started_at: started_at&.iso8601,
        last_tick_started_at: last_tick_started_at&.iso8601,
        last_tick_finished_at: last_tick_finished_at&.iso8601,
        last_result: last_result,
        last_error: last_error,
        shutdown_at: shutdown_at&.iso8601,
        stale_after_seconds: stale_after_seconds
      }.compact
    end
  end

  ScheduleState = Struct.new(
    :key, :status, :enabled, :paused_at, :last_due_at, :last_started_at, :last_finished_at,
    :last_status, :last_error, :last_target_kind, :last_target_key, :previous_target_key,
    :next_due_at, :run_count, :skip_count, :first_success_notified_at, :failure_started_at,
    :recovery_notified_at,
    keyword_init: true
  ) do
    OPERATOR_STATUSES = %w[scheduled paused stopped].freeze
    LEGACY_STOPPED_STATUSES = %w[failed blocked awaiting-input stopped].freeze

    def self.from_hash(hash)
      enabled = hash.key?("enabled") ? hash["enabled"] != false : true
      paused_at = parse_time(hash["paused_at"])
      last_status = hash["last_status"]
      last_error = hash["last_error"]
      new(
        key: hash["key"],
        status: normalize_status(hash["status"]) || legacy_status(
          enabled: enabled,
          paused_at: paused_at,
          last_status: last_status,
          last_error: last_error
        ),
        enabled: enabled,
        paused_at: paused_at,
        last_due_at: parse_time(hash["last_due_at"]),
        last_started_at: parse_time(hash["last_started_at"]),
        last_finished_at: parse_time(hash["last_finished_at"]),
        last_status: last_status,
        last_error: last_error,
        last_target_kind: hash["last_target_kind"],
        last_target_key: hash["last_target_key"],
        previous_target_key: hash["previous_target_key"],
        next_due_at: parse_time(hash["next_due_at"]),
        run_count: hash["run_count"].to_i,
        skip_count: hash["skip_count"].to_i,
        first_success_notified_at: parse_time(hash["first_success_notified_at"]),
        failure_started_at: parse_time(hash["failure_started_at"]),
        recovery_notified_at: parse_time(hash["recovery_notified_at"])
      )
    end

    def self.normalize_status(value)
      text = value.to_s.strip
      OPERATOR_STATUSES.include?(text) ? text : nil
    end

    def self.legacy_status(enabled:, paused_at:, last_status:, last_error:)
      return "stopped" if stopped_legacy_state?(last_status:, last_error:)
      return "paused" if enabled == false || paused_at

      "scheduled"
    end

    def self.stopped_legacy_state?(last_status:, last_error:)
      return true if last_error.to_s == "interactive"

      LEGACY_STOPPED_STATUSES.include?(last_status.to_s)
    end

    def self.parse_time(value)
      return nil if value.to_s.empty?

      Time.parse(value.to_s)
    rescue StandardError
      nil
    end

    def to_hash
      {
        "key" => key,
        "status" => status,
        "enabled" => enabled != false,
        "paused_at" => paused_at&.iso8601,
        "last_due_at" => last_due_at&.iso8601,
        "last_started_at" => last_started_at&.iso8601,
        "last_finished_at" => last_finished_at&.iso8601,
        "last_status" => last_status,
        "last_error" => last_error,
        "last_target_kind" => last_target_kind,
        "last_target_key" => last_target_key,
        "previous_target_key" => previous_target_key,
        "next_due_at" => next_due_at&.iso8601,
        "run_count" => run_count.to_i,
        "skip_count" => skip_count.to_i,
        "first_success_notified_at" => first_success_notified_at&.iso8601,
        "failure_started_at" => failure_started_at&.iso8601,
        "recovery_notified_at" => recovery_notified_at&.iso8601
      }.compact
    end

    def status
      self[:status] = self.class.normalize_status(self[:status]) || self.class.legacy_status(
        enabled: enabled,
        paused_at: paused_at,
        last_status: last_status,
        last_error: last_error
      )
    end

    def status=(value)
      self[:status] = self.class.normalize_status(value) || "scheduled"
    end

    def scheduled?
      status == "scheduled"
    end

    def paused?
      status == "paused"
    end

    def stopped?
      status == "stopped"
    end

    def mark_scheduled!
      self.status = "scheduled"
      self.enabled = true
      self.paused_at = nil
    end

    def mark_paused!(now: Time.now)
      self.status = "paused"
      self.enabled = false
      self.paused_at ||= now
    end

    def mark_stopped!(now: Time.now)
      self.status = "stopped"
      self.enabled = false
      self.paused_at ||= now
    end
  end

  class ScheduleStore
    DEFAULT_DAEMON_STALE_AFTER_SECONDS = 120

    attr_reader :path

    def initialize(path: SCHEDULES_STATE_FILE, daemon_path: SCHEDULER_DAEMON_FILE, process_detector: nil)
      @path = path
      @daemon_path = daemon_path
      @process_detector = process_detector
    end

    def load
      return {} unless File.exist?(@path)

      parsed = JSON.parse(File.read(@path))
      Array(parsed).each_with_object({}) do |hash, states|
        state = ScheduleState.from_hash(hash)
        states[state.key] = state unless state.key.to_s.empty?
      end
    rescue StandardError
      {}
    end

    def save(states)
      FileUtils.mkdir_p(File.dirname(@path))
      ordered = states.values.sort_by { |state| state.key.to_s }
      File.write(@path, JSON.pretty_generate(ordered.map(&:to_hash)))
    end

    def state_for(states, key)
      states[key.to_s] ||= ScheduleState.new(
        key: key.to_s,
        status: "scheduled",
        enabled: true,
        run_count: 0,
        skip_count: 0
      )
    end

    def record_daemon_start!(pid:, mode:, interval:, dry_run:, now: Time.now)
      write_daemon_state(
        "pid" => pid,
        "mode" => mode.to_s,
        "dry_run" => dry_run ? true : false,
        "interval" => interval.to_i,
        "started_at" => now.iso8601,
        "last_tick_started_at" => nil,
        "last_tick_finished_at" => nil,
        "last_result" => nil,
        "last_error" => nil,
        "shutdown_at" => nil
      )
    end

    def record_daemon_tick_started!(now: Time.now)
      merge_daemon_state(
        "last_tick_started_at" => now.iso8601,
        "last_error" => nil,
        "shutdown_at" => nil
      )
    end

    def record_daemon_tick_finished!(result, now: Time.now)
      merge_daemon_state(
        "last_tick_finished_at" => now.iso8601,
        "last_result" => result
      )
    end

    def record_daemon_stop!(signal: nil, error: nil, now: Time.now)
      merge_daemon_state(
        "shutdown_at" => now.iso8601,
        "shutdown_signal" => signal,
        "last_error" => error
      )
    end

    def daemon_state(now: Time.now, stale_after_seconds: DEFAULT_DAEMON_STALE_AFTER_SECONDS)
      data = read_daemon_state
      return empty_daemon_state(stale_after_seconds:) if data.empty?

      pid = integer_or_nil(data["pid"])
      last_tick_finished_at = ScheduleState.parse_time(data["last_tick_finished_at"])
      last_tick_started_at = ScheduleState.parse_time(data["last_tick_started_at"])
      started_at = ScheduleState.parse_time(data["started_at"])
      shutdown_at = ScheduleState.parse_time(data["shutdown_at"])
      last_seen = last_tick_finished_at || last_tick_started_at || started_at
      alive = ProcessLiveness.alive?(pid)
      status = daemon_status(alive:, shutdown_at:, last_seen:, now:, stale_after_seconds:)
      detected_pid = detected_daemon_pid
      if status == "stopped" && detected_pid
        return untracked_daemon_state(pid: detected_pid, stale_after_seconds:)
      end

      ScheduleDaemonState.new(
        status: status,
        pid: pid,
        mode: data["mode"],
        dry_run: data["dry_run"] == true,
        interval: data["interval"],
        started_at: started_at,
        last_tick_started_at: last_tick_started_at,
        last_tick_finished_at: last_tick_finished_at,
        last_result: data["last_result"],
        last_error: data["last_error"],
        shutdown_at: shutdown_at,
        stale_after_seconds: stale_after_seconds
      )
    end

    private

    def read_daemon_state
      return {} unless File.exist?(@daemon_path)

      parsed = JSON.parse(File.read(@daemon_path))
      parsed.is_a?(Hash) ? parsed : {}
    rescue StandardError
      {}
    end

    def write_daemon_state(data)
      FileUtils.mkdir_p(File.dirname(@daemon_path))
      File.write(@daemon_path, JSON.pretty_generate(data.compact))
    end

    def merge_daemon_state(attrs)
      write_daemon_state(read_daemon_state.merge(attrs))
    end

    def empty_daemon_state(stale_after_seconds:)
      detected_pid = detected_daemon_pid
      return untracked_daemon_state(pid: detected_pid, stale_after_seconds:) if detected_pid

      ScheduleDaemonState.new(status: "stopped", stale_after_seconds:)
    end

    def untracked_daemon_state(pid:, stale_after_seconds:)
      ScheduleDaemonState.new(
        status: "untracked",
        pid: pid,
        last_error: "process is running without heartbeat state; restart bin/schedule to enable tick freshness",
        stale_after_seconds: stale_after_seconds
      )
    end

    def integer_or_nil(value)
      Integer(value)
    rescue StandardError
      nil
    end

    def daemon_status(alive:, shutdown_at:, last_seen:, now:, stale_after_seconds:)
      return "stopped" if shutdown_at
      return "stopped" unless alive
      return "stale" unless last_seen
      return "stale" if now - last_seen > stale_after_seconds

      "running"
    end

    def detected_daemon_pid
      return integer_or_nil(@process_detector.call) if @process_detector
      return nil if HQ.env("DISABLE_SCHEDULE_PROCESS_DETECTION") == "1"

      `ps -axo pid=,command=`.each_line do |line|
        pid_text, command = line.strip.split(/\s+/, 2)
        pid = integer_or_nil(pid_text)
        next unless pid
        next if pid == Process.pid
        next unless scheduler_process_command?(command.to_s)
        next unless ProcessLiveness.alive?(pid)

        return pid
      end
      nil
    rescue StandardError
      nil
    end

    def scheduler_process_command?(command)
      return true if command.match?(%r{(^|\s)bin/schedule(\s|$)})
      return true if command.match?(%r{(^|\s)bin/tycho\s+schedule\s+daemon(\s|$)})
      return true if command.match?(/(^|\s)tycho\s+schedule\s+daemon(\s|$)/)

      false
    end
  end
end
