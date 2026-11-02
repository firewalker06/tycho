# frozen_string_literal: true

require_relative "../../lib/hq/domain/managed_agent"

# Numeric examples only. No source conversation or private payload is copied.
module UsageScopeFixture
  module_function

  def snapshots
    {
      125 => nil,
      126 => {
        "currency" => "USD", "run_cost_scope" => "run", "session_id" => "fixture-session",
        "basis" => "api_list_price_estimate", "coverage" => "complete", "through_run_count" => 126,
        "run_amount_usd" => 0.0579388, "amount_usd" => 30.1711088
      },
      127 => {
        "run_cost_scope" => "run", "session_id" => "fixture-session", "coverage" => "partial",
        "through_run_count" => 127, "amount_usd" => 30.774118
      }
    }
  end

  def build(root, workspace)
    FileUtils.mkdir_p(File.join(root, "agents"))
    agent = HQ::ManagedAgent.new(
      key: "web-agent-usage-scope", name: "Usage scope example", project_key: "web", template_key: "custom",
      workspace:, prompt: "Synthetic usage fixture", agent: "codex", model: "gpt-6.1-sol",
      log_path: File.join(root, "agents", "usage-scope.raw.log")
    )
    127.times do |index|
      time = Time.utc(2026, 10, 29) + index * 60
      agent.runs << HQ::ManagedAgent::AgentRun.new(run_id: "fixture-#{index + 1}", started_at: time,
                                                finished_at: time + 10, status: "success", exit_code: 0,
                                                session_id: "fixture-session")
    end
    snapshots.each do |number, snapshot|
      HQ::AgentMemory.new(agent).append_run_summary!(
        summary: "Saved usage example for run #{number}.", status: "success",
        created_at: agent.runs[number - 1].finished_at,
        metadata: { "summary_id" => "usage-#{number}", "run_id" => "fixture-#{number}",
                    "run_number" => number, "cost_snapshot" => snapshot }
      )
    end
    agent.cost_snapshot = snapshots.fetch(127)
    agent.summary = "Saved usage example for run 127."
    File.write(File.join(root, "managed_agents.json"), JSON.generate([agent.to_hash]))
  end
end

UsageScopeFixture.build(ENV.fetch("TYCHO_LOGS_ROOT"), ARGV.fetch(0)) if $PROGRAM_NAME == __FILE__
