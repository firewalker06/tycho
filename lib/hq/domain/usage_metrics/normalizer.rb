# frozen_string_literal: true

require "digest"
require "json"
require "time"

require_relative "../../harness_registry"

module HQ
  module UsageMetrics
    class Normalizer
      TOKEN_KEYS = %w[
        input_tokens cached_input_tokens cache_creation_input_tokens cache_read_input_tokens
        output_tokens reasoning_output_tokens
      ].freeze

      def initialize(agent:, run:, usage_entries:, source:, inference: {})
        @agent = agent
        @run = run
        @usage_entries = Array(usage_entries)
        @source = source.to_s
        @inference = stringify(inference || {})
      end

      def record
        adapter = HQ.harness_adapter(harness)
        normalized = adapter == "codex" ? codex_usage : per_run_usage(adapter)
        native_session_id = present(@run.session_id) || present(@agent.session_id)
        inferred_fields = Array(@inference["inferred_fields"]).map(&:to_s).uniq
        unknown_reasons = Array(normalized.fetch("unknown_reasons"))
        unknown_reasons << "Native session ID was not reported" unless native_session_id
        unknown_reasons << "Observed model was not reported" if normalized.fetch("observed_models").empty?
        unknown_reasons << "Configured model was not recorded" unless configured_model
        unknown_reasons.concat(Array(@inference["unknown_reasons"]))
        identity = run_identity

        {
          "schema_version" => 1,
          "run_id" => identity,
          "identity_kind" => present(@run.run_id) ? "persisted_uuid" : "deterministic_backfill_v1",
          "agent_key" => @agent.key.to_s,
          "project_key" => @agent.project_key.to_s,
          "group" => present(@agent.respond_to?(:project_group) ? @agent.project_group : nil),
          "harness" => harness,
          "harness_adapter" => adapter,
          "configured_model" => configured_model,
          "observed_models" => normalized.fetch("observed_models"),
          "model_attribution" => normalized.fetch("model_attribution"),
          "native_session_id" => native_session_id,
          "session_key" => native_session_id ? session_key(adapter, native_session_id) : nil,
          "started_at" => utc_iso(@run.started_at),
          "finished_at" => utc_iso(@run.finished_at),
          "duration_ms" => duration_ms,
          "status" => present(@run.status) || "unknown",
          "exit_code" => @run.exit_code,
          "tokens" => normalized["tokens"],
          "cumulative_tokens" => normalized["cumulative_tokens"],
          "codex_baseline_known" => codex_baseline_known?(adapter, native_session_id),
          "estimated_cost" => normalized.fetch("estimated_cost"),
          "completeness" => {
            "telemetry" => normalized.fetch("telemetry_completeness"),
            "tokens" => normalized["tokens"] ? "complete" : "unknown",
            "pricing" => normalized.dig("estimated_cost", "amount_usd").nil? ? "unpriced" : "priced",
            "session" => native_session_id ? "known" : "unknown",
            "model" => normalized.fetch("observed_models").empty? ? configured_model ? "configured_only" : "unknown" : "observed",
            "overall" => unknown_reasons.empty? ? "complete" : "partial",
            "unknown_reasons" => unknown_reasons.compact.uniq,
            "inferred_fields" => inferred_fields
          },
          "provenance" => provenance,
          "archived" => @inference["archived"] == true
        }
      end

      private

      def codex_usage
        entry = final_entry("turn.completed")
        snapshot = token_hash(metadata(entry)["usage"])
        observed = observed_models(entry)
        reasons = []
        reasons << "Codex did not report a complete cumulative token snapshot" unless snapshot
        {
          "tokens" => nil,
          "cumulative_tokens" => snapshot,
          "observed_models" => observed,
          "model_attribution" => observed.map { |model| { "observed_model" => model } },
          "estimated_cost" => unavailable_cost("Codex cost is calculated after cumulative-token normalization"),
          "telemetry_completeness" => entry ? snapshot ? "complete" : "partial" : "unknown",
          "unknown_reasons" => reasons
        }
      end

      def per_run_usage(adapter)
        entry_type = adapter == "opencode" ? "step_finish" : "result"
        entries = @usage_entries.select { |entry| event_type(entry) == entry_type }
        final = entries.last
        tokens = token_hash(metadata(final)["usage"], require_codex_core: false)
        attribution = adapter == "claude" ? claude_model_attribution(final) : []
        observed = (observed_models(final) + attribution.filter_map { |item| item["observed_model"] }).uniq.sort
        cost = if adapter == "opencode"
                 values = entries.filter_map { |entry| numeric(metadata(entry)["total_cost_usd"]) }
                 values.empty? ? nil : values.sum
               else
                 numeric(metadata(final)["total_cost_usd"])
               end
        reason = if final.nil?
                   "#{adapter_label(adapter)} did not report usage telemetry"
                 elsif cost.nil?
                   "#{adapter_label(adapter)} did not report a run cost"
                 end
        {
          "tokens" => tokens,
          "cumulative_tokens" => nil,
          "observed_models" => observed,
          "model_attribution" => attribution,
          "estimated_cost" => cost_payload(
            cost,
            "#{adapter}_reported_estimate",
            {
              "source" => "#{adapter}_reported_total",
              "version" => nil,
              "version_unknown_reason" => "The harness did not report a pricing version"
            },
            reason
          ),
          "telemetry_completeness" => if final.nil?
                                        "unknown"
                                      elsif tokens && !cost.nil?
                                        "complete"
                                      elsif tokens || !cost.nil?
                                        "partial"
                                      else
                                        "unknown"
                                      end,
          "unknown_reasons" => [reason, ("Token telemetry was not reported" unless tokens)].compact
        }
      end

      def claude_model_attribution(entry)
        usage = metadata(entry)["model_usage"]
        return [] unless usage.is_a?(Hash)

        usage.map do |model, values|
          details = values.is_a?(Hash) ? stringify(values) : {}
          tokens = token_hash(details, require_codex_core: false)
          amount = numeric(details["costUSD"] || details["cost_usd"] || details["total_cost_usd"])
          {
            "observed_model" => present(model),
            "tokens" => tokens,
            "estimated_cost_usd" => amount,
            "currency" => amount.nil? ? nil : "USD",
            "cost_source" => amount.nil? ? nil : "claude_model_usage",
            "pricing_version" => nil,
            "pricing_version_unknown_reason" => "Claude modelUsage did not report a pricing version",
            "reason_unavailable" => amount.nil? ? "Claude modelUsage did not report attributed cost" : nil
          }
        end.sort_by { |item| item.fetch("observed_model", "") }
      end

      def observed_models(entry)
        model = present(metadata(entry)["model"])
        model ? [model] : []
      end

      def provenance
        events = @usage_entries.map do |entry|
          safe = safe_usage_metadata(metadata(entry))
          {
            "event_type" => event_type(entry),
            "event_sha256" => Digest::SHA256.hexdigest(JSON.generate(canonical(safe))),
            "fields" => safe.keys.sort
          }
        end
        {
          "source" => @source,
          "event_count" => events.length,
          "events" => events,
          "log_start_offset" => @run.respond_to?(:log_start_offset) ? @run.log_start_offset : nil
        }
      end

      def safe_usage_metadata(value)
        allowed = %w[
          event_type total_cost_usd usage model model_usage subtype is_error duration_ms duration_api_ms
          num_turns session_id
        ]
        value.select { |key, _entry| allowed.include?(key.to_s) }
      end

      def run_identity
        existing = present(@run.respond_to?(:run_id) ? @run.run_id : nil)
        return existing if existing

        components = [@agent.key, utc_iso(@run.started_at), @run.respond_to?(:log_start_offset) ? @run.log_start_offset : nil,
                      @inference["source_identity"]].map(&:to_s)
        Digest::SHA256.hexdigest("usage-run-v1\0#{components.join("\0")}")
      end

      def session_key(adapter, native_session_id)
        Digest::SHA256.hexdigest("native-session-v1\0#{adapter}\0#{native_session_id}")
      end

      def codex_baseline_known?(adapter, native_session_id)
        return nil unless adapter == "codex"
        return false unless native_session_id
        return @inference["codex_baseline_known"] if @inference.key?("codex_baseline_known")

        prior = Array(@agent.runs)[0...-1].count { |candidate| candidate.session_id.to_s == native_session_id }
        prior.zero?
      end

      def configured_model
        present(@run.respond_to?(:model) ? @run.model : nil) || present(@agent.respond_to?(:model) ? @agent.model : nil)
      end

      def harness
        present(@run.respond_to?(:agent) ? @run.agent : nil) || @agent.agent.to_s
      end

      def final_entry(type)
        @usage_entries.reverse.find { |entry| event_type(entry) == type }
      end

      def event_type(entry)
        metadata(entry)["event_type"].to_s
      end

      def metadata(entry)
        return {} unless entry.respond_to?(:metadata) && entry.metadata.is_a?(Hash)

        stringify(entry.metadata)
      end

      def token_hash(value, require_codex_core: true)
        return nil unless value.is_a?(Hash)

        aliases = {
          "input_tokens" => ["input_tokens", "inputTokens"],
          "cached_input_tokens" => ["cached_input_tokens", "cachedInputTokens"],
          "cache_creation_input_tokens" => ["cache_creation_input_tokens", "cacheCreationInputTokens"],
          "cache_read_input_tokens" => ["cache_read_input_tokens", "cacheReadInputTokens"],
          "output_tokens" => ["output_tokens", "outputTokens"],
          "reasoning_output_tokens" => ["reasoning_output_tokens", "reasoningOutputTokens"]
        }
        result = TOKEN_KEYS.each_with_object({}) do |key, tokens|
          raw = aliases.fetch(key).filter_map { |candidate| value[candidate] }.first
          number = numeric(raw)
          tokens[key] = number unless number.nil?
        end
        required = require_codex_core ? %w[input_tokens cached_input_tokens output_tokens] : %w[input_tokens output_tokens]
        return nil unless required.all? { |key| result.key?(key) }

        result
      end

      def duration_ms
        return nil unless @run.started_at && @run.finished_at

        milliseconds = ((@run.finished_at - @run.started_at) * 1000).round
        milliseconds >= 0 ? milliseconds : nil
      end

      def cost_payload(amount, source, pricing, reason)
        {
          "amount_usd" => amount,
          "currency" => amount.nil? ? nil : "USD",
          "semantics" => "estimate_not_invoice",
          "source" => amount.nil? ? "unpriced" : source,
          "pricing" => pricing,
          "reason_unavailable" => reason
        }
      end

      def unavailable_cost(reason)
        cost_payload(nil, "unpriced", nil, reason)
      end

      def adapter_label(adapter)
        adapter == "opencode" ? "OpenCode" : adapter.capitalize
      end

      def utc_iso(value)
        value&.utc&.iso8601(6)
      end

      def numeric(value)
        number = Float(value)
        number if number.finite? && number >= 0
      rescue ArgumentError, TypeError
        nil
      end

      def present(value)
        text = value.to_s.strip
        text unless text.empty?
      end

      def stringify(value)
        case value
        when Hash then value.each_with_object({}) { |(key, entry), result| result[key.to_s] = stringify(entry) }
        when Array then value.map { |entry| stringify(entry) }
        else value
        end
      end

      def canonical(value)
        case value
        when Hash then value.keys.sort.to_h { |key| [key, canonical(value[key])] }
        when Array then value.map { |entry| canonical(entry) }
        else value
        end
      end
    end
  end
end
