# frozen_string_literal: true

module HQ
  # Server-lifetime cache of rendered conversation blocks, keyed per agent and
  # validated by a caller-supplied revision. Requests run in parallel threads
  # and each request builds its own RemoteService, so the cache must outlive
  # the service and guard its state with a mutex. Blocks are built outside the
  # lock so a slow build for one agent never stalls reads for another.
  class ConversationBlocksCache
    DEFAULT_LIMIT = 200

    def initialize(limit: DEFAULT_LIMIT)
      @limit = limit
      @entries = {}
      @mutex = Mutex.new
    end

    def fetch(agent_key, revision)
      key = agent_key.to_s
      cached = @mutex.synchronize do
        entry = @entries.delete(key)
        @entries[key] = entry if entry
        entry
      end
      return cached[:blocks] if cached && cached[:revision] == revision

      blocks = yield
      @mutex.synchronize do
        @entries.delete(key)
        @entries[key] = { revision: revision, blocks: blocks }
        @entries.shift while @entries.size > @limit
      end
      blocks
    end

    def delete(agent_key)
      @mutex.synchronize { @entries.delete(agent_key.to_s) }
    end

    def blocks_for(agent_key)
      @mutex.synchronize { @entries[agent_key.to_s]&.fetch(:blocks) }
    end

    def size
      @mutex.synchronize { @entries.size }
    end
  end
end
