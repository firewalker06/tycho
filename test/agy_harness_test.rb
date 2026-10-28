# frozen_string_literal: true

require "json"
require "tmpdir"
require "rbconfig"
require_relative "../lib/hq/domain/managed_agent"
require_relative "../lib/hq/domain/agent_stream_recorder"

module AgyHarnessTest
  module_function

  def run!
    Dir.mktmpdir("tycho-agy-native-") do |dir|
      payload = { "status" => "success", "summary" => "Read **native** output.", "attachments" => [] }
      lines = [
        { event: "init", conversation_id: "native-agy-id", init: { permission_mode: "always-proceed" } },
        { event: "step_update", step_update: { step_index: 1, step_type: "agent_response", state: "ACTIVE", text_delta: "Partial" } },
        { event: "step_update", step_update: { step_index: 1, step_type: "agent_response", state: "DONE", text_delta: " JSON" } },
        { event: "step_update", step_update: { step_index: 2, step_type: "tool", state: "ACTIVE", tool_name: "read_file", tool_info: { parameters: { Path: "README.md" } } } },
        { event: "step_update", step_update: { step_index: 2, step_type: "tool", state: "DONE", tool_name: "read_file", tool_info: { output: "# Fixture" } } },
        { event: "step_update", step_update: { step_index: 3, step_type: "finish", state: "DONE", duration_seconds: 0.2 } },
        { event: "result", result: { conversation_id: "native-agy-id", status: "SUCCESS", response: JSON.generate(payload), structured_output: payload,
                                     usage: { input_tokens: 13, output_tokens: 7, cache_read_tokens: 3 }, duration_seconds: 1.25 } }
      ].map { |event| JSON.generate(event) }
      fake = File.join(dir, "agy")
      File.write(fake, "#!#{RbConfig.ruby}\nrequire 'json'\nabort 'credential leak' if ENV['TYCHO_REMOTE_TOKEN'] || ENV['TYCHO_GITHUB_TOKEN']\nputs #{lines.join("\n").inspect}\n")
      File.chmod(0o700, fake)
      raw_path = File.join(dir, "agy.raw.log")
      memory_path = File.join(dir, "agy.memory.jsonl")
      agent = HQ::ManagedAgent.new(key: "native-agy", name: "Native agy", project_key: "test", template_key: "custom",
                                   workspace: dir, prompt: "Read only", agent: "agy", sandbox_mode: "read-only", model: "example",
                                   reasoning_effort: "low", log_path: raw_path)
      previous = ENV["TYCHO_AGY_BIN"]
      ENV["TYCHO_AGY_BIN"] = fake
      command = agent.send(:build_command).fetch(:command)
      assert(command.first == fake && command.include?("stream-json"), "native executable/stream not selected")
      assert(command.include?("--sandbox") && command.each_cons(2).include?(["--mode", "plan"]), "conservative launch flags missing")
      assert(!command.include?("--conversation") && !command.include?("--session-id"), "cold run must let agy create its identity")
      assert(!command.include?("--dangerously-skip-permissions"), "PoC must not bypass approvals")
      assert(command.each_cons(2).include?(["--model", "example"]), "native model flag missing")
      assert(!command.include?("--effort"), "agy must ignore saved effort and use native defaults")
      interactive_command = agent.send(:interactive_command).fetch(:command)
      assert(interactive_command.include?("--prompt-interactive"), "interactive chat must use --prompt-interactive")
      code = HQ::AgentStreamRecorder.run(command: command, raw_log_path: raw_path, memory_path: memory_path, agent_type: "agy", run_id: "native-run")
      assert(code.zero?, "native stream process failed")
      assert(File.read(raw_path).include?(JSON.generate(payload)), "raw structured response was lost")
      fake_agent = Struct.new(:memory_path, :pid, :finished_at, :raw_log_path, :agent, :runs).new(memory_path, nil, Time.now, raw_path, "agy", [])
      blocks = HQ::AgentChatLog.new(fake_agent).chat_blocks
      assert(blocks.select { |block| block.role == "assistant" }.map(&:content) == ["Read **native** output."], "raw/partial JSON leaked or final response duplicated")
      assert(blocks.any? { |block| block.content.include?("# Fixture") }, "tool result missing")
      _, system = HQ::Parser.parse_stream(lines, agent_type: "agy")
      usage = system.find { |entry| entry.type == :usage }.metadata.fetch("usage")
      assert(usage["input_tokens"] == 13 && usage["output_tokens"] == 7 && usage["cache_read_input_tokens"] == 3, "usage mapping incorrect")
      assert(HQ::AgentStructuredResult.from_log_lines(lines) == payload, "native structured result lost")
      assert(HQ::AgentStructuredResult.candidate_from_log_lines(lines) == payload, "validator cannot find native result")
      failed = JSON.generate(event: "result", result: { status: "ERROR", response: "Permission denied", structured_output: payload })
      assert(HQ::AgentStructuredResult.from_log_lines([failed])["status"] == "failed", "native failure must override stale success payload")
      timeout_lines = [
        JSON.generate(event: "result", result: { conversation_id: "native-agy-id", status: "SUCCESS", response: "", structured_output: payload }),
        JSON.generate(event: "step_update", step_update: { step_index: 9, step_type: "tool", state: "DONE", tool_name: "run_command", tool_info: { output: "partial" } })
      ]
      assert(HQ::AgentStructuredResult.from_log_lines(timeout_lines).nil?, "timeout envelope must not adopt previous run's structured output")
      assert(HQ::AgentStructuredResult.candidate_from_log_lines(timeout_lines).nil?, "timeout envelope must not be a structured candidate")
      fresh = [
        JSON.generate(event: "step_update", step_update: { step_index: 9, step_type: "finish", state: "DONE", duration_seconds: 0.2 }),
        timeout_lines.first
      ]
      assert(HQ::AgentStructuredResult.from_log_lines(fresh) == payload, "fresh finish must keep structured output")
      fresh_parser_conversation, fresh_parser_system = HQ::Parser.parse_stream(fresh + [timeout_lines[1]], agent_type: "agy")
      assert(fresh_parser_conversation.map(&:role) != ["assistant"] || fresh_parser_conversation.last.content == "Read **native** output.", "fresh parse lost structured summary")
      stale = [timeout_lines[1], timeout_lines.first]
      stale_conversation, stale_system = HQ::Parser.parse_stream(stale, agent_type: "agy")
      assert(stale_conversation.none? { |entry| entry.role == "assistant" && entry.content.include?("Read **native** output.") }, "stale envelope leaked previous summary into conversation")
      assert(stale_system.any? { |entry| entry.type == :error && entry.content.include?("no final answer") }, "stale envelope not flagged as incomplete")
      partial = [timeout_lines[1], JSON.generate(event: "result", result: { conversation_id: "native-agy-id", status: "SUCCESS", response: "Partial answer text", structured_output: payload })]
      partial_conversation, partial_system = HQ::Parser.parse_stream(partial, agent_type: "agy")
      assert(partial_conversation.none? { |entry| entry.role == "assistant" }, "no-finish SUCCESS response leaked into conversation as final answer")
      assert(partial_system.any? { |entry| entry.type == :error && entry.metadata["status"] == "incomplete" }, "no-finish SUCCESS run not marked incomplete")
      assert(partial_system.none? { |entry| entry.metadata["status"] == "completed" }, "no-finish SUCCESS run marked completed")
      run = HQ::ManagedAgent::AgentRun.new(started_at: Time.now - 2, finished_at: Time.now, status: "succeeded", agent: "agy", log_path: raw_path, log_start_offset: 0)
      agent = HQ::ManagedAgent.new(key: "native-agy", name: "Native agy", project_key: "test", template_key: "custom", workspace: dir,
                                   prompt: "Read only", agent: "agy", sandbox_mode: "read-only", log_path: raw_path, runs: [run], started_at: run.started_at)
      agent.send(:capture_session_id!)
      assert(agent.session_id == "native-agy-id", "native conversation identity not captured")
      restored = HQ::ManagedAgent.from_hash(agent.to_hash)
      resumed = restored.send(:build_command).fetch(:command)
      assert(resumed.each_cons(2).include?(["--conversation", "native-agy-id"]), "resume after reload lost native identity")
      assert(restored.send(:native_resume?), "native resume incorrectly replays full history")
    ensure
      ENV["TYCHO_AGY_BIN"] = previous
    end
    puts "agy_harness_test: ok"
  end

  def assert(condition, message)
    raise message unless condition
  end
end

AgyHarnessTest.run! if $PROGRAM_NAME == __FILE__
