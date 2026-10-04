# frozen_string_literal: true

require "json"
require "tmpdir"

require_relative "../lib/hq/domain/managed_agent"

module ContextPressureTest
  module_function

  def run!
    assert_codex_measured_warning_and_acknowledgement
    assert_later_low_measurement_clears_warning
    assert_stale_measurement_does_not_warn
    assert_claude_compaction_is_reported_without_invented_limit
    assert_pi_compaction_is_reported
    assert_unsupported_harness_is_unknown
    puts "context_pressure_test: ok"
  end

  def assert_later_low_measurement_clears_warning
    with_agent("codex") do |agent, log|
      append(log, "type" => "event_msg", "payload" => {
        "type" => "token_count", "info" => {
          "last_token_usage" => { "total_tokens" => 90_000 }, "model_context_window" => 100_000
        }
      })
      append(log, "type" => "event_msg", "payload" => {
        "type" => "token_count", "info" => {
          "last_token_usage" => { "total_tokens" => 10_000 }, "model_context_window" => 100_000
        }
      })

      pressure = agent.context_pressure
      assert(pressure["state"] == "normal" && !pressure["warning"],
             "expected the latest valid low measurement to clear the earlier warning")
      assert(pressure["used_tokens"] == 10_000 && pressure["utilization"] == 0.1,
             "expected the latest measurement to define the current context state")
      assert(pressure["detail"] == "The harness reported 10% active-context usage.",
             "expected the normal measured report to use a percentage")
    end
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
      assert(pressure["detail"] == "The harness reported 90% active-context usage." &&
             !pressure["detail"].include?("90000"),
             "expected the measured report to show a percentage instead of an x-of-y count")
      agent.acknowledge_context_pressure!(pressure.fetch("signal_id"))
      assert(!agent.context_pressure["warning"] && agent.to_hash["context_pressure_acknowledged_signal"],
             "expected keep-going acknowledgement to persist")
      reloaded = HQ::ManagedAgent.from_hash(agent.to_hash)
      assert(reloaded.context_pressure["acknowledged"] && !reloaded.context_pressure["warning"],
             "expected the persisted acknowledgement to survive agent reload")
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
      assert(!pressure["detail"].match?(/\d+(?:\.\d+)?%/),
             "expected stale telemetry not to reuse a measured percentage")
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
      assert(!pressure["detail"].include?("%"),
             "expected compaction-only evidence without a limit not to invent a percentage")
    end
  end

  def assert_pi_compaction_is_reported
    with_agent("pi") do |agent, log|
      append(log, "type" => "compaction_end", "reason" => "threshold")
      pressure = agent.context_pressure
      assert(pressure["warning"] && pressure["basis"] == "reported", "expected Pi compaction warning")
      assert(!pressure["detail"].include?("%"), "expected reported compaction not to invent a percentage")
    end
  end

  def assert_unsupported_harness_is_unknown
    with_agent("custom") do |agent, log|
      append(log, "type" => "result", "usage" => { "input_tokens" => 500_000, "output_tokens" => 10 })
      pressure = agent.context_pressure
      assert(pressure["state"] == "unknown" && !pressure["warning"],
             "expected token totals without a context limit to stay unknown")
      assert(!pressure["detail"].include?("%"), "expected unsupported harness state not to invent a percentage")
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
