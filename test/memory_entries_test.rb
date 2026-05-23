# frozen_string_literal: true

require "tmpdir"
require "fileutils"
require "time"
require "json"

require_relative "../lib/hq/domain/managed_agent"

# End-to-end test of the agent memory write path:
#   raw.log → Parser → ManagedAgent#capture_run_memory! → memory.jsonl
#
# For each Claude tool fixture under test/fixtures/parser/claude/<tool>.jsonl
# we synthesize a real raw.log (with a `=== [...] start ===` marker so that
# ManagedAgent#current_run_log_lines accepts it), construct a ManagedAgent
# pointing at a tmpdir, call the private #capture_run_memory!, and then
# assert the resulting memory.jsonl content one tool_summary line at a time.
#
# Pinning the persisted strings catches regressions in either the parser
# (per-tool body formatters) or in ManagedAgent#compact_system_summary —
# any drift in either path will surface here.
#
# Note: capture_run_memory! is private; this test calls it via #send. That's
# the intentional shortcut from option (a) — once that method is extracted
# into a more testable helper, this test should switch to the public seam.
module MemoryEntriesTest
  module_function

  FIXTURE_DIR = File.expand_path("fixtures/parser/claude", __dir__)

  def run!
    assert_bash_entries
    assert_read_entries
    assert_write_entries
    assert_grep_entries
    assert_glob_entries
    assert_agent_entries
    assert_skill_entries
    assert_structured_output_entries
    puts "memory_entries_test: ok"
  end

  def assert_bash_entries
    call, result = capture_summaries("bash")

    assert_summary(call, "Bash", "Bash: Inspect demo project status")
    assert_summary(result, "Bash", "tool result: Demo project status: healthy")
  end

  def assert_read_entries
    call, result = capture_summaries("read")

    assert_summary(call, "Read", "Read: example_status.rb")
    assert_summary(result, "Read", "tool result: 1\tmodule ExampleStatus")
  end

  def assert_write_entries
    call, result = capture_summaries("write")

    assert_summary(call, "Write", "Write: hq-public-review.md")
    assert_summary(result, "Write", "tool result: File created successfully at: /tmp/hq-public-review.md")
  end

  def assert_grep_entries
    call, result = capture_summaries("grep")

    assert_summary(call, "Grep", "Grep: def status  in /workspace/demo/app/models")
    assert_summary(result, "Grep", "tool result: app/models/example.rb:12:  def status")
  end

  def assert_glob_entries
    call, result = capture_summaries("glob")

    assert_summary(call, "Glob", "Glob: **/*_status_test.rb  in /workspace/demo/test")
    assert_summary(result, "Glob", "tool result: test/example_status_test.rb")
  end

  def assert_agent_entries
    call, result = capture_summaries("agent")

    assert_summary(call, "Agent", "Agent: Verify demo project readiness")
    assert_summary(result, "Agent", "tool result: Here are the demo findings:")
  end

  def assert_skill_entries
    call, result = capture_summaries("skill")

    assert_summary(call, "Skill", "Skill: /review demo change")
    assert_summary(result, "Skill", "tool result: Launching skill: review")
  end

  def assert_structured_output_entries
    call, result = capture_summaries("structuredoutput")

    # compact_system_summary truncates to 200 chars with a "..." tail; pin
    # the exact stored string so any change in truncation length is loud.
    expected_call = "StructuredOutput: success — Reviewed demo change. Parser fixtures use synthetic data only. " \
                    "Report written to /tmp/hq-public-review.md and opened for user."
    assert_summary(call, "StructuredOutput", expected_call)
    assert_summary(result, "StructuredOutput", "tool result: Structured output provided successfully")
  end

  # -- helpers --

  def capture_summaries(tool)
    Dir.mktmpdir("hq-memory-entries-test-#{tool}") do |dir|
      log_path = File.join(dir, "agent.raw.log")
      started_at = Time.now
      write_raw_log(log_path, started_at, tool)

      agent = build_agent(dir, log_path, started_at, tool)
      run = build_run(started_at, log_path)

      agent.send(:capture_run_memory!, run)

      summaries = read_tool_summaries(agent.memory_path)
      raise "expected 2 tool_summary events for #{tool}, got #{summaries.length}" unless summaries.length == 2

      summaries
    end
  end

  def write_raw_log(path, started_at, tool)
    fixture = File.readlines(File.join(FIXTURE_DIR, "#{tool}.jsonl"))
    marker = "=== [#{started_at.strftime("%Y-%m-%d %H:%M:%S")}] start ==="
    File.open(path, "w") do |file|
      file.puts(marker)
      file.write(fixture.join)
    end
  end

  def build_agent(workspace, log_path, started_at, tool)
    HQ::ManagedAgent.new(
      key: "memory-entries-test-#{tool}",
      name: "Memory Entries Test",
      project_key: "memory-entries-test",
      template_key: "implementer",
      workspace: workspace,
      prompt: "test",
      agent: "claude",
      log_path: log_path,
      created_at: started_at - 1,
      started_at: started_at,
      finished_at: started_at + 5
    )
  end

  def build_run(started_at, log_path)
    HQ::ManagedAgent::AgentRun.new(
      started_at: started_at,
      finished_at: started_at + 5,
      exit_code: 0,
      status: "success",
      log_path: log_path,
      command: "test"
    )
  end

  def read_tool_summaries(memory_path)
    raise "memory file not written: #{memory_path}" unless File.exist?(memory_path)

    File.foreach(memory_path).filter_map do |line|
      event = JSON.parse(line)
      next unless event["type"] == "tool_summary"

      event
    end
  end

  def assert_summary(event, expected_tool_name, expected_content)
    actual_tool_name = event["metadata"]&.dig("tool_name")
    assert(actual_tool_name == expected_tool_name,
           "expected tool_name=#{expected_tool_name.inspect}, got #{actual_tool_name.inspect}")
    assert(event["content"] == expected_content,
           "expected content=#{expected_content.inspect}, got #{event["content"].inspect}")
  end

  def assert(condition, message)
    raise message unless condition
  end
end

MemoryEntriesTest.run! if __FILE__ == $PROGRAM_NAME
