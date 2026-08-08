# frozen_string_literal: true

require "json"
require "rbconfig"
require "stringio"
require "tmpdir"
require_relative "../lib/hq/domain/agent_correction_runner"

module StructuredOutputValidationTest
  module_function

  FIXTURE_ROOT = File.expand_path("fixtures/structured_output", __dir__)
  SCHEMA_PATH = File.expand_path("../config/schemas/agent_result.json", __dir__)

  def run!
    assert_first_pass_success
    assert_malformed_json_feedback
    assert_multiple_schema_violations
    assert_successful_correction_for_supported_harnesses
    assert_retry_exhaustion_preserves_invalid_response
    puts "structured_output_validation_test: ok"
  end

  def assert_first_pass_success
    with_runner("codex", "first_pass", correction_limit: 2) do |result|
      assert(result[:exit_code].zero?, "expected valid first-pass output to succeed")
      assert(result[:invocations].length == 1, "expected first-pass success not to retry")
      assert(!result[:output].include?("validation_failed"), "expected no validation failure event")
    end
  end

  def assert_malformed_json_feedback
    validator = validator()
    result = validator.validate(File.read(fixture("malformed.json")))
    assert(!result.valid?, "expected malformed JSON to fail")
    assert(result.errors == [{ "code" => "parse_error", "path" => "$", "message" => "Malformed JSON" }],
           "expected concise parse feedback, got #{result.errors.inspect}")
  end

  def assert_multiple_schema_violations
    result = validator.validate(File.read(fixture("multiple_violations.json")))
    codes = result.errors.map { |error| error["code"] }
    %w[missing_field unexpected_field invalid_enum wrong_type].each do |code|
      assert(codes.include?(code), "expected #{code} in #{result.errors.inspect}")
    end
    feedback = JSON.generate(result.errors)
    assert(!feedback.include?("must not appear"), "validation feedback must not include field values")
    assert(result.errors.any? { |error| error["path"] == "$.attachments" },
           "expected missing attachments path")
    assert(result.errors.any? { |error| error["path"] == "$.inquiry.fields[0].input_type" },
           "expected nested enum path")
  end

  def assert_successful_correction_for_supported_harnesses
    %w[codex claude].each do |adapter|
      with_runner(adapter, "corrected", correction_limit: 2) do |result|
        assert(result[:exit_code].zero?, "expected #{adapter} correction to succeed: #{result[:output]}")
        assert(result[:invocations].length == 2, "expected #{adapter} to make one correction")
        follow_up = result[:invocations].last
        assert(follow_up["session_id"] == "#{adapter}-session", "expected #{adapter} native session continuity")
        assert(follow_up["mode"] == "resume", "expected #{adapter} correction to resume")
        assert(follow_up["feedback"].include?("structured_output_validation_error"),
               "expected machine-readable correction feedback")
        assert(result[:invocations].count { |entry| entry["tool_work"] } == 1,
               "expected completed tool work not to rerun for #{adapter}")
      end
    end
  end

  def assert_retry_exhaustion_preserves_invalid_response
    with_runner("claude", "exhausted", correction_limit: 2) do |result|
      assert(result[:exit_code] == HQ::AgentCorrectionRunner::VALIDATION_FAILURE_EXIT_CODE,
             "expected actionable validation exit code")
      assert(result[:invocations].length == 3, "expected initial attempt plus two bounded corrections")
      assert(File.read(result[:invalid_path]) == File.read(fixture("malformed.json")),
             "expected final invalid response to be preserved exactly")
      mode = File.stat(result[:invalid_path]).mode & 0o777
      assert(mode == 0o600, "expected invalid diagnostic response to be owner-readable only")
      structured = HQ::AgentStructuredResult.from_log_lines(result[:output].lines)
      assert(structured["status"] == "failed", "expected exhausted result to surface failed status")
      assert(structured["summary"].include?(result[:invalid_path]),
             "expected exhausted result to identify the diagnostic artifact")
    end
  end

  def with_runner(adapter, scenario, correction_limit:)
    Dir.mktmpdir("tycho-structured-output-runner") do |dir|
      state_path = File.join(dir, "invocations.jsonl")
      last_message_path = File.join(dir, "last-message.json")
      invalid_path = File.join(dir, "invalid-structured-output.json")
      harness_path = File.join(dir, "fake_harness.rb")
      File.write(harness_path, fake_harness_source)

      initial = [
        RbConfig.ruby, harness_path, adapter, scenario, state_path, last_message_path,
        "initial", "#{adapter}-session", "initial prompt", FIXTURE_ROOT
      ]
      correction = [
        RbConfig.ruby, harness_path, adapter, scenario, state_path, last_message_path,
        "resume", HQ::AgentCorrectionRunner::SESSION_PLACEHOLDER,
        HQ::AgentCorrectionRunner::PROMPT_PLACEHOLDER, FIXTURE_ROOT
      ]
      output = StringIO.new
      runner = HQ::AgentCorrectionRunner.new(
        {
          "initial_command" => initial,
          "correction_command" => correction,
          "harness_adapter" => adapter,
          "schema_path" => SCHEMA_PATH,
          "last_message_path" => last_message_path,
          "invalid_response_path" => invalid_path,
          "session_id" => adapter == "claude" ? "claude-session" : "",
          "correction_limit" => correction_limit
        },
        output:
      )
      exit_code = runner.run
      invocations = File.readlines(state_path, chomp: true).map { |line| JSON.parse(line) }
      yield(exit_code:, output: output.string, invocations:, invalid_path: invalid_path)
    end
  end

  def fake_harness_source
    <<~'RUBY'
      require "json"
      adapter, scenario, state_path, last_message_path, mode, session_id, feedback, fixture_root = ARGV
      count = File.file?(state_path) ? File.readlines(state_path).length : 0
      entry = {
        "mode" => mode,
        "session_id" => session_id,
        "feedback" => feedback,
        "tool_work" => count.zero?
      }
      File.open(state_path, "a") { |file| file.puts(JSON.generate(entry)) }
      fixture_name = if scenario == "first_pass" || (scenario == "corrected" && count.positive?)
                       "valid.json"
                     elsif scenario == "corrected"
                       "multiple_violations.json"
                     else
                       "malformed.json"
                     end
      raw = File.read(File.join(fixture_root, fixture_name))
      if adapter == "codex"
        File.write(last_message_path, raw)
        puts JSON.generate("type" => "thread.started", "thread_id" => "codex-session")
      elsif fixture_name == "malformed.json"
        puts JSON.generate("type" => "result", "session_id" => "claude-session", "result" => raw)
      else
        puts JSON.generate("type" => "assistant", "session_id" => "claude-session", "structured_output" => JSON.parse(raw))
      end
    RUBY
  end

  def validator
    schema = JSON.parse(File.read(SCHEMA_PATH))
    HQ::AgentStructuredOutputValidator.new(schema:)
  end

  def fixture(name)
    File.join(FIXTURE_ROOT, name)
  end

  def assert(condition, message)
    raise message unless condition
  end
end

StructuredOutputValidationTest.run! if $PROGRAM_NAME == __FILE__
