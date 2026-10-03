# frozen_string_literal: true

require "json"
require "tmpdir"

require_relative "../lib/hq/domain/managed_agent"

module ContextPressureTest
  module_function

  def run!
    assert_codex_measured_warning_and_acknowledgement
    assert_stale_measurement_does_not_warn
    assert_claude_compaction_is_reported_without_invented_limit
    assert_pi_compaction_is_reported
    assert_unsupported_harness_is_unknown
    puts "context_pressure_test: ok"
  end

  def assert_codex_measured_warning_and_acknowledgement
    with_agent("codex") do |agent, log|
      append(log, "type" => "event_msg", "payload" => {
        "type" => "token_count", "info" => {
          "last_token_usage" => { "total_tokens" => 90_000 }, "model_context_window" => 100_000
        }
      })
      pressure = agent.context_pressure
      assert(pressure["warning"] && pressure["basis"] == "measured", "expected measured Codex warning")
      assert(pressure["used_tokens"] == 90_000 && pressure["limit_tokens"] == 100_000,
             "expected exact harness values")
      agent.acknowledge_context_pressure!(pressure.fetch("signal_id"))
      assert(!agent.context_pressure["warning"] && agent.to_hash["context_pressure_acknowledged_signal"],
             "expected keep-going acknowledgement to persist")
    end
  end

  def assert_stale_measurement_does_not_warn
    with_agent("codex") do |agent, log|
      append(log, "type" => "event_msg", "payload" => {
        "type" => "token_count", "info" => {
          "last_token_usage" => { "total_tokens" => 90_000 }, "model_context_window" => 100_000
        }
      })
      File.open(log, "a") { |file| file.puts("=== [2026-10-03 05:00:00] start ===") }
      append(log, "type" => "turn.completed", "usage" => { "input_tokens" => 999_999 })
      pressure = agent.context_pressure
      assert(pressure["state"] == "stale" && !pressure["warning"],
             "expected a later run without context telemetry to make the old percentage stale")
    end
  end

  def assert_claude_compaction_is_reported_without_invented_limit
    with_agent("claude") do |agent, log|
      append(log, "type" => "system", "subtype" => "compact_boundary", "compact_metadata" => {
        "trigger" => "auto", "pre_tokens" => 167_000, "post_tokens" => 12_000
      })
      pressure = agent.context_pressure
      assert(pressure["warning"] && pressure["source"] == "harness_compaction", "expected Claude compaction warning")
      assert(pressure["basis"] == "measured" && pressure["limit_tokens"].nil?,
             "expected measured before/after values without an invented limit")
    end
  end

  def assert_pi_compaction_is_reported
    with_agent("pi") do |agent, log|
      append(log, "type" => "compaction_end", "reason" => "threshold")
      pressure = agent.context_pressure
      assert(pressure["warning"] && pressure["basis"] == "reported", "expected Pi compaction warning")
    end
  end

  def assert_unsupported_harness_is_unknown
    with_agent("custom") do |agent, log|
      append(log, "type" => "result", "usage" => { "input_tokens" => 500_000, "output_tokens" => 10 })
      pressure = agent.context_pressure
      assert(pressure["state"] == "unknown" && !pressure["warning"],
             "expected token totals without a context limit to stay unknown")
    end
  end

  def with_agent(harness)
    Dir.mktmpdir("tycho-context-pressure") do |dir|
      log = File.join(dir, "agent.raw.log")
      File.write(log, "=== [2026-10-03 04:00:00] start ===\n")
      agent = HQ::ManagedAgent.new(
        key: "context-agent", name: "Context agent", project_key: "demo", template_key: "custom",
        workspace: dir, prompt: "Prompt", agent: harness, log_path: log
      )
      yield agent, log
    end
  end

  def append(path, payload)
    File.open(path, "a") { |file| file.puts(JSON.generate(payload)) }
  end

  def assert(condition, message)
    raise message unless condition
  end
end

ContextPressureTest.run!
