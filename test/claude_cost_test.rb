# frozen_string_literal: true

require "json"
require "tmpdir"
require_relative "browser/claude_cost_fixture"
require_relative "agent_cost_snapshot_test"

module ClaudeCostTest
  module_function

  def run!
    agent = AgentCostSnapshotTest.agent("claude", [])
    [1.25, 2.0, 2.5].each_with_index do |total, index|
      run = AgentCostSnapshotTest.run("retained-cost-session", index + 1)
      agent.runs << run
      lines = File.readlines(File.join(__dir__, "fixtures/claude_cost/resumed-#{index + 1}.jsonl"))
      _conversation, system = HQ::Parser.parse_stream(lines, agent_type: "claude")
      entries = system.select { |entry| entry.type == :usage }
      snapshot = HQ::AgentCostSnapshot.advance(agent:, run:, usage_entries: entries)
      assert(snapshot["amount_usd"] == total, "expected latest Claude session total #{total}, got #{snapshot["amount_usd"]}")
      assert(snapshot["run_amount_usd"] == [1.25, 0.75, 0.5][index], "expected only this run's estimated cost")
      agent.cost_snapshot = JSON.parse(JSON.generate(snapshot))
    end
    Dir.mktmpdir("claude-cost-retained") do |root|
      agent = ClaudeCostFixture.build(root, root)
      summaries = HQ::AgentMemory.new(agent).events.select { |event| event["type"] == "run_summary" }
      assert(summaries.map { |event| event.dig("metadata", "cost_snapshot", "run_amount_usd") } == [1.25, 0.75, 0.5],
             "expected retained run summaries to preserve costs across reloads")
      records = HQ::UsageMetrics::Store.new(path: File.join(root, "cost-metrics.json")).runs.sort_by { |record| record["started_at"] }
      assert(records.map { |record| record.dig("estimated_cost", "amount_usd") } == [1.25, 0.75, 0.5],
             "expected metrics to use run deltas rather than resumed session totals")
      assert(records.last["model_attribution"].all? { |item| item["scope"] == "session" },
             "expected cumulative model attribution to declare its scope")
      historical = HQ::UsageMetrics::Normalizer.new(
        agent:, run: agent.runs.first, source: "test",
        usage_entries: HQ::Parser.parse_stream(File.readlines(File.join(__dir__, "fixtures/claude_cost/resumed-1.jsonl")), agent_type: "claude").last.select { |entry| entry.type == :usage }
      ).record
      assert(historical.dig("estimated_cost", "amount_usd").nil?, "expected historical normalization not to borrow the latest run cost")
      before = File.binread(agent.memory_path)
      restored = HQ::ManagedAgent.from_hash(JSON.parse(JSON.generate(agent.to_hash)))
      assert(restored.cost_snapshot["amount_usd"] == 2.5 && File.binread(agent.memory_path) == before,
             "expected loading to preserve saved summaries and latest total")
    end
    assert_edges
    puts "claude_cost_test: ok"
  end

  def assert_edges
    helper = AgentCostSnapshotTest
    first = helper.run("session", 1)
    agent = helper.agent("claude", [first])
    entries = [helper.usage("result", "total_cost_usd" => 1.25, "claude_code_version" => "2.1.311")]
    snapshot = HQ::AgentCostSnapshot.advance(agent:, run: first, usage_entries: entries)
    agent.cost_snapshot = snapshot
    assert(HQ::AgentCostSnapshot.advance(agent:, run: first, usage_entries: entries) == snapshot,
           "expected duplicate finalization to leave the cost unchanged")
    missing = helper.run("session", 2)
    agent.runs << missing
    snapshot = HQ::AgentCostSnapshot.advance(agent:, run: missing, usage_entries: [])
    assert(snapshot["run_amount_usd"].nil? && snapshot["amount_usd"] == 1.25,
           "expected missing evidence to preserve the last session total without a zero run cost")
    agent.cost_snapshot = JSON.parse(JSON.generate(snapshot))
    next_run = helper.run("session", 3)
    agent.runs << next_run
    entries = [helper.usage("result", "total_cost_usd" => 2.5, "claude_code_version" => "2.1.311")]
    snapshot = HQ::AgentCostSnapshot.advance(agent:, run: next_run, usage_entries: entries)
    assert(snapshot["run_amount_usd"].nil? && snapshot["amount_usd"] == 2.5,
           "expected a gap to prevent attributing two runs' spend to one run")
    agent.cost_snapshot = snapshot
    fourth = helper.run("session", 4)
    agent.runs << fourth
    entries << helper.usage("result", "total_cost_usd" => 3.0, "claude_code_version" => "2.1.311")
    entries << entries.last
    snapshot = HQ::AgentCostSnapshot.advance(agent:, run: fourth, usage_entries: entries)
    assert(snapshot["run_amount_usd"] == 0.5, "expected only the last result after retries and duplicates")
    agent.cost_snapshot = snapshot
    fifth = helper.run("session", 5)
    agent.runs << fifth
    entries = [helper.usage("result", "total_cost_usd" => 0.0, "subtype" => "error_during_execution", "claude_code_version" => "2.1.311")]
    snapshot = HQ::AgentCostSnapshot.advance(agent:, run: fifth, usage_entries: entries)
    assert(snapshot["run_amount_usd"].nil? && snapshot["amount_usd"] == 3.0,
           "expected crash-zeroed cost to remain unavailable")
    agent.cost_snapshot = { "amount_usd" => 458.58, "session_id" => "session", "through_run_count" => 4 }
    entries = [helper.usage("result", "total_cost_usd" => 30.201749, "claude_code_version" => "2.1.311")]
    snapshot = HQ::AgentCostSnapshot.advance(agent:, run: fifth, usage_entries: entries)
    assert(snapshot["amount_usd"] == 30.201749 && snapshot["run_amount_usd"].nil?,
           "expected an old inflated snapshot never to be a subtraction baseline")
    agent.cost_snapshot = { "reported_amount_usd" => 40, "reported_cost_scope" => "session", "session_id" => "session", "through_run_count" => 4 }
    snapshot = HQ::AgentCostSnapshot.advance(agent:, run: fifth, usage_entries: entries)
    assert(snapshot["run_amount_usd"].nil?, "expected a decreasing total not to fabricate a run cost")
    old_entries = [helper.usage("result", "total_cost_usd" => 0.75, "claude_code_version" => "2.1.276")]
    snapshot = HQ::AgentCostSnapshot.advance(agent:, run: fifth, usage_entries: old_entries)
    assert(snapshot["run_amount_usd"] == 0.75, "expected older Claude to retain per-call semantics")
  end

  def assert(condition, message)
    raise message unless condition
  end
end

ClaudeCostTest.run! if $PROGRAM_NAME == __FILE__
