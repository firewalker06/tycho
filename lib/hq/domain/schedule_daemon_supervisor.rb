# frozen_string_literal: true

require "fileutils"
require "rbconfig"
require "time"

require_relative "constants"
require_relative "process_liveness"
require_relative "schedule_store"
require_relative "scheduler"

module HQ
  class ScheduleDaemonSupervisor
    Error = Class.new(StandardError)

    DEFAULT_STOP_TIMEOUT_SECONDS = 5
    DAEMON_LOG_FILE = File.join(LOGS_DIR, "scheduler_daemon.log")

    attr_reader :store, :log_path

    def initialize(store: ScheduleStore.new, command: nil, log_path: DAEMON_LOG_FILE,
                   spawner: nil, detacher: nil, killer: nil, liveness: nil, sleeper: nil)
      @store = store
      @command = command
      @log_path = log_path
      @spawner = spawner || Process.method(:spawn)
      @detacher = detacher || Process.method(:detach)
      @killer = killer || Process.method(:kill)
      @liveness = liveness || ProcessLiveness.method(:alive?)
      @sleeper = sleeper || Kernel.method(:sleep)
    end

    def start!(interval: Scheduler::DEFAULT_INTERVAL, dry_run: false)
      current = store.daemon_state
      if active?(current)
        raise Error, "Scheduler daemon is already #{current.status}"
      end

      normalized_interval = positive_integer(interval, Scheduler::DEFAULT_INTERVAL)
      pid = spawn_daemon(interval: normalized_interval, dry_run: dry_run)
      {
        started: true,
        pid: pid,
        log_path: log_path,
        daemon: {
          status: "starting",
          pid: pid,
          mode: "daemon",
          interval: normalized_interval,
          dry_run: dry_run ? true : false,
          log_path: log_path
        }
      }
    rescue SystemCallError, IOError => e
      store.record_daemon_stop!(error: e.message)
      raise Error, "Failed to start scheduler daemon: #{e.message}"
    end

    def stop!(timeout: DEFAULT_STOP_TIMEOUT_SECONDS)
      current = store.daemon_state
      pid = current.pid
      unless pid
        return {
          stopped: false,
          daemon: current.to_hash,
          message: "Scheduler daemon is not running"
        }
      end

      signal_daemon(pid)
      stopped = wait_for_stop(pid, timeout: positive_integer(timeout, DEFAULT_STOP_TIMEOUT_SECONDS))
      store.record_daemon_stop!(signal: "TERM")
      {
        stopped: stopped,
        daemon: store.daemon_state.to_hash,
        pid: pid
      }
    rescue Errno::ESRCH
      store.record_daemon_stop!(signal: "TERM")
      {
        stopped: true,
        daemon: store.daemon_state.to_hash,
        pid: pid
      }
    rescue SystemCallError => e
      raise Error, "Failed to stop scheduler daemon #{pid}: #{e.message}"
    end

    def restart!(interval: Scheduler::DEFAULT_INTERVAL, dry_run: false)
      stopped = stop!
      if stopped[:pid] && !stopped[:stopped]
        raise Error, "Scheduler daemon did not stop within #{DEFAULT_STOP_TIMEOUT_SECONDS} seconds"
      end

      started = start!(interval:, dry_run:)
      {
        restarted: true,
        stopped: stopped,
        started: started,
        daemon: started.fetch(:daemon)
      }
    end

    private

    def active?(state)
      %w[running stale untracked].include?(state.status.to_s)
    end

    def spawn_daemon(interval:, dry_run:)
      FileUtils.mkdir_p(File.dirname(log_path))
      pid = nil
      File.open(log_path, "ab") do |log|
        log.sync = true
        pid = @spawner.call(
          *daemon_command(interval:, dry_run:),
          out: log,
          err: log,
          pgroup: true,
          chdir: ROOT_DIR
        )
      end
      @detacher.call(pid)
      pid
    end

    def daemon_command(interval:, dry_run:)
      command = Array(@command).map(&:to_s).reject(&:empty?)
      command = default_command if command.empty?
      command = [*command, "--interval", interval.to_s]
      command << "--dry-run" if dry_run
      command
    end

    def default_command
      executable = File.join(ROOT_DIR, "bin", "tycho")
      if File.exist?(executable)
        [RbConfig.ruby, executable, "schedule", "daemon"]
      else
        ["tycho", "schedule", "daemon"]
      end
    end

    def signal_daemon(pid)
      @killer.call("TERM", pid)
    end

    def wait_for_stop(pid, timeout:)
      deadline = Time.now + timeout
      while @liveness.call(pid)
        return false if Time.now >= deadline

        @sleeper.call(0.1)
      end
      true
    end

    def positive_integer(value, fallback)
      number = Integer(value)
      number.positive? ? number : fallback
    rescue StandardError
      fallback
    end
  end
end
