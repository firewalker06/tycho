# frozen_string_literal: true

module HQ
  # Server-lifetime cache of chat blocks parsed from an agent's own logs, keyed
  # per agent and validated by a caller-supplied revision. Requests run in
  # parallel threads and each request builds its own RemoteService, so the
  # cache must outlive the service and guard its state with a mutex.
  #
  # Blocks are built outside the lock so a slow build for one agent never
  # stalls reads for another. Concurrent readers of the same agent and
  # revision share one build. The cache is bounded by entry count and by the
  # total number of cached blocks, because one long transcript can hold
  # thousands of blocks.
  class ConversationBlocksCache
    DEFAULT_LIMIT = 200
    DEFAULT_BLOCK_BUDGET = 20_000

    def initialize(limit: DEFAULT_LIMIT, block_budget: DEFAULT_BLOCK_BUDGET)
      @limit = limit
      @block_budget = block_budget
      @entries = {}
      @in_flight = {}
      @block_count = 0
      @mutex = Mutex.new
      @finished = ConditionVariable.new
    end

    def fetch(agent_key, revision, &build)
      key = agent_key.to_s
      loop do
        flight = nil
        waited = false
        @mutex.synchronize do
          entry = touch(key)
          return entry[:blocks] if entry && entry[:revision] == revision

          current = @in_flight[key]
          if current.nil?
            flight = @in_flight[key] = { revision: revision }
          elsif current[:revision] == revision
            @finished.wait(@mutex) while @in_flight[key].equal?(current)
            waited = true
          end
        end
        next if waited

        return build_and_store(key, revision, flight, &build)
      end
    end

    def delete(agent_key)
      @mutex.synchronize { remove(agent_key.to_s) }
    end

    def blocks_for(agent_key)
      @mutex.synchronize { @entries[agent_key.to_s]&.fetch(:blocks) }
    end

    def size
      @mutex.synchronize { @entries.size }
    end

    def block_count
      @mutex.synchronize { @block_count }
    end

    private

    # Must hold @mutex. Moves the entry to the most-recently-used position.
    def touch(key)
      entry = @entries.delete(key)
      @entries[key] = entry if entry
      entry
    end

    def build_and_store(key, revision, flight)
      blocks = yield
      @mutex.synchronize do
        remove(key)
        if blocks.length <= @block_budget
          @entries[key] = { revision: revision, blocks: blocks }
          @block_count += blocks.length
          evict
        end
      end
      blocks
    ensure
      @mutex.synchronize do
        @in_flight.delete(key) if flight && @in_flight[key].equal?(flight)
        @finished.broadcast
      end
    end

    def remove(key)
      entry = @entries.delete(key)
      @block_count -= entry[:blocks].length if entry
      entry
    end

    def evict
      remove(@entries.first.first) while @entries.size > @limit || @block_count > @block_budget
    end
  end
end
