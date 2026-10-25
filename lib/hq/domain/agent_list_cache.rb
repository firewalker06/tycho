# frozen_string_literal: true

require "thread"

module HQ
  # Thread-safe snapshot of the loaded agent list shared across Remote requests.
  # It is valid only while the agents file keeps the signature seen before the load.
  class AgentListCache
    # max_age bounds staleness for owners that refresh on a timer; 0 disables reuse (no timer to reconcile).
    def initialize(path: AGENTS_FILE, max_age: 0)
      @path = path
      @max_age = max_age
      @replaced_at = nil
      @mutex = Mutex.new
      @records = nil
      @signature = nil
      @readonly_agents = nil
    end

    # Signature of the agents file; take it while holding the store lock that guards the load.
    def signature
      stat = File.stat(@path)
      [stat.ino, stat.size, stat.mtime.to_i, stat.mtime.nsec]
    rescue SystemCallError
      nil
    end

    def replace!(agents, signature:)
      records = agents.to_h { |agent| [agent.key, agent.to_hash.freeze] }.freeze
      @mutex.synchronize do
        @records = records
        @signature = signature
        @readonly_agents = nil
        @replaced_at = now
      end
    end

    # Shared agents for read-only use (such as reference payloads); callers must not mutate them.
    # Returns nil when the snapshot is missing or stale.
    def readonly_agents(usage_metrics_store: nil)
      current = signature
      @mutex.synchronize do
        return nil if stale?(current)

        @readonly_agents ||= @records.values.map do |record|
          agent = ManagedAgent.from_hash(Marshal.load(Marshal.dump(record)))
          agent.usage_metrics_store = usage_metrics_store if usage_metrics_store
          agent
        end
      end
    end

    # Returns a private copy of the agent, :unknown when the valid snapshot has no such key,
    # or nil when the snapshot is missing or stale.
    def fetch(key, usage_metrics_store: nil)
      current = signature
      record = @mutex.synchronize do
        return nil if stale?(current)

        @records[key.to_s] || :unknown
      end
      return :unknown if record == :unknown

      agent = ManagedAgent.from_hash(Marshal.load(Marshal.dump(record)))
      agent.usage_metrics_store = usage_metrics_store if usage_metrics_store
      agent
    end

    private

    def stale?(current)
      @records.nil? || current.nil? || current != @signature || now - @replaced_at >= @max_age
    end

    def now
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
  end
end
