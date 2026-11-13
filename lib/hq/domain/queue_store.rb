# frozen_string_literal: true

require_relative "constants"
require_relative "file_store"
require "digest"

module HQ
  # Queue records share the agent lifecycle lock. The journal makes a queue and
  # agent-file commit recoverable before a later caller can claim any work.
  class QueueStore
    FIELDS = %w[prompt_queue prompt_queue_claim prompt_queue_dispatch_error queue_work].freeze
    EMPTY_MIGRATION = {
      "queue_sha256" => Digest::SHA256.hexdigest("{}"),
      "entry_ids" => [], "claim_id" => nil, "batch_ids" => []
    }.freeze
    MIGRATION_RETAIN = 100
    MIGRATION_DELETE_LIMIT = 1000
    RUN_FIELDS = %w[queue_delivery_staged queue_delivery_rollback].freeze

    def self.path
      File.join(File.dirname(AGENTS_FILE), "queues.json")
    end

    def self.journal_path
      "#{path}.transaction.json"
    end

    def self.transaction_paths
      [path, journal_path]
    end

    def self.fingerprint(queue)
      return nil unless queue

      Digest::SHA256.hexdigest(JSON.generate(queue.reject { |key, _value| key == "generation" }))
    end

    def self.signature
      transaction_paths.map do |file|
        stat = File.stat(file)
        [stat.ino, stat.size, stat.mtime.to_i, stat.mtime.nsec]
      rescue Errno::ENOENT
        nil
      end
    end

    def initialize(path: self.class.path)
      @path = path
    end

    def journal_path
      "#{@path}.transaction.json"
    end

    def read
      return { "version" => 1, "agents" => {} } unless File.exist?(@path)

      state = JSON.parse(FileStore.read_text(@path))
      validate_state!(state)
    rescue JSON::ParserError => e
      raise IOError, "Invalid queue store: #{e.class}"
    end

    def hydrate(record, state: read)
      reference = record["queue_ref"]
      return record unless reference

      raise IOError, "Queue target reference does not match agent" unless reference == record["key"]
      queue = state.fetch("agents")[reference]
      raise IOError, "Missing queue record for #{reference}" unless queue.is_a?(Hash)
      if record["queue_generation"] != queue["generation"]
        raise IOError, "Agent and queue generations do not match for #{reference}"
      end

      result = Marshal.load(Marshal.dump(record))
      result.delete("queue_ref")
      result.delete("queue_generation")
      FIELDS.each { |field| result.delete(field) }
      FIELDS.each { |field| result[field] = queue[field] if queue.key?(field) }
      Array(result["runs"]).each_with_index do |run, index|
        RUN_FIELDS.each { |field| run["metadata"]&.delete(field) }
        metadata = queue.fetch("runs", {})[run["run_id"] || "index:#{index}"]
        run["metadata"] = (run["metadata"] || {}).merge(metadata) if metadata
      end
      result
    end

    # Caller holds the agent lifecycle lock. Keep removed/archived targets: their
    # completion evidence remains addressable and is never eligible for dispatch.
    def write(records, target: AGENTS_FILE)
      recover!
      state = read
      stripped = records.map do |record|
        record = hydrate(record, state:)
        copy = Marshal.load(Marshal.dump(record))
        queue = FIELDS.to_h { |field| [field, copy.delete(field)] }.compact
        runs = Array(copy["runs"]).each_with_index.each_with_object({}) do |(run, index), result|
          metadata = run["metadata"] || {}
          values = RUN_FIELDS.to_h { |field| [field, metadata.delete(field)] }.compact
          result[run["run_id"] || "index:#{index}"] = values unless values.empty?
        end
        queue["runs"] = runs unless runs.empty?
        if !record.key?("queue_ref") && !state.fetch("agents").key?(copy.fetch("key"))
          state["migrations"] ||= {}
          state["migrations"][copy.fetch("key")] = {
            "queue_sha256" => Digest::SHA256.hexdigest(JSON.generate(queue)),
            "entry_ids" => Array(queue["prompt_queue"]).map { |entry| entry["id"] },
            "claim_id" => queue.dig("prompt_queue_claim", "id"),
            "batch_ids" => Array(queue.dig("queue_work", "batches")).map { |batch| batch["id"] }
          }
        end
        previous = state.fetch("agents")[copy.fetch("key")]
        queue["generation"] = if self.class.fingerprint(previous) == self.class.fingerprint(queue)
                                previous.fetch("generation")
                              else
                                SecureRandom.uuid
                              end
        state.fetch("agents")[copy.fetch("key")] = queue
        copy["queue_ref"] = copy.fetch("key")
        copy["queue_generation"] = queue.fetch("generation")
        copy
      end
      payload = target == AGENTS_FILE ? stripped : stripped.fetch(0)
      journal = { "version" => 1, "target" => target, "records" => payload, "queues" => state }
      FileStore.write_json(journal_path, journal, backup: false)
      install!(journal)
      stripped
    end

    # Caller holds the lifecycle lock. Only audit receipts are candidates.
    # Keep the last 100 by key; legacy receipts have no reliable timestamps.
    def cleanup_empty_migrations(apply: false)
      raise IOError, "Queue transaction needs recovery" if File.exist?(journal_path)

      state = File.exist?(@path) ? JSON.parse(FileStore.read_text(@path)) : read
      validate_state!(state)
      migrations = state.fetch("migrations", {})
      raise IOError, "Invalid migration receipts" unless migrations.is_a?(Hash) && migrations.keys.all? { |key| key.is_a?(String) }

      retained = {}
      eligible = migrations.keys.sort.select do |key|
        receipt = migrations.fetch(key)
        queue = state.fetch("agents")[key]
        reason = if receipt != EMPTY_MIGRATION
                   "nonempty_or_unknown_receipt"
                 elsif !queue.is_a?(Hash) || queue.empty?
                   "missing_queue"
                 elsif queue.keys != ["generation"]
                   "queue_evidence"
                 end
        retained[key] = reason if reason
        reason.nil?
      end
      keep = eligible.last(MIGRATION_RETAIN)
      keep.each { |key| retained[key] = "retention_window" }
      candidates = (eligible - keep).first(MIGRATION_DELETE_LIMIT)
      (eligible - keep - candidates).each { |key| retained[key] = "per_run_limit" }
      report = {
        "mode" => apply ? "apply" : "dry_run",
        "retain" => MIGRATION_RETAIN, "delete_limit" => MIGRATION_DELETE_LIMIT,
        "candidates" => candidates, "retained" => retained,
        "removed" => apply ? candidates : []
      }
      return report unless apply && !candidates.empty?

      candidates.each { |key| migrations.delete(key) }
      journal = { "version" => 2, "operation" => "migration_cleanup", "queues" => state }
      FileStore.write_json(journal_path, journal, backup: false)
      install!(journal)
      report
    rescue JSON::ParserError => e
      raise IOError, "Invalid queue store: #{e.class}"
    end

    def recover!
      return false unless File.exist?(journal_path)

      journal = read_journal
      install!(journal)
      true
    end

    def read_journal
      journal = JSON.parse(FileStore.read_text(journal_path))
      if journal.is_a?(Hash) && journal["version"] == 2 && journal["operation"] == "migration_cleanup"
        validate_state!(journal.fetch("queues"))
        raise IOError, "Invalid migration receipts" unless journal.dig("queues", "migrations").is_a?(Hash)
        return journal
      end
      unless journal.is_a?(Hash) && journal["version"] == 1 && journal["queues"].is_a?(Hash) &&
             journal["target"].is_a?(String) && journal.key?("records")
        raise IOError, "Invalid queue transaction journal"
      end
      state = validate_state!(journal.fetch("queues"))
      records = journal["target"] == AGENTS_FILE ? journal["records"] : [journal["records"]]
      unless records.is_a?(Array) && records.all? { |record| record.is_a?(Hash) && record["queue_ref"] }
        raise IOError, "Invalid queue transaction records"
      end
      records.each { |record| hydrate(record, state:) }
      journal
    rescue JSON::ParserError => e
      raise IOError, "Invalid queue transaction journal: #{e.class}"
    end

    private

    def validate_state!(state)
      unless state.is_a?(Hash) && state["version"] == 1 && state["agents"].is_a?(Hash) &&
             state["agents"].all? { |key, queue| key.is_a?(String) && queue.is_a?(Hash) &&
               (queue.empty? || (queue["generation"].is_a?(String) && !queue["generation"].empty?)) }
        raise IOError, "Invalid queue store"
      end
      # Earlier stores can have empty, unreferenced placeholders while agents
      # still own their inline queues. Treat these as absent without writing.
      # A referenced placeholder still fails hydrate's missing-record check.
      state.merge("agents" => state.fetch("agents").reject { |_key, queue| queue.empty? })
    end

    def install!(journal)
      FileStore.write_json(@path, journal.fetch("queues"))
      FileStore.write_json(journal.fetch("target"), journal.fetch("records")) unless journal["version"] == 2
      File.unlink(journal_path)
      FileStore.fsync_directory(File.dirname(@path))
    end
  end
end
