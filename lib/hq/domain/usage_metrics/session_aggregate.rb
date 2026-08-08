# frozen_string_literal: true

require_relative "values"

module HQ
  module UsageMetrics
    module SessionAggregate
      module_function

      def build(runs)
        sorted = runs.sort_by { |run| [run["started_at"].to_s, run["run_id"].to_s] }
        costs = sorted.filter_map { |run| Values.numeric(run.dig("estimated_cost", "amount_usd")) }
        all_priced = costs.length == sorted.length
        tokens_complete = sorted.all? { |run| valid_tokens?(run["tokens"]) }
        token_totals = sum_tokens(sorted.map { |run| run["tokens"] })
        observed_models = sorted.flat_map { |run| Array(run["observed_models"]) }.uniq.sort
        configured_models = sorted.filter_map { |run| Values.present(run["configured_model"]) }.uniq.sort
        {
          "session_key" => sorted.first.fetch("session_key"),
          "native_session_id" => sorted.first.fetch("native_session_id"),
          "harness_adapter" => sorted.first.fetch("harness_adapter"),
          "first_activity_at" => sorted.first.fetch("started_at"),
          "last_activity_at" => sorted.map { |run| run["finished_at"] || run["started_at"] }.max,
          "run_count" => sorted.length,
          "agent_count" => sorted.map { |run| run["agent_key"] }.uniq.length,
          "configured_models" => configured_models,
          "observed_models" => observed_models,
          "mixed_model" => (configured_models + observed_models).uniq.length > 1,
          "tokens" => tokens_complete ? token_totals : nil,
          "known_tokens" => token_totals,
          "known_estimated_cost_usd" => costs.empty? ? nil : costs.sum,
          "estimated_cost_usd" => all_priced ? costs.sum : nil,
          "currency" => costs.empty? ? nil : "USD",
          "pricing_coverage" => all_priced ? "complete" : costs.empty? ? "unpriced" : "partial",
          "completeness" => {
            "tokens" => tokens_complete ? "complete" : "partial",
            "pricing" => all_priced ? "priced" : costs.empty? ? "unpriced" : "partial",
            "overall" => all_priced && tokens_complete &&
              sorted.all? { |run| run.dig("completeness", "overall") == "complete" } ? "complete" : "partial",
            "unknown_reasons" => sorted.flat_map { |run| Array(run.dig("completeness", "unknown_reasons")) }.uniq
          }
        }
      end

      def valid_tokens?(value)
        value.is_a?(Hash) && %w[input_tokens cached_input_tokens output_tokens].all? do |key|
          number = value[key]
          number.is_a?(Numeric) && number.finite? && number >= 0
        end
      end

      def sum_tokens(tokens)
        keys = Array(tokens).filter_map { |value| value.is_a?(Hash) ? value.keys : nil }.flatten.uniq
        keys.to_h do |key|
          values = Array(tokens).filter_map { |value| Values.numeric(value[key]) if value.is_a?(Hash) }
          [key, values.empty? ? nil : values.sum]
        end.compact
      end
    end
  end
end
