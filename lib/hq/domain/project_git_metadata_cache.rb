# frozen_string_literal: true

module HQ
  # One server-wide cache. Detail requests express demand; no timer warms idle projects.
  # Git runs on at most two workers, never on a request thread.
  class ProjectGitMetadataCache
    FRESHNESS_WINDOW = 10
    WORKER_LIMIT = 2

    def initialize(clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) })
      @clock = clock
      @entries = {}
      @pending = {}
      @workers = []
      @mutex = Mutex.new
      @closed = false
    end

    def apply(project)
      metadata = @mutex.synchronize { @entries.dig(cache_key(project), :metadata) }
      project.apply_git_metadata(metadata) if metadata
      project
    end

    # Return a consistent snapshot, and coalesce demand from tabs and peer requests.
    # Failed attempts also have a retry window, to avoid retry bursts on broken mounts.
    def request(project)
      @mutex.synchronize do
        key = cache_key(project)
        entry = @entries[key] ||= { metadata: {}.freeze }
        now = @clock.call
        unless @closed || entry[:refreshing] || (entry[:attempted_at] && now - entry[:attempted_at] < FRESHNESS_WINDOW)
          entry[:refreshing] = true
          @pending[key] = [project, now]
          start_workers
        end
        state = if entry[:failed]
                  "failed"
                elsif entry[:refreshed_at]
                  now - entry[:refreshed_at] < FRESHNESS_WINDOW ? "fresh" : "stale"
                else
                  "unknown"
                end
        { metadata: entry[:metadata], state: state, refreshing: entry[:refreshing] == true }
      end
    end

    # Explicit synchronous refresh for non-HTTP callers and regression fixtures.
    # Server detail reads use request instead.
    def refresh(project)
      metadata = project.refresh_metadata!
      @mutex.synchronize do
        key = cache_key(project)
        entry = @entries[key] ||= { metadata: {}.freeze }
        entry[:metadata] = entry[:metadata].merge(metadata).freeze
        entry[:attempted_at] = @clock.call
        entry[:failed] = (Project::GIT_FIELDS - metadata.keys).any?
        entry[:refreshed_at] = entry[:attempted_at] unless entry[:failed]
      end
      project
    rescue StandardError => e
      @mutex.synchronize do
        entry = @entries[cache_key(project)] ||= { metadata: {}.freeze }
        entry[:attempted_at] = @clock.call
        entry[:failed] = true
      end
      HQ.logger.warn("Project") { "Git metadata refresh failed for #{project.key}: #{e.class} - #{e.message}" }
      project
    end

    def known?(project)
      metadata = @mutex.synchronize { @entries.dig(cache_key(project), :metadata) }
      !metadata.nil? && (Project::GIT_FIELDS - metadata.keys).empty?
    end

    def close
      workers = @mutex.synchronize do
        @closed = true
        @pending.each_key { |key| @entries[key][:refreshing] = false }
        @pending.clear
        @workers.dup
      end
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + Project::GIT_COMMAND_TIMEOUT * Project::GIT_FIELDS.length + 2
      workers.each do |worker|
        remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
        worker.join(remaining) if remaining.positive?
      end
    end

    private

    # Called under the mutex. Workers leave when demand is drained, so standalone
    # service callers do not retain idle threads. Old queued demand is discarded.
    def start_workers
      target = [WORKER_LIMIT, @workers.length + @pending.length].min
      while @workers.length < target
        @workers << Thread.new do
          Thread.current.report_on_exception = false
          loop do
            job = @mutex.synchronize do
              pair = @pending.shift
              unless pair
                @workers.delete(Thread.current)
                next nil
              end
              key, (project, requested_at) = pair
              if @clock.call - requested_at >= FRESHNESS_WINDOW
                @entries[key][:refreshing] = false
                next :expired
              end
              [key, project]
            end
            break unless job
            next if job == :expired

            key, project = job
            begin
              refresh(project)
            ensure
              @mutex.synchronize { @entries[key][:refreshing] = false }
            end
          end
        end
      end
    end

    def cache_key(project)
      [project.key, project.path]
    end
  end
end
