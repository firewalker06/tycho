# frozen_string_literal: true

require_relative "../lib/hq/parser"

# Per-tool parser regression tests for the Claude harness. Each fixture in
# test/fixtures/parser/claude/<tool>.jsonl is a literal pair from a real raw
# log: one `tool_use` event line followed by one `tool_result` event line.
# We parse the pair and assert the exact :tool_call and :tool_result content
# the parser emits, so any change to the per-tool body formatters or the
# tool-result preview logic is caught immediately.
module ParserTest
  module_function

  FIXTURE_DIR = File.expand_path("fixtures/parser/claude", __dir__)

  def run!
    assert_bash_tool
    assert_read_tool
    assert_write_tool
    assert_grep_tool
    assert_glob_tool
    assert_agent_tool
    assert_skill_tool
    assert_structured_output_tool
    puts "parser_test: ok"
  end

  def assert_bash_tool
    call, result = parse_fixture("bash")

    assert_call(call, "Bash", "Inspect demo project status\nbin/tycho app status demo --verbose")
    assert_result(result, "Bash", "Demo project status: healthy")
  end

  def assert_read_tool
    call, result = parse_fixture("read")

    assert_call(call, "Read", "example_status.rb")
    assert_result(result, "Read", "1\tmodule ExampleStatus")
  end

  def assert_write_tool
    call, result = parse_fixture("write")

    assert_call(call, "Write", "hq-public-review.md")
    assert_result(result, "Write", "File created successfully at: /tmp/hq-public-review.md")
  end

  def assert_grep_tool
    call, result = parse_fixture("grep")

    assert_call(call, "Grep", "def status  in /workspace/demo/app/models")
    assert_result(result, "Grep", "app/models/example.rb:12:  def status")
  end

  def assert_glob_tool
    call, result = parse_fixture("glob")

    assert_call(call, "Glob", "**/*_status_test.rb  in /workspace/demo/test")
    assert_result(result, "Glob", "test/example_status_test.rb")
  end

  def assert_agent_tool
    call, result = parse_fixture("agent")

    assert_call(call, "Agent", "Verify demo project readiness")
    assert_result(result, "Agent", "Here are the demo findings:")
  end

  def assert_skill_tool
    call, result = parse_fixture("skill")

    assert_call(call, "Skill", "/review demo change")
    assert_result(result, "Skill", "Launching skill: review")
  end

  def assert_structured_output_tool
    call, result = parse_fixture("structuredoutput")

    expected_summary = "success — Reviewed demo change. Parser fixtures use synthetic data only. " \
                       "Report written to /tmp/hq-public-review.md and opened for user."
    assert_call(call, "StructuredOutput", expected_summary)
    assert_result(result, "StructuredOutput", "Structured output provided successfully")
  end

  def parse_fixture(name)
    path = File.join(FIXTURE_DIR, "#{name}.jsonl")
    lines = File.readlines(path)
    _conversation, system = HQ::Parser.parse_stream(lines, agent_type: "claude")

    call = system.find { |entry| entry.type == :tool_call }
    result = system.find { |entry| entry.type == :tool_result }
    raise "missing tool_call in #{name} fixture" unless call
    raise "missing tool_result in #{name} fixture" unless result

    [call, result]
  end

  def assert_call(entry, expected_tool_name, expected_content)
    assert(entry.tool_name == expected_tool_name,
           "expected tool_call tool_name=#{expected_tool_name.inspect}, got #{entry.tool_name.inspect}")
    assert(entry.content == expected_content,
           "expected tool_call content=#{expected_content.inspect}, got #{entry.content.inspect}")
  end

  def assert_result(entry, expected_tool_name, expected_content)
    assert(entry.tool_name == expected_tool_name,
           "expected tool_result tool_name=#{expected_tool_name.inspect}, got #{entry.tool_name.inspect}")
    assert(entry.content == expected_content,
           "expected tool_result content=#{expected_content.inspect}, got #{entry.content.inspect}")
  end

  def assert(condition, message)
    raise message unless condition
  end
end

ParserTest.run! if __FILE__ == $PROGRAM_NAME
