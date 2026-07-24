# frozen_string_literal: true

require "time"

require_relative "../harness_registry"
require_relative "openai_model_pricing"

module HQ
  module AgentCostSnapshot
    module_function

    def advance(agent:, run:, usage_entries:)
      previous = normalize_snapshot(agent.cost_snapshot)
      session_id = run.session_id.to_s
      same_session = previous && previous["session_id"].to_s == session_id
      previous = nil unless same_session
      prior_session_runs = agent.runs[0...-1].count { |candidate| candidate.session_id.to_s == session_id }
      adapter = HQ.harness_adapter(run.respond_to?(:agent) && !run.agent.to_s.empty? ? run.agent : agent.agent)
      usage = Array(usage_entries)
      token_snapshot, run_tokens = codex_token_snapshots(adapter, usage, previous:, prior_session_runs:)
      run_model = run.respond_to?(:model) ? run.model : agent_model(agent)
      cost_result = run_cost_for(adapter, usage, model: run_model, run_tokens: run_tokens)
      run_cost = cost_result.fetch("amount_usd")

      amount = previous&.fetch("amount_usd", nil)
      amount = add_cost(amount, run_cost) unless run_cost.nil?
      tracked_run_count = previous&.fetch("tracked_run_count", 0).to_i
      tracked_run_count += 1 unless run_cost.nil?
      missing_run_count = previous&.fetch("missing_run_count", 0).to_i
      missing_run_count += 1 if run_cost.nil?
      coverage = coverage_for(previous:, prior_session_runs:, amount:, run_cost:)

      {
        "currency" => "USD",
        "amount_usd" => amount,
        "run_amount_usd" => run_cost,
        "basis" => basis_for(adapter, run_cost, previous),
        "coverage" => coverage,
        "source" => cost_result.fetch("source"),
        "session_id" => session_id,
        "as_of" => (run.finished_at || agent.finished_at || Time.now).iso8601,
        "through_run_count" => agent.run_count,
        "tracked_run_count" => tracked_run_count,
        "missing_run_count" => missing_run_count,
        "reason_unavailable" => run_cost.nil? ? cost_result["reason_unavailable"] : nil,
        "model" => cost_result["model"],
        "pricing" => cost_result["pricing"],
        "token_snapshot" => token_snapshot,
        "run_tokens" => run_tokens
      }.compact
    end

    def normalize(value)
      normalize_snapshot(value)
    end

    def run_cost_for(adapter, usage_entries, model:, run_tokens:)
      case adapter
      when "claude"
        entry = usage_entries.reverse.find { |candidate| event_type(candidate) == "result" }
        cost = numeric_cost(metadata(entry)["total_cost_usd"])
        cost_result(cost, "claude_result", cost.nil? ? "Claude did not report a run cost" : nil)
      when "opencode"
        entries = usage_entries.select { |candidate| event_type(candidate) == "step_finish" }
        costs = entries.filter_map { |entry| numeric_cost(metadata(entry)["total_cost_usd"]) }
        cost = costs.empty? ? nil : costs.sum
        cost_result(cost, "opencode_step_finish", cost.nil? ? "OpenCode did not report step costs" : nil)
      when "codex"
        entry = usage_entries.reverse.find { |candidate| event_type(candidate) == "turn.completed" }
        return cost_result(nil, "codex_turn_completed", "Codex did not report token usage") unless entry
        return cost_result(nil, "codex_token_estimate", "Codex token delta is unavailable") unless run_tokens

        HQ::OpenAIModelPricing.estimate(model:, tokens: run_tokens).merge("source" => "codex_token_estimate")
      else
        cost_result(nil, "unknown", "The harness does not expose cost usage")
      end
    end
    private_class_method :run_cost_for

    def cost_result(amount, source, reason = nil)
      { "amount_usd" => amount, "source" => source, "reason_unavailable" => reason }
    end
    private_class_method :cost_result

    def coverage_for(previous:, prior_session_runs:, amount:, run_cost:)
      return amount.nil? ? "unavailable" : "partial" if run_cost.nil?
      return "partial" if previous && previous["coverage"] != "complete"
      return "partial" if previous.nil? && prior_session_runs.positive?

      "complete"
    end
    private_class_method :coverage_for

    def basis_for(adapter, run_cost, previous)
      return previous["basis"] if run_cost.nil? && previous&.key?("basis")
      return "harness_estimate" if !run_cost.nil? && %w[claude opencode].include?(adapter)
      return "api_list_price_estimate" if !run_cost.nil? && adapter == "codex"

      "unavailable"
    end
    private_class_method :basis_for

    def codex_token_snapshots(adapter, usage_entries, previous:, prior_session_runs:)
      return [nil, nil] unless adapter == "codex"

      entry = usage_entries.reverse.find { |candidate| event_type(candidate) == "turn.completed" }
      values = metadata(entry)["usage"]
      return [nil, nil] unless values.is_a?(Hash)

      snapshot = %w[input_tokens cached_input_tokens output_tokens reasoning_output_tokens].each_with_object({}) do |key, result|
        result[key] = values[key] if values[key].is_a?(Numeric)
      end
      return [nil, nil] if snapshot.empty?

      previous_tokens = previous&.dig("token_snapshot")
      run_tokens = if previous_tokens.is_a?(Hash)
                     token_delta(snapshot, previous_tokens)
                   elsif prior_session_runs.zero?
                     snapshot.dup
                   end
      [snapshot, run_tokens]
    end
    private_class_method :codex_token_snapshots

    def token_delta(current, previous)
      current.each_with_object({}) do |(key, value), result|
        prior = previous[key]
        result[key] = prior.is_a?(Numeric) ? [value - prior, 0].max : value
      end
    end
    private_class_method :token_delta

    def add_cost(total, run_cost)
      return run_cost.to_f if total.nil?

      total.to_f + run_cost.to_f
    end
    private_class_method :add_cost

    def agent_model(agent)
      agent.respond_to?(:model) ? agent.model : nil
    end
    private_class_method :agent_model

    def numeric_cost(value)
      number = Float(value)
      return nil unless number.finite? && number >= 0

      number
    rescue ArgumentError, TypeError
      nil
    end
    private_class_method :numeric_cost

    def event_type(entry)
      metadata(entry)["event_type"].to_s
    end
    private_class_method :event_type

    def metadata(entry)
      return {} unless entry.respond_to?(:metadata)

      entry.metadata.is_a?(Hash) ? entry.metadata : {}
    end
    private_class_method :metadata

    def normalize_snapshot(value)
      return nil unless value.is_a?(Hash) && !value.empty?

      value.each_with_object({}) { |(key, entry), result| result[key.to_s] = entry }
    end
    private_class_method :normalize_snapshot
  end
end
