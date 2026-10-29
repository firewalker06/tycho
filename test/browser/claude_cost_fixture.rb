# frozen_string_literal: true

require_relative "../../lib/hq/domain/managed_agent"

module ClaudeCostFixture
  module_function

  def build(root, workspace, with_legacy: false)
    FileUtils.mkdir_p(File.join(root, "agents"))
    log_path = File.join(root, "agents", "claude-cost.raw.log")
    agent = HQ::ManagedAgent.new(
      key: "web-agent-claude-cost", name: "Claude run cost", project_key: "web", template_key: "custom",
      workspace:, prompt: "Synthetic cost fixture only", agent: "claude", log_path:,
      session_id: "retained-cost-session", session_bootstrapped: true
    )
    if with_legacy
      HQ::AgentMemory.new(agent).append_run_summary!(
        summary: "Historical saved estimate remains unchanged.", status: "success", created_at: Time.utc(2026, 10, 27),
        metadata: { "summary_id" => "legacy-cost", "run_id" => "legacy-cost", "run_number" => 0,
                    "cost_snapshot" => { "amount_usd" => 458.58, "coverage" => "partial" } }
      )
    end
    metrics_store = HQ::UsageMetrics::Store.new(path: File.join(root, "cost-metrics.json"))
    3.times do |index|
      started_at = Time.utc(2026, 10, 28, 10, index * 5, 0)
      offset = File.exist?(log_path) ? File.size(log_path) : 0
      File.open(log_path, "a") do |file|
        file.puts "=== [#{started_at.strftime("%Y-%m-%d %H:%M:%S")}] start ==="
        file.write(File.read(File.join(__dir__, "../fixtures/claude_cost/resumed-#{index + 1}.jsonl")))
      end
      run = HQ::ManagedAgent::AgentRun.new(
        run_id: "cost-run-#{index + 1}", started_at:, finished_at: started_at + 10,
        status: "success", exit_code: 0, agent: "claude", log_path:, log_start_offset: offset,
        session_id: "retained-cost-session", command: index.zero? ? "claude -p" : "claude -p --resume retained-cost-session"
      )
      data = agent.to_hash.merge("started_at" => started_at.iso8601, "finished_at" => run.finished_at.iso8601,
                                 "summary" => "Completed fixture run #{index + 1}.", "last_exit_code" => 0)
      agent = HQ::ManagedAgent.from_hash(JSON.parse(JSON.generate(data)))
      agent.summary = "Completed fixture run #{index + 1}."
      agent.structured_result = { "status" => "success", "summary" => agent.summary }
      agent.usage_metrics_store = metrics_store
      agent.runs << run
      agent.send(:capture_run_memory!, run)
    end
    agent
  end
end

if $PROGRAM_NAME == __FILE__
  root = ENV.fetch("TYCHO_LOGS_ROOT")
  agent = ClaudeCostFixture.build(root, ARGV.fetch(0), with_legacy: ARGV.include?("--with-legacy"))
  File.write(File.join(root, "managed_agents.json"), JSON.generate([agent.to_hash]))
end
