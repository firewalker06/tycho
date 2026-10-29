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
      if adapter == "claude" && (claude_session_totals?(usage) ||
                                (usage.none? { |entry| event_type(entry) == "result" } &&
                                 previous&.fetch("reported_cost_scope", nil) == "session"))
        return claude_session_snapshot(agent:, run:, usage:, previous:, prior_session_runs:)
      end
      token_snapshot, run_tokens = codex_token_snapshots(adapter, usage, previous:, prior_session_runs:)
      run_model = run.respond_to?(:model) ? run.model : nil
      run_model = agent_model(agent) if run_model.to_s.strip.empty?
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
        "run_cost_scope" => run_cost_scope(adapter, usage),
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

    def run_cost_scope(adapter, entries)
      return "run" unless adapter == "claude"

      entry = entries.reverse.find { |candidate| event_type(candidate) == "result" }
      metadata(entry)["claude_code_version"].to_s.match?(/\A\d+\.\d+\.\d+\z/) ? "run" : "reported"
    end
    private_class_method :run_cost_scope

    # Claude Code >= 2.1.277 restores cost totals on native resume. Older
    # versions and compatible wrappers retain the existing per-call path.
    def claude_session_totals?(entries)
      entry = entries.reverse.find { |candidate| event_type(candidate) == "result" }
      version = metadata(entry)["claude_code_version"].to_s
      return false unless version.match?(/\A\d+\.\d+\.\d+\z/)

      (version.split(".").map(&:to_i) <=> [2, 1, 277]) >= 0
    end

    def claude_session_snapshot(agent:, run:, usage:, previous:, prior_session_runs:)
      return previous if previous && previous["through_run_count"].to_i == agent.run_count

      entry = usage.reverse.find { |candidate| event_type(candidate) == "result" }
      reported = numeric_cost(metadata(entry)["total_cost_usd"])
      baseline = previous && numeric_cost(previous["reported_amount_usd"])
      adjacent = previous && previous["through_run_count"].to_i == agent.run_count - 1
      reason = nil
      run_cost = nil
      if reported.nil?
        reason = "Claude did not report a session cost"
      elsif metadata(entry)["subtype"] == "error_during_execution" && reported.zero?
        reported = nil
        reason = "Claude crash result may contain a zeroed cost"
      elsif !metadata(entry)["session_id"].to_s.empty? && metadata(entry)["session_id"].to_s != run.session_id.to_s
        reported = nil
        reason = "Claude result belongs to a different native session"
      elsif run.session_id.to_s.empty?
        reason = "Claude did not report a native session ID"
      elsif prior_session_runs.zero? && previous.nil? &&
            !(run.respond_to?(:command) && run.command.to_s.match?(/--(?:resume|continue)\b/))
        run_cost = reported
      elsif baseline && adjacent && previous["reported_cost_scope"] == "session" && reported >= baseline
        run_cost = reported - baseline
      else
        reason = "Claude session cost has no consecutive compatible baseline"
      end
      {
        "currency" => "USD",
        "amount_usd" => reported || previous&.fetch("amount_usd", nil),
        "run_amount_usd" => run_cost,
        "reported_amount_usd" => reported,
        "reported_cost_scope" => "session",
        "run_cost_scope" => "run",
        "basis" => "harness_estimate",
        "coverage" => reported.nil? ? previous ? "partial" : "unavailable" : "complete",
        "source" => "claude_session_result",
        "run_id" => run.respond_to?(:run_id) ? run.run_id : nil,
        "session_id" => run.session_id.to_s,
        "as_of" => (run.finished_at || agent.finished_at || Time.now).iso8601,
        "through_run_count" => agent.run_count,
        "tracked_run_count" => previous&.fetch("tracked_run_count", 0).to_i + (run_cost.nil? ? 0 : 1),
        "missing_run_count" => previous&.fetch("missing_run_count", 0).to_i + (run_cost.nil? ? 1 : 0),
        "reason_unavailable" => reason
      }.compact
    end
    private_class_method :claude_session_snapshot

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
      when "pi"
        entries = usage_entries.select { |candidate| event_type(candidate) == "message_end" }
        costs = entries.filter_map { |entry| numeric_cost(metadata(entry)["total_cost_usd"]) }
        cost = costs.empty? ? nil : costs.sum
        cost_result(cost, "pi_message_end", cost.nil? ? "Pi did not report message costs" : nil)
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
      return "harness_estimate" if !run_cost.nil? && %w[claude opencode pi].include?(adapter)
      return "api_list_price_estimate" if !run_cost.nil? && adapter == "codex"

      "unavailable"
    end
    private_class_method :basis_for

    def codex_token_snapshots(adapter, usage_entries, previous:, prior_session_runs:)
      return [nil, nil] unless adapter == "codex"

      entry = usage_entries.reverse.find { |candidate| event_type(candidate) == "turn.completed" }
      values = metadata(entry)["usage"]
      return [nil, nil] unless values.is_a?(Hash)

      snapshot = %w[
        input_tokens cached_input_tokens cache_creation_input_tokens output_tokens reasoning_output_tokens
      ].each_with_object({}) do |key, result|
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
