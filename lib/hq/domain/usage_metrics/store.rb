# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require "time"

require_relative "../constants"
require_relative "../file_store"
require_relative "../openai_model_pricing"
require_relative "session_aggregate"
require_relative "values"

module HQ
  module UsageMetrics
    class Store
      include Values

      SCHEMA_VERSION = 1

      attr_reader :path, :lock_path

      def initialize(path: USAGE_METRICS_FILE, lock_path: nil)
        @path = File.expand_path(path)
        @lock_path = File.expand_path(lock_path || "#{@path}.lock")
      end

      def upsert(record)
        normalized = stringify(record)
        identity = normalized.fetch("run_id")
        with_lock(File::LOCK_EX) do
          document = read_document
          existing = document.fetch("runs")[identity]
          document.fetch("runs")[identity] = normalized
          rebuild!(document)
          return :unchanged if existing == document.fetch("runs")[identity]

          write_document(document)
          existing ? :updated : :created
        end
      end

      def replace(records)
        with_lock(File::LOCK_EX) do
          document = blank_document
          Array(records).each do |record|
            normalized = stringify(record)
            document.fetch("runs")[normalized.fetch("run_id")] = normalized
          end
          rebuild!(document)
          write_document(document)
          document
        end
      end

      def upsert_many(records)
        normalized_records = Array(records).map { |record| stringify(record) }
        with_lock(File::LOCK_EX) do
          document = read_document
          existing = normalized_records.to_h do |record|
            identity = record.fetch("run_id")
            [identity, document.fetch("runs")[identity]]
          end
          normalized_records.each do |record|
            document.fetch("runs")[record.fetch("run_id")] = record
          end
          rebuild!(document)
          outcomes = normalized_records.map { |record| record.fetch("run_id") }.uniq.to_h do |identity|
            prior = existing[identity]
            outcome = if prior.nil?
                        :created
                      elsif prior == document.fetch("runs")[identity]
                        :unchanged
                      else
                        :updated
                      end
            [identity, outcome]
          end
          write_document(document) if outcomes.value?(:created) || outcomes.value?(:updated)
          outcomes.values.tally
        end
      end

      def snapshot
        with_lock(File::LOCK_SH) { deep_copy(read_document) }
      end

      def runs
        snapshot.fetch("runs").values
      end

      def sessions
        snapshot.fetch("sessions").values
      end

      def mark_agent_archived(agent_key)
        changed = false
        with_lock(File::LOCK_EX) do
          document = read_document
          document.fetch("runs").each_value do |run|
            next unless run["agent_key"] == agent_key.to_s
            next if run["archived"] == true

            run["archived"] = true
            changed = true
          end
          if changed
            rebuild!(document)
            write_document(document)
          end
        end
        changed
      end

      private

      def blank_document
        {
          "schema_version" => SCHEMA_VERSION,
          "generated_at" => Time.now.utc.iso8601(6),
          "runs" => {},
          "sessions" => {},
          "recovery" => { "discarded_run_count" => 0, "warnings" => [] }
        }
      end

      def read_document
        return blank_document unless File.exist?(@path)

        raw = JSON.parse(FileStore.read_text(@path))
        migrate(raw)
      rescue StandardError => error
        backup = read_backup
        raise error unless backup

        migrated = migrate(backup)
        migrated["recovery"] = {
          "discarded_run_count" => 0,
          "warnings" => ["Recovered metrics from the atomic-write backup after #{error.class}"]
        }
        migrated
      end

      def read_backup
        backup_path = FileStore.backup_path(@path)
        return nil unless File.exist?(backup_path)

        JSON.parse(FileStore.read_text(backup_path))
      rescue StandardError
        nil
      end

      def migrate(raw)
        raise ArgumentError, "Usage metrics root must be an object" unless raw.is_a?(Hash)

        version = Integer(raw["schema_version"] || 0)
        case version
        when SCHEMA_VERSION
          normalize_document(raw)
        when 0
          migrate_v0(raw)
        else
          raise ArgumentError, "Unsupported usage metrics schema version #{version}"
        end
      end

      def migrate_v0(raw)
        records = Array(raw["records"] || raw["runs"])
        document = blank_document
        records.each do |record|
          next unless record.is_a?(Hash) && !record["run_id"].to_s.empty?

          document.fetch("runs")[record.fetch("run_id").to_s] = stringify(record)
        end
        rebuild!(document)
        document.fetch("recovery").fetch("warnings") << "Migrated usage metrics schema 0 to 1"
        document
      end

      def normalize_document(raw)
        document = blank_document.merge(stringify(raw))
        source_runs = document["runs"]
        source_runs = Array(source_runs).to_h { |record| [record["run_id"].to_s, record] } if source_runs.is_a?(Array)
        source_runs = {} unless source_runs.is_a?(Hash)
        discarded = 0
        document["runs"] = source_runs.each_with_object({}) do |(identity, record), result|
          unless valid_record?(record)
            discarded += 1
            next
          end
          result[identity.to_s] = stringify(record)
        end
        document["recovery"] = stringify(document["recovery"] || {})
        document["recovery"]["discarded_run_count"] = discarded
        document["recovery"]["warnings"] = Array(document["recovery"]["warnings"])
        document["recovery"]["warnings"] << "Discarded #{discarded} invalid run records" if discarded.positive?
        rebuild!(document)
        document
      end

      def valid_record?(record)
        return false unless record.is_a?(Hash)
        return false if %w[run_id started_at agent_key harness_adapter].any? { |key| record[key].to_s.empty? }
        return false if !record["native_session_id"].to_s.empty? && record["session_key"].to_s.empty?

        Time.iso8601(record.fetch("started_at"))
        true
      rescue ArgumentError
        false
      end

      def rebuild!(document)
        recalculate_codex_runs!(document.fetch("runs").values)
        document["sessions"] = build_sessions(document.fetch("runs").values)
        document["schema_version"] = SCHEMA_VERSION
        document["generated_at"] = Time.now.utc.iso8601(6)
      end

      def recalculate_codex_runs!(runs)
        grouped = runs.select { |run| run["harness_adapter"] == "codex" && !run["native_session_id"].to_s.empty? }
                      .group_by { |run| run.fetch("session_key") }
        grouped.each_value do |session_runs|
          previous = nil
          session_runs.sort_by { |run| [run["started_at"].to_s, run["run_id"].to_s] }.each do |run|
            snapshot = run["cumulative_tokens"]
            delta, reason = codex_delta(snapshot, previous, baseline_known: run["codex_baseline_known"] == true)
            run["tokens"] = delta
            update_codex_cost!(run, delta, reason)
            previous = snapshot if valid_tokens?(snapshot)
          end
        end
      end

      def codex_delta(current, previous, baseline_known:)
        return [nil, "Codex did not report a complete cumulative token snapshot"] unless valid_tokens?(current)
        return [nil, "The preceding Codex cumulative snapshot is unavailable"] if previous.nil? && !baseline_known
        return [current.dup, nil] unless previous
        return [nil, "The preceding Codex cumulative snapshot is incomplete"] unless valid_tokens?(previous)

        delta = current.each_with_object({}) do |(key, value), result|
          prior = previous[key]
          return [nil, "Codex cumulative token counters decreased"] if prior.is_a?(Numeric) && value < prior
          result[key] = prior.is_a?(Numeric) ? value - prior : value
        end
        [delta, nil]
      end

      def update_codex_cost!(run, delta, delta_reason)
        if delta
          estimate = OpenAIModelPricing.estimate(model: run["configured_model"], tokens: delta)
          pricing = estimate["pricing"]&.merge("version" => estimate.dig("pricing", "as_of"))
          run["estimated_cost"] = cost_payload(estimate["amount_usd"], estimate["amount_usd"] ? "api_list_price_estimate" : "unpriced",
                                                pricing, estimate["reason_unavailable"])
        else
          run["estimated_cost"] = cost_payload(nil, "unpriced", nil, delta_reason)
        end
        refresh_completeness!(run, delta_reason)
      end

      def refresh_completeness!(run, token_reason)
        completeness = stringify(run["completeness"] || {})
        reasons = Array(completeness["unknown_reasons"]).reject { |reason| reason.to_s.start_with?("Codex ") || reason == "The preceding Codex cumulative snapshot is unavailable" }
        reasons << token_reason if token_reason
        cost_reason = run.dig("estimated_cost", "reason_unavailable")
        reasons << cost_reason if cost_reason
        completeness["tokens"] = run["tokens"] ? "complete" : "unknown"
        completeness["pricing"] = run.dig("estimated_cost", "amount_usd").nil? ? "unpriced" : "priced"
        completeness["unknown_reasons"] = reasons.compact.uniq
        completeness["overall"] = completeness["unknown_reasons"].empty? ? "complete" : "partial"
        run["completeness"] = completeness
      end

      def build_sessions(runs)
        runs.reject { |run| run["native_session_id"].to_s.empty? }.group_by { |run| run.fetch("session_key") }
            .transform_values { |session_runs| SessionAggregate.build(session_runs) }
      end

      def valid_tokens?(value)
        value.is_a?(Hash) && %w[input_tokens cached_input_tokens output_tokens].all? do |key|
          number = value[key]
          number.is_a?(Numeric) && number.finite? && number >= 0
        end
      end

      def cost_payload(amount, source, pricing, reason)
        {
          "amount_usd" => amount,
          "currency" => amount.nil? ? nil : "USD",
          "semantics" => "estimate_not_invoice",
          "source" => source,
          "pricing" => pricing,
          "reason_unavailable" => reason
        }
      end

      def write_document(document)
        recovered = Array(document.dig("recovery", "warnings")).any? { |warning| warning.include?("atomic-write backup") }
        FileStore.write_json(@path, document, backup: !recovered)
      end

      def with_lock(mode)
        FileUtils.mkdir_p(File.dirname(@lock_path))
        File.open(@lock_path, File::RDWR | File::CREAT, 0o600) do |lock|
          lock.flock(mode)
          yield
        ensure
          lock.flock(File::LOCK_UN) rescue nil
        end
      end

      def deep_copy(value)
        JSON.parse(JSON.generate(value))
      end

    end
  end
end
