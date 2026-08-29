# frozen_string_literal: true

require_relative "../lib/hq/parser"
require_relative "../lib/hq/domain/agent_structured_result"

# Per-tool parser regression tests for the Claude harness use real raw-log
# pairs. OpenCode fixtures are sanitized from `opencode run --format json`
# output so parser coverage stays anchored to observed event shapes.
module ParserTest
  module_function

  CLAUDE_FIXTURE_DIR = File.expand_path("fixtures/parser/claude", __dir__)
  OPENCODE_FIXTURE_DIR = File.expand_path("fixtures/parser/opencode", __dir__)
  PI_FIXTURE_DIR = File.expand_path("fixtures/parser/pi", __dir__)

  def run!
    assert_bash_tool
    assert_read_tool
    assert_write_tool
    assert_grep_tool
    assert_glob_tool
    assert_agent_tool
    assert_skill_tool
    assert_structured_output_tool
    assert_opencode_basic_stream
    assert_opencode_tool_use_stream
    assert_opencode_structured_stream
    assert_opencode_permission_denied_stream
    assert_opencode_resume_stream
    assert_pi_structured_stream
    assert_pi_error_stream
    assert_chat_blocks_use_sequence_for_equal_timestamps
    assert_codex_turn_completed_usage_metadata
    assert_claude_result_usage_metadata
    assert_opencode_step_finish_usage_metadata
    puts "parser_test: ok"
  end

  def assert_bash_tool
    call, result = parse_fixture("bash")

    assert_call(call, "Bash", "Inspect demo agent status\nbin/tycho agent status demo-agent")
    assert_result(result, "Bash", "Demo agent status: succeeded")
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

  def assert_opencode_basic_stream
    conversation, system = parse_opencode_fixture("basic")
    usage = system.find { |entry| entry.type == :usage }

    assert(conversation.map(&:content) == ["FIXTURE_OK"],
           "expected OpenCode assistant text, got #{conversation.map(&:content).inspect}")
    assert(usage.content.include?("7 output"), "expected OpenCode usage summary, got #{usage.content.inspect}")
  end

  def assert_opencode_tool_use_stream
    conversation, system = parse_opencode_fixture("tool_use")
    call = system.find { |entry| entry.type == :tool_call }
    result = system.find { |entry| entry.type == :tool_result }
    usage = system.select { |entry| entry.type == :usage }.last

    assert(conversation.map(&:content) == ["TOOL_DONE fixture-file-value"],
           "expected OpenCode final text, got #{conversation.map(&:content).inspect}")
    assert_call(call, "bash", "cat fixture_tool_ok.txt")
    assert_result(result, "bash", "fixture-file-value")
    assert(usage.content.include?("13 output"), "expected OpenCode final usage summary, got #{usage.content.inspect}")
  end

  def assert_opencode_structured_stream
    lines = opencode_fixture_lines("structured")
    conversation, system = HQ::Parser.parse_stream(lines, agent_type: "opencode")
    structured = HQ::AgentStructuredResult.from_log_lines(lines)
    usage = system.find { |entry| entry.type == :usage }

    assert(conversation.map(&:content) == ["STRUCTURED_OK"],
           "expected OpenCode structured text, got #{conversation.map(&:content).inspect}")
    assert(structured["summary"] == "STRUCTURED_OK",
           "expected structured summary from OpenCode fixture, got #{structured.inspect}")
    assert(structured["attachments"].first["path"] == "/tmp/opencode-fixture.txt",
           "expected structured attachment from OpenCode fixture, got #{structured.inspect}")
    assert(usage.content.include?("37 output"), "expected OpenCode structured usage, got #{usage.content.inspect}")
  end

  def assert_opencode_permission_denied_stream
    conversation, system = parse_opencode_fixture("permission_bash_denied")
    calls = system.select { |entry| entry.type == :tool_call }
    results = system.select { |entry| entry.type == :tool_result }

    assert(conversation.first.content.include?("don't have access to a Bash tool"),
           "expected denied bash explanation, got #{conversation.first&.content.inspect}")
    assert(conversation.last.content.include?("permission target"),
           "expected permission fixture final text, got #{conversation.last&.content.inspect}")
    assert(calls.map(&:tool_name) == %w[glob read],
           "expected glob/read calls after bash deny, got #{calls.map(&:tool_name).inspect}")
    assert_result(results.last, "read", "permission target")
  end

  def assert_opencode_resume_stream
    conversation, system = parse_opencode_fixture("resume")
    session_ids = (conversation + system).filter_map { |entry| entry.metadata["sessionID"] }.uniq

    assert(conversation.map(&:content) == %w[RESUME_ONE RESUME_TWO],
           "expected two resumed OpenCode messages, got #{conversation.map(&:content).inspect}")
    assert(session_ids == ["ses_fixture_resume"],
           "expected one resumed session id, got #{session_ids.inspect}")
  end

  def assert_pi_structured_stream
    lines = File.readlines(File.join(PI_FIXTURE_DIR, "structured.jsonl"))
    conversation, system = HQ::Parser.parse_stream(lines, agent_type: "pi")
    structured = HQ::AgentStructuredResult.from_log_lines(lines)
    call = system.find { |entry| entry.type == :tool_call }
    result = system.find { |entry| entry.type == :tool_result }
    usage = system.find { |entry| entry.type == :usage }
    statuses = system.select { |entry| entry.type == :status }

    assert(conversation.map(&:content) == ["PI_FIXTURE_OK"],
           "expected Pi structured summary display, got #{conversation.map(&:content).inspect}")
    assert_call(call, "read", '{"path":"fixture.txt"}')
    assert_result(result, "read", "fixture value")
    assert(usage.metadata["usage"]["cache_read_input_tokens"] == 40,
           "expected Pi cache telemetry to normalize")
    assert(usage.metadata["total_cost_usd"] == 0.0033,
           "expected Pi reported cost to survive parsing")
    assert(structured["summary"] == "PI_FIXTURE_OK", "expected Pi structured result extraction")
    assert(structured.dig("attachments", 0, "path") == "/tmp/pi-fixture.txt",
           "expected Pi structured attachment extraction")
    assert(statuses.map { |entry| entry.metadata["event_type"] } == %w[session turn_end agent_end],
           "expected durable Pi session and terminal lifecycle statuses")
    assert(statuses.first.metadata["session_id"] == "00000000-1111-4222-8333-444444444444" &&
           statuses.first.metadata["session_version"] == 3,
           "expected useful Pi session metadata")
    assert(statuses.drop(1).all? { |entry| entry.metadata["status"] == "completed" },
           "expected completed Pi turn and agent terminal statuses")
    lifecycle_content = statuses.map(&:content)
    assert(HQ::Parser.compose_chat_blocks(conversation, system).none? { |block| lifecycle_content.include?(block.content) },
           "expected Pi lifecycle records not to flood conversation blocks")
  end

  def assert_pi_error_stream
    lines = File.readlines(File.join(PI_FIXTURE_DIR, "errors.jsonl"))
    _conversation, system = HQ::Parser.parse_stream(lines, agent_type: "pi")
    errors = system.select { |entry| entry.type == :error }.map(&:content)

    assert(errors.any? { |text| text.include?("Permission denied") }, "expected denied Pi tool error")
    assert(errors.include?("Fixture provider error"), "expected Pi provider error")
    assert(errors.include?("Fixture retries exhausted"), "expected Pi retry exhaustion")
    malformed = system.find { |entry| entry.metadata&.dig("event_type") == "tycho.pi.malformed_json" }
    assert(malformed&.content == "Pi emitted a malformed JSON stream record; Tycho ignored it.",
           "expected malformed Pi JSON to surface a credential-safe error")
    assert(malformed.metadata["record_bytes"].positive? && !malformed.metadata.key?("raw"),
           "expected malformed Pi diagnostics without raw stream content")
  end

  def assert_chat_blocks_use_sequence_for_equal_timestamps
    timestamp = Time.utc(2026, 6, 14, 8, 0, 0)
    conversation = [
      HQ::Parser::ConversationEntry.new(
        role: "assistant",
        content: "assistant first",
        timestamp:,
        metadata: { "_sequence" => 1 }
      )
    ]
    system = [
      HQ::Parser::SystemEntry.new(
        type: :run_summary,
        content: "run summary last",
        timestamp:,
        tool_name: nil,
        metadata: { "_sequence" => 2, "summary_id" => "summary-2" }
      )
    ]

    blocks = HQ::Parser.compose_chat_blocks(conversation, system)

    assert(blocks.map(&:kind) == %i[message run_summary],
           "expected equal-timestamp blocks to use metadata sequence, got #{blocks.map(&:kind).inspect}")
    assert(blocks.last.metadata["summary_id"] == "summary-2",
           "expected summary metadata to survive chat block composition")
  end

  def assert_codex_turn_completed_usage_metadata
    lines = [
      '{"type":"turn.completed","usage":{"input_tokens":13283428,"cached_input_tokens":12080128,"output_tokens":51480,"reasoning_output_tokens":12370}}'
    ]
    _conversation, system = HQ::Parser.parse_stream(lines, agent_type: "codex")
    usage = system.find { |entry| entry.type == :usage }
    blocks = HQ::Parser.compose_chat_blocks([], system)
    summary = blocks.find { |block| block.kind == :summary }

    assert(usage.content.include?("12370 reasoning output"),
           "expected Codex usage content to include reasoning tokens, got #{usage.content.inspect}")
    assert(usage.metadata["usage"]["cached_input_tokens"] == 12_080_128,
           "expected Codex usage metadata to keep full usage payload, got #{usage.metadata.inspect}")
    assert(summary.metadata["event_type"] == "turn.completed",
           "expected Codex summary block to retain turn.completed metadata, got #{summary.metadata.inspect}")
    assert(summary.metadata["usage"]["reasoning_output_tokens"] == 12_370,
           "expected Codex summary metadata to expose reasoning tokens, got #{summary.metadata.inspect}")
  end

  def assert_claude_result_usage_metadata
    lines = [
      '{"type":"result","subtype":"success","duration_ms":26054,"duration_api_ms":24747,"ttft_ms":19457,"num_turns":2,"total_cost_usd":3.39366625,"usage":{"input_tokens":2,"cache_creation_input_tokens":537245,"cache_read_input_tokens":0,"output_tokens":1435,"server_tool_use":{"web_search_requests":0,"web_fetch_requests":0}}}'
    ]
    _conversation, system = HQ::Parser.parse_stream(lines, agent_type: "claude")
    usage = system.find { |entry| entry.type == :usage }
    blocks = HQ::Parser.compose_chat_blocks([], system)
    summary = blocks.find { |block| block.kind == :summary }

    assert(usage.metadata["event_type"] == "result",
           "expected Claude usage metadata to identify result events, got #{usage.metadata.inspect}")
    assert(usage.metadata["usage"]["cache_creation_input_tokens"] == 537_245,
           "expected Claude usage metadata to keep cache creation tokens, got #{usage.metadata.inspect}")
    assert(usage.metadata["duration_api_ms"] == 24_747,
           "expected Claude usage metadata to keep API duration, got #{usage.metadata.inspect}")
    assert(summary.metadata["event_type"] == "result",
           "expected Claude summary block to retain result metadata, got #{summary.metadata.inspect}")
    assert(summary.metadata["total_cost_usd"] == 3.39366625,
           "expected Claude summary metadata to expose total cost, got #{summary.metadata.inspect}")
  end

  def assert_opencode_step_finish_usage_metadata
    lines = [
      '{"type":"step_finish","timestamp":1783439777672,"sessionID":"ses_fixture","part":{"id":"prt_fixture","reason":"tool-calls","type":"step-finish","tokens":{"total":11952,"input":11753,"output":151,"reasoning":48,"cache":{"write":7,"read":11}},"cost":0.00170114}}'
    ]
    _conversation, system = HQ::Parser.parse_stream(lines, agent_type: "opencode")
    usage = system.find { |entry| entry.type == :usage }
    blocks = HQ::Parser.compose_chat_blocks([], system)
    summary = blocks.find { |block| block.kind == :summary }

    assert(usage.content.include?("11952 total"),
           "expected OpenCode usage content to include total tokens, got #{usage.content.inspect}")
    assert(usage.metadata["event_type"] == "step_finish",
           "expected OpenCode usage metadata to identify step_finish events, got #{usage.metadata.inspect}")
    assert(usage.metadata["usage"]["cache_creation_input_tokens"] == 7,
           "expected OpenCode usage metadata to normalize cache write tokens, got #{usage.metadata.inspect}")
    assert(summary.metadata["usage"]["reasoning_output_tokens"] == 48,
           "expected OpenCode summary metadata to expose reasoning tokens, got #{summary.metadata.inspect}")
  end

  def parse_fixture(name)
    path = File.join(CLAUDE_FIXTURE_DIR, "#{name}.jsonl")
    lines = File.readlines(path)
    _conversation, system = HQ::Parser.parse_stream(lines, agent_type: "claude")

    call = system.find { |entry| entry.type == :tool_call }
    result = system.find { |entry| entry.type == :tool_result }
    raise "missing tool_call in #{name} fixture" unless call
    raise "missing tool_result in #{name} fixture" unless result

    [call, result]
  end

  def parse_opencode_fixture(name)
    HQ::Parser.parse_stream(opencode_fixture_lines(name), agent_type: "opencode")
  end

  def opencode_fixture_lines(name)
    path = File.join(OPENCODE_FIXTURE_DIR, "#{name}.jsonl")
    File.readlines(path)
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
