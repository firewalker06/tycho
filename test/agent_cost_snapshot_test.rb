# frozen_string_literal: true

require "time"

require_relative "../lib/hq/domain/agent_cost_snapshot"
require_relative "../lib/hq/parser"

module AgentCostSnapshotTest
  module_function

  FakeAgent = Struct.new(:agent, :model, :cost_snapshot, :runs, :finished_at, keyword_init: true) do
    def run_count
      runs.length
    end
  end
  FakeRun = Struct.new(:session_id, :finished_at, keyword_init: true)

  def run!
    assert_claude_cost_accumulates_per_session
    assert_session_change_resets_cost
    assert_opencode_sums_step_costs
    assert_missing_history_is_marked_partial
    assert_codex_estimates_cost_from_cumulative_token_deltas
    assert_unknown_codex_model_stays_unpriced
    assert_missing_cost_is_not_treated_as_zero
    puts "agent_cost_snapshot_test: ok"
  end

  def assert_claude_cost_accumulates_per_session
    first_run = run("session-1", 1)
    agent = agent("claude", [first_run])
    first = advance(agent, first_run, [usage("result", "total_cost_usd" => 1.25)])

    second_run = run("session-1", 2)
    agent.cost_snapshot = first
    agent.runs << second_run
    second = advance(agent, second_run, [usage("result", "total_cost_usd" => 0.75)])

    assert(second["amount_usd"] == 2.0, "expected Claude session cost to accumulate")
    assert(second["run_amount_usd"] == 0.75, "expected the latest Claude run cost")
    assert(second["coverage"] == "complete", "expected complete tracking from the first run")
    assert(second["basis"] == "harness_estimate", "expected Claude costs to remain estimates")
  end

  def assert_session_change_resets_cost
    old = {
      "amount_usd" => 4.0,
      "basis" => "harness_estimate",
      "coverage" => "complete",
      "session_id" => "session-1",
      "tracked_run_count" => 3,
      "missing_run_count" => 0
    }
    new_run = run("session-2", 4)
    agent = agent("claude", [run("session-1", 1), run("session-1", 2), run("session-1", 3), new_run], old)
    snapshot = advance(agent, new_run, [usage("result", "total_cost_usd" => 0.5)])

    assert(snapshot["amount_usd"] == 0.5, "expected a new native session to reset the total")
    assert(snapshot["coverage"] == "complete", "expected a newly observed session to have complete coverage")
  end

  def assert_opencode_sums_step_costs
    current_run = run("open-session", 1)
    agent = agent("opencode", [current_run])
    entries = [
      usage("step_finish", "total_cost_usd" => 0.1),
      usage("step_finish", "total_cost_usd" => 0.25),
      usage("message", "total_cost_usd" => 99)
    ]
    snapshot = advance(agent, current_run, entries)

    assert((snapshot["run_amount_usd"] - 0.35).abs < 0.000_001,
           "expected only OpenCode step costs to be summed")
    assert(snapshot["source"] == "opencode_step_finish", "expected the OpenCode source label")
  end

  def assert_missing_history_is_marked_partial
    old_run = run("session-1", 1)
    current_run = run("session-1", 2)
    agent = agent("claude", [old_run, current_run])
    snapshot = advance(agent, current_run, [usage("result", "total_cost_usd" => 0.5)])

    assert(snapshot["amount_usd"] == 0.5, "expected tracking to begin with the completed run")
    assert(snapshot["coverage"] == "partial", "expected older untracked runs to keep coverage partial")
  end

  def assert_codex_estimates_cost_from_cumulative_token_deltas
    first_run = run("codex-session", 1)
    agent = agent("codex", [first_run])
    first = advance(agent, first_run, [usage("turn.completed", "usage" => {
      "input_tokens" => 100,
      "cached_input_tokens" => 40,
      "output_tokens" => 20,
      "reasoning_output_tokens" => 5
    })])

    second_run = run("codex-session", 2)
    agent.cost_snapshot = first
    agent.runs << second_run
    second = advance(agent, second_run, [usage("turn.completed", "usage" => {
      "input_tokens" => 175,
      "cached_input_tokens" => 90,
      "output_tokens" => 32,
      "reasoning_output_tokens" => 8
    })])

    assert((first["run_amount_usd"] - 0.00092).abs < 0.000_000_001,
           "expected the first Codex run to use its cumulative token snapshot")
    assert((second["run_amount_usd"] - 0.00051).abs < 0.000_000_001,
           "expected the resumed Codex run to price only its token delta")
    assert((second["amount_usd"] - 0.00143).abs < 0.000_000_001,
           "expected Codex session cost to accumulate")
    assert(second["token_snapshot"]["input_tokens"] == 175, "expected cumulative Codex tokens")
    assert(second["run_tokens"]["input_tokens"] == 75, "expected Codex run deltas")
    assert(second["run_tokens"]["cached_input_tokens"] == 50, "expected cached-token deltas")
    assert(second["basis"] == "api_list_price_estimate", "expected API list-price basis")
    assert(second["model"] == "gpt-5.5", "expected the priced model to persist")
    assert(second.dig("pricing", "output_usd_per_million") == 30.0,
           "expected the applied output price to persist")
  end

  def assert_unknown_codex_model_stays_unpriced
    current_run = run("codex-session", 1)
    agent = agent("codex", [current_run], nil, model: "codex-auto-review")
    snapshot = advance(agent, current_run, [usage("turn.completed", "usage" => {
      "input_tokens" => 100,
      "cached_input_tokens" => 40,
      "output_tokens" => 20
    })])

    assert(snapshot["amount_usd"].nil?, "expected unknown Codex models to stay unpriced")
    assert(snapshot["reason_unavailable"].include?("No OpenAI list price"),
           "expected an explicit missing-price reason")
    assert(snapshot["token_snapshot"]["input_tokens"] == 100,
           "expected token telemetry to survive missing pricing")
  end

  def assert_missing_cost_is_not_treated_as_zero
    current_run = run("session-1", 1)
    agent = agent("claude", [current_run])
    snapshot = advance(agent, current_run, [usage("result", {})])

    assert(snapshot["amount_usd"].nil?, "expected a missing cost to stay unavailable")
    assert(snapshot["coverage"] == "unavailable", "expected unavailable coverage")
    assert(snapshot["missing_run_count"] == 1, "expected the unpriced run to be counted")
  end

  def agent(harness, runs, cost_snapshot = nil, model: nil)
    model ||= "gpt-5.5" if harness == "codex"
    FakeAgent.new(
      agent: harness,
      model: model,
      runs: runs,
      cost_snapshot: cost_snapshot,
      finished_at: runs.last&.finished_at
    )
  end

  def run(session_id, index)
    time = Time.utc(2026, 7, 22, 10, index, 0)
    FakeRun.new(session_id: session_id, finished_at: time)
  end

  def usage(event_type, values)
    HQ::Parser::SystemEntry.new(
      type: :usage,
      content: "usage",
      timestamp: Time.now,
      tool_name: nil,
      metadata: { "event_type" => event_type }.merge(values)
    )
  end

  def advance(agent, current_run, entries)
    HQ::AgentCostSnapshot.advance(agent: agent, run: current_run, usage_entries: entries)
  end

  def assert(condition, message)
    raise message unless condition
  end
end

AgentCostSnapshotTest.run! if $PROGRAM_NAME == __FILE__
