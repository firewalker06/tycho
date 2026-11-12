# frozen_string_literal: true

require "json"
require "open3"
require "tmpdir"
require "rbconfig"
require_relative "../lib/hq/domain/managed_agent"
require_relative "../lib/hq/domain/agent_correction_runner"
require_relative "../lib/hq/domain/agent_stream_recorder"
require_relative "../lib/hq/domain/harness_catalog"
require_relative "../lib/hq/domain/skill_discovery"
require_relative "../lib/hq/domain/harness_auth_check"

module DshHarnessTest
  module_function

  def run!
    Dir.mktmpdir("tycho-dsh-test-") do |dir|
      fake = File.join(dir, "dsh")
      capture = File.join(dir, "capture.jsonl")
      File.write(fake, <<~'CHILD'.sub("RUBY_EXECUTABLE", RbConfig.ruby))
        #!RUBY_EXECUTABLE
        require "json"
        abort "server credential leak" if ENV["TYCHO_REMOTE_TOKEN"] || ENV["TYCHO_GITHUB_TOKEN"]
        patch = ARGV.fetch(ARGV.index("--patch") + 1)
        received = { "argv" => ARGV, "stdin" => STDIN.read, "patch" => JSON.parse(File.read(patch)),
                     "patch_mode" => File.stat(patch).mode & 0777, "patch_path" => patch }
        File.open(ENV.fetch("DSH_TEST_CAPTURE"), "a") { |f| f.puts JSON.generate(received) }
        session = ARGV.include?("--session-id") ? ARGV.fetch(ARGV.index("--session-id") + 1) : "session-dsh-test"
        puts JSON.generate(type: "session", sessionId: session, cwd: Dir.pwd)
        puts JSON.generate(type: "tool_call", callId: "call-1", tool: "read", input: { path: "README.md" })
        puts JSON.generate(type: "tool_result", callId: "call-1", status: "completed", result: "# Fixture")
        puts JSON.generate(type: "status", phase: "step_end", usage: { inputTokens: 13, outputTokens: 7, cacheReadTokens: 3 })
        mode = ENV["DSH_TEST_MODE"]
        exit 0 if mode == "missing"
        text = if mode == "correction" && !ARGV.include?("--session-id")
                 "not JSON"
               else
                 JSON.generate(status: "success", summary: "Native dsh answer.", attachments: [])
               end
        reason = mode == "aborted" ? { kind: "aborted" } : { kind: "completed" }
        reason = nil if mode == "null-reason"
        final_id = mode == "wrong-session" ? "other-session" : session
        puts JSON.generate(type: "final", sessionId: final_id, reason: reason, text: text)
        puts JSON.generate(type: "error", message: "late error") if mode == "late-error"
        exit(mode == "nonzero" ? 2 : 0)
      CHILD
      File.chmod(0o700, fake)
      previous = ENV.to_h.slice("TYCHO_DSH_BIN", "DSH_TEST_CAPTURE", "DSH_TEST_MODE")
      ENV["TYCHO_DSH_BIN"] = fake
      ENV["DSH_TEST_CAPTURE"] = capture
      prompt = "private-prompt-851\n日本語\n" + ("é\n" * 600_000)
      agent = new_agent(dir, prompt: prompt, model: "deepseek-flash", reasoning_effort: "high")
      execution = agent.send(:build_command)
      assert(execution[:prompt_transport] == "stdin" && execution[:stdin_data].include?(prompt), "stdin transport lost prompt")
      assert(!execution[:command].join.include?("private-prompt-851"), "prompt leaked into command")
      native = execution[:command]
      assert(native.each_cons(2).include?(["--profile", "headless"]), "native headless profile missing")
      assert(native.each_cons(2).include?(["--permission-mode", "read-only"]), "permission mode missing")
      assert(native.each_cons(2).include?(["--approval-policy", "never"]), "unattended approval policy missing")
      assert(!native.include?("--session-id") && !native.include?("--model"), "invented model flag or cold session ID")
      out, err, status = execute(execution, dir)
      assert(status.success?, "native fake run failed: #{err}")
      received = JSON.parse(File.readlines(capture).last)
      assert(received["stdin"] == execution[:stdin_data], "prompt bytes changed")
      assert(received["patch"] == [{ "id" => "agent-default-model", "config" => {
        "provider" => "deepseek-official", "model" => "deepseek-flash", "reasoningEffort" => "high"
      } }], "model/effort overlay incorrect")
      assert(received["patch_mode"] == 0o600 && !File.exist?(received["patch_path"]), "overlay mode or cleanup incorrect")
      lines = out.lines
      payload = { "status" => "success", "summary" => "Native dsh answer.", "attachments" => [] }
      assert(HQ::AgentStructuredResult.from_log_lines(lines) == payload, "native final result missing")
      assert(JSON.parse(HQ::AgentStructuredResult.candidate_from_log_lines(lines)) == payload, "validator candidate missing")
      conversation, system = HQ::Parser.parse_stream(lines, agent_type: "dsh")
      assert(conversation.map(&:content) == ["Native dsh answer."], "final answer duplicated or lost")
      assert(system.any? { |entry| entry.type == :tool_result && entry.content == "# Fixture" }, "tool result missing")
      usage = system.find { |entry| entry.type == :usage }.metadata.fetch("usage")
      assert(usage == { "input_tokens" => 13, "output_tokens" => 7, "cache_read_input_tokens" => 3 }, "usage mapping incorrect")
      File.write(agent.raw_log_path, out)
      run = HQ::ManagedAgent::AgentRun.new(started_at: Time.now - 1, finished_at: Time.now, status: "succeeded",
                                          agent: "dsh", log_path: agent.raw_log_path, log_start_offset: 0)
      restored_agent = new_agent(dir, prompt: "Continue", runs: [run], started_at: run.started_at)
      restored_agent.send(:capture_session_id!)
      restored = HQ::ManagedAgent.from_hash(restored_agent.to_hash)
      assert(restored.session_id == "session-dsh-test" && restored.send(:native_resume?), "native identity/resume not persisted")
      resumed = restored.send(:build_command)
      assert(resumed[:command].each_cons(2).include?(["--session-id", "session-dsh-test"]), "resume flag missing")
      assert(!resumed[:stdin_data].include?("private-prompt-851"), "native resume replayed old prompt")
      %w[workspace-write danger-full-access].each do |preset|
        command = new_agent(dir, sandbox_mode: preset).send(:build_command)[:command]
        assert(command.each_cons(2).include?(["--permission-mode", preset]), "permission preset changed")
      end
      %w[missing aborted null-reason wrong-session late-error nonzero].each do |mode|
        ENV["DSH_TEST_MODE"] = mode
        _out, _err, failed = execute(execution, dir)
        assert(!failed.success?, "#{mode} incorrectly succeeded")
        received = JSON.parse(File.readlines(capture).last)
        assert(!File.exist?(received["patch_path"]), "#{mode} leaked overlay")
      end
      aborted = JSON.generate(type: "final", sessionId: "session-dsh-test", reason: { kind: "aborted" }, text: JSON.generate(payload))
      assert(HQ::AgentStructuredResult.from_log_lines(lines + [aborted]).nil?, "aborted event reused earlier success")
      assert(HQ::AgentStructuredResult.candidate_from_log_lines(lines + [aborted]).nil?, "aborted candidate reused earlier success")
      failed_run = HQ::ManagedAgent::AgentRun.new(started_at: Time.now - 1, finished_at: Time.now, status: "failed",
                                                 agent: "dsh", log_path: agent.raw_log_path, log_start_offset: 0)
      failed_agent = new_agent(dir, runs: [failed_run], started_at: failed_run.started_at, last_exit_code: 2)
      failed_agent.build_summary!
      assert(failed_agent.status == "failed" && failed_agent.structured_result.nil?, "nonzero run trusted a success payload")
      correction_test(dir, execution, capture)
      ENV.delete("DSH_TEST_MODE")
      memory = File.join(dir, "events.jsonl")
      projector = HQ::AgentStreamProjector.new(memory_path: memory, agent_type: "dsh", run_id: "run-851")
      lines.each_with_index { |line, index| projector.project_line(line, source_sequence: index) }
      events = File.readlines(memory).map { |line| JSON.parse(line) }
      assert(events.any? { |event| event["type"] == "tool_summary" && event.dig("metadata", "tool_name") == "read" }, "native tool projection missing")
      assert(events.count { |event| event["type"] == "assistant_message" } == 1, "canonical final answer duplicated")
      auth = HQ::HarnessAuthCheck.new.check(adapter: "dsh", command: [fake])
      assert(auth.state == "unknown", "credential readiness was guessed")
      assert(HQ::HarnessCatalog.dsh_catalog[:default_model] == "deepseek-flash", "offline default missing")
      assert(HQ.supported_harness?("dsh"), "native harness not registered")
      assert(HQ::SkillDiscovery.roots_for("dsh", dir).empty?, "dsh incorrectly inherited Codex skills")
    ensure
      %w[TYCHO_DSH_BIN DSH_TEST_CAPTURE DSH_TEST_MODE].each do |key|
        previous&.key?(key) ? ENV[key] = previous[key] : ENV.delete(key)
      end
    end
    puts "dsh_harness_test: ok"
  end

  def correction_test(dir, execution, capture)
    ENV["DSH_TEST_MODE"] = "correction"
    schema = File.join(dir, "result-schema.json")
    File.write(schema, JSON.generate(type: "object", required: %w[status summary], properties: {
      status: { type: "string", enum: ["success"] }, summary: { type: "string" }, attachments: { type: "array" }
    }))
    correction = new_agent(dir, prompt: HQ::AgentCorrectionRunner::PROMPT_PLACEHOLDER,
                           session_id: HQ::AgentCorrectionRunner::SESSION_PLACEHOLDER).send(:build_command)
    config = {
      "initial_command" => execution[:command], "initial_stdin" => "Return JSON", "prompt_transport" => "stdin",
      "correction_command" => correction[:command], "harness_adapter" => "dsh", "schema_path" => schema,
      "last_message_path" => File.join(dir, "last.json"), "invalid_response_path" => File.join(dir, "invalid.json"),
      "session_id" => "", "correction_limit" => 1
    }
    runner = [RbConfig.ruby, "--disable-gems", "-I", File.expand_path("../lib", __dir__),
              "-r", "hq/domain/agent_correction_runner", "-e", "HQ::AgentCorrectionRunner.run_from_stdin!"]
    out, err, status = Open3.capture3(HQ::HarnessExecution.environment, *runner, stdin_data: JSON.generate(config), chdir: dir)
    assert(status.success?, "same-session correction failed: #{err}\n#{out}")
    received = File.readlines(capture).last(2).map { |line| JSON.parse(line) }
    assert(!received.first["argv"].include?("--session-id"), "correction test did not start cold")
    assert(received.last["argv"].each_cons(2).include?(["--session-id", "session-dsh-test"]), "correction did not resume native session")
    assert(JSON.parse(received.last["stdin"])["type"] == "structured_output_validation_error", "correction feedback lost")
  end

  def new_agent(dir, **attributes)
    HQ::ManagedAgent.new(**{ key: "dsh-851", name: "DeepSeek Harness", project_key: "test", template_key: "custom",
                            workspace: dir, prompt: "Read only", agent: "dsh", sandbox_mode: "read-only",
                            log_path: File.join(dir, "dsh.raw.log") }.merge(attributes))
  end

  def execute(execution, dir)
    Open3.capture3(HQ::HarnessExecution.environment(execution[:env]), *execution[:command],
                   stdin_data: execution[:stdin_data], chdir: dir)
  end

  def assert(condition, message)
    raise message unless condition
  end
end

DshHarnessTest.run! if $PROGRAM_NAME == __FILE__
