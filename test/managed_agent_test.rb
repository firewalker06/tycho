# frozen_string_literal: true

require "tmpdir"
require "fileutils"
require "json"

require_relative "../lib/hq/domain/managed_agent"

module ManagedAgentTest
  module_function

  def run!
    assert_new_agents_use_unique_log_stems
    assert_start_finalizes_unpolled_previous_run
    assert_start_reconciles_session_after_restart
    assert_fallback_summary_uses_assistant_message_not_tool_json
    assert_structured_output_summary_beats_later_agent_message
    assert_claude_scalar_json_structured_output_normalizes
    assert_final_output_checklist_is_ephemeral_execution_context
    assert_agent_result_schema_describes_summary
    assert_initial_user_message_attachments_seed_memory
    assert_start_records_missing_harness_without_spawning
    assert_agent_runner_warns_when_command_cannot_execute
    puts "managed_agent_test: ok"
  end

  def assert_new_agents_use_unique_log_stems
    old_logs_dir = nil
    Dir.mktmpdir("hq-managed-agent-test") do |dir|
      logs_dir = File.join(dir, "agents")
      FileUtils.mkdir_p(logs_dir)
      old_logs_dir = replace_constant(HQ, :AGENT_LOGS_DIR, logs_dir)
      created_at = Time.parse("2026-05-14 12:34:56")
      attrs = {
        key: "demo-agent-1",
        name: "Demo",
        project_key: "demo",
        template_key: "custom",
        workspace: dir,
        prompt: "Test",
        created_at: created_at
      }

      first = HQ::ManagedAgent.new(**attrs)
      second = HQ::ManagedAgent.new(**attrs)

      assert(first.raw_log_path != second.raw_log_path,
             "expected agents with a reused key to get distinct raw log paths")
      assert(File.basename(first.raw_log_path).start_with?("demo-20260514-123456-"),
             "expected raw log filename to include project key and creation timestamp")
      assert(!File.basename(first.raw_log_path).start_with?("demo-agent-1-"),
             "expected raw log filename to omit the agent sequence suffix")
      assert(first.send(:status_file_path) == first.raw_log_path.sub(/\.raw\.log\z/, ".status"),
             "expected status files to share the raw log stem")
      assert(first.send(:last_message_file_path) == first.raw_log_path.sub(/\.raw\.log\z/, ".last_message.json"),
             "expected structured-output files to share the raw log stem")
    end
  ensure
    replace_constant(HQ, :AGENT_LOGS_DIR, old_logs_dir) if old_logs_dir
  end

  # Regression for a bug where a Claude run that exited before the 10s poll tick
  # could be followed by a user-triggered restart; the previous run was never
  # finalized, so `capture_session_id!` never flipped `session_bootstrapped`,
  # and the second run was launched with `--session-id` instead of `--resume`,
  # producing "Session ID ... is already in use."
  def assert_start_finalizes_unpolled_previous_run
    old_logs_dir = nil
    Dir.mktmpdir("hq-managed-agent-test") do |dir|
      logs_dir = File.join(dir, "agents")
      FileUtils.mkdir_p(logs_dir)
      workspace = File.join(dir, "workspace")
      FileUtils.mkdir_p(workspace)

      old_logs_dir = replace_constant(HQ, :AGENT_LOGS_DIR, logs_dir)

      session_id = "3ee7587e-7224-4570-901d-d7db53c1df80"
      log_path = File.join(logs_dir, "demo.raw.log")
      started_at = Time.now - 60

      # Simulate an unfinalized first run: raw.log has the session_id event
      # but finalize_latest_run! never ran.
      marker = "=== [#{started_at.strftime("%Y-%m-%d %H:%M:%S")}] start ==="
      File.open(log_path, "w") do |f|
        f.puts
        f.puts marker
        f.puts "workspace=#{workspace}"
        f.puts "session_id=#{session_id}"
        f.puts "prompt=SYSTEM: test"
        f.puts
        f.puts JSON.generate(
          "type" => "system", "subtype" => "init", "session_id" => session_id
        )
        f.puts JSON.generate(
          "type" => "result", "subtype" => "success",
          "is_error" => false, "session_id" => session_id
        )
      end

      # Status file so read_exit_code returns 0.
      File.write(File.join(logs_dir, "demo.status"), "0")

      agent = HQ::ManagedAgent.new(
        key: "demo",
        name: "Demo",
        project_key: "demo",
        template_key: "custom",
        workspace: workspace,
        prompt: "SYSTEM: test",
        agent: "claude",
        session_id: session_id,
        session_bootstrapped: false,
        runs: [HQ::ManagedAgent::AgentRun.new(
          started_at: started_at,
          status: "running",
          log_path: log_path,
          command: "claude --session-id #{session_id}"
        )],
        log_path: log_path
      )

      # The detached pid is gone (run already exited, before poll tick).
      # Spawn a throwaway child and reap it so its pid is recycled/dead.
      dead_pid = spawn("true", out: File::NULL, err: File::NULL)
      Process.wait(dead_pid)
      agent.instance_variable_set(:@pid, dead_pid)
      agent.instance_variable_set(:@started_at, started_at)

      # Sanity: pid 1 is alive but not in our pgroup, so running? is false.
      raise "expected agent to be non-running for this test" if agent.running?

      assert(agent.session_bootstrapped == false,
             "precondition: session_bootstrapped should start false")
      assert(agent.send(:claude_session_arguments) == ["--session-id", session_id],
             "precondition: unfinalized run should still pass --session-id")

      # Stub build_command to avoid launching a real agent subprocess.
      # We capture the command the next run would use.
      captured = []
      agent.define_singleton_method(:build_command) do
        args = send(:claude_session_arguments)
        captured.concat(args)
        { command: ["true"], env: {} }
      end

      agent.start!

      assert(captured.first(2) == ["--resume", session_id],
             "start! should finalize the prior run and launch the next with --resume, got: #{captured.inspect}")
      assert(agent.session_bootstrapped == true,
             "start! should flip session_bootstrapped to true via finalize_previous_run!")
      assert(agent.session_id == session_id,
             "session_id should be preserved across restart")
      assert(agent.runs.first.status != "running",
             "the prior run should have been finalized, not left as running")
    end
  ensure
    replace_constant(HQ, :AGENT_LOGS_DIR, old_logs_dir) if old_logs_dir
  end

  # Regression for a bug where, after HQ restarts, `@pid` is nil so
  # `finalize_previous_run!` short-circuits, leaving `session_bootstrapped`
  # stuck at false even though the raw.log already contains the session_id
  # event. The next `start!` then keeps using `--session-id` and the CLI
  # rejects it. `reconcile_session_bootstrap!` self-heals from the log.
  def assert_start_reconciles_session_after_restart
    old_logs_dir = nil
    Dir.mktmpdir("hq-managed-agent-test") do |dir|
      logs_dir = File.join(dir, "agents")
      FileUtils.mkdir_p(logs_dir)
      workspace = File.join(dir, "workspace")
      FileUtils.mkdir_p(workspace)

      old_logs_dir = replace_constant(HQ, :AGENT_LOGS_DIR, logs_dir)

      session_id = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
      log_path = File.join(logs_dir, "restart-demo.raw.log")
      old_started_at = Time.now - 3600

      File.open(log_path, "w") do |f|
        f.puts
        f.puts "=== [#{old_started_at.strftime("%Y-%m-%d %H:%M:%S")}] start ==="
        f.puts "session_id=#{session_id}"
        f.puts JSON.generate(
          "type" => "system", "subtype" => "init", "session_id" => session_id
        )
        f.puts JSON.generate(
          "type" => "result", "subtype" => "success",
          "is_error" => false, "session_id" => session_id
        )
      end

      # State after an HQ restart: no pid, bootstrapped still false,
      # a prior run record stuck in "running" status.
      agent = HQ::ManagedAgent.new(
        key: "restart-demo",
        name: "Restart Demo",
        project_key: "demo",
        template_key: "custom",
        workspace: workspace,
        prompt: "SYSTEM: test",
        agent: "claude",
        session_id: session_id,
        session_bootstrapped: false,
        runs: [HQ::ManagedAgent::AgentRun.new(
          started_at: old_started_at,
          status: "running",
          log_path: log_path,
          command: "claude --session-id #{session_id}"
        )],
        log_path: log_path
      )

      raise "precondition: no pid expected" if agent.pid
      assert(agent.send(:claude_session_arguments) == ["--session-id", session_id],
             "precondition: bootstrapped=false should emit --session-id")

      captured = []
      agent.define_singleton_method(:build_command) do
        args = send(:claude_session_arguments)
        captured.concat(args)
        { command: ["true"], env: {} }
      end

      agent.start!

      assert(captured.first(2) == ["--resume", session_id],
             "start! after restart should reconcile from log and launch with --resume, got: #{captured.inspect}")
      assert(agent.session_bootstrapped == true,
             "reconcile_session_bootstrap! should flip the flag via the raw log")
    end
  ensure
    replace_constant(HQ, :AGENT_LOGS_DIR, old_logs_dir) if old_logs_dir
  end

  def assert_fallback_summary_uses_assistant_message_not_tool_json
    Dir.mktmpdir("hq-managed-agent-summary-test") do |dir|
      log_path = File.join(dir, "summary.raw.log")
      started_at = Time.parse("2026-05-12 09:30:00")
      finished_at = started_at + 30
      marker = "=== [#{started_at.strftime("%Y-%m-%d %H:%M:%S")}] start ==="
      File.open(log_path, "w") do |f|
        f.puts marker
        f.puts "workspace=#{dir}"
        f.puts "prompt=Summarize fallback behavior"
        f.puts JSON.generate(
          "type" => "item.completed",
          "item" => {
            "id" => "item_message",
            "type" => "agent_message",
            "text" => "Finished useful work."
          }
        )
        f.puts JSON.generate(
          "type" => "item.completed",
          "item" => {
            "id" => "item_command",
            "type" => "command_execution",
            "command" => "git status --short",
            "aggregated_output" => "",
            "exit_code" => 0,
            "status" => "completed"
          }
        )
        f.puts JSON.generate(
          "type" => "turn.completed",
          "usage" => { "input_tokens" => 10, "output_tokens" => 5 }
        )
      end

      run = HQ::ManagedAgent::AgentRun.new(
        started_at: started_at,
        finished_at: finished_at,
        exit_code: 0,
        status: "success",
        log_path: log_path,
        command: "codex test"
      )
      agent = HQ::ManagedAgent.new(
        key: "summary-demo",
        name: "Summary Demo",
        project_key: "demo",
        template_key: "custom",
        workspace: dir,
        prompt: "Summarize fallback behavior",
        agent: "codex",
        started_at: started_at,
        finished_at: finished_at,
        last_exit_code: 0,
        runs: [run],
        log_path: log_path
      )

      summary = agent.build_summary!
      assert(summary == "Finished useful work.",
             "fallback summary should prefer assistant message, got #{summary.inspect}")

      agent.send(:capture_run_memory!, run)
      run_summary = HQ::AgentMemory.new(agent).events.reverse.find { |event| event["type"] == "run_summary" }
      assert(run_summary["content"] == "Finished useful work.",
             "memory run_summary should not contain raw item.completed JSON, got #{run_summary.inspect}")
    end
  end

  def assert_structured_output_summary_beats_later_agent_message
    Dir.mktmpdir("hq-managed-agent-structured-summary-test") do |dir|
      log_path = File.join(dir, "structured-summary.raw.log")
      started_at = Time.parse("2026-05-12 09:45:00")
      marker = "=== [#{started_at.strftime("%Y-%m-%d %H:%M:%S")}] start ==="
      File.open(log_path, "w") do |f|
        f.puts marker
        f.puts "workspace=#{dir}"
        f.puts "prompt=Prefer structured output"
        f.puts JSON.generate(
          "type" => "assistant",
          "message" => {
            "role" => "assistant",
            "content" => [
              {
                "type" => "tool_use",
                "name" => "StructuredOutput",
                "input" => {
                  "status" => "success",
                  "summary" => "Structured summary wins.",
                  "inquiry" => nil,
                  "attachments" => nil
                }
              }
            ]
          }
        )
        f.puts JSON.generate(
          "type" => "assistant",
          "message" => {
            "role" => "assistant",
            "content" => [
              {
                "type" => "text",
                "text" => "Later plain agent message."
              }
            ]
          }
        )
      end

      agent = HQ::ManagedAgent.new(
        key: "structured-summary-demo",
        name: "Structured Summary Demo",
        project_key: "demo",
        template_key: "custom",
        workspace: dir,
        prompt: "Prefer structured output",
        agent: "claude",
        started_at: started_at,
        finished_at: started_at + 20,
        last_exit_code: 0,
        runs: [
          HQ::ManagedAgent::AgentRun.new(
            started_at: started_at,
            finished_at: started_at + 20,
            exit_code: 0,
            status: "success",
            log_path: log_path,
            command: "claude test"
          )
        ],
        log_path: log_path
      )

      summary = agent.build_summary!
      assert(summary == "Structured summary wins.",
             "structured output summary should beat later agent message, got #{summary.inspect}")
      assert(agent.structured_result&.dig("summary") == "Structured summary wins.",
             "expected StructuredOutput tool payload to populate structured_result")
    end
  end

  def assert_claude_scalar_json_structured_output_normalizes
    Dir.mktmpdir("hq-managed-agent-scalar-structured-test") do |dir|
      log_path = File.join(dir, "scalar-structured.raw.log")
      started_at = Time.parse("2026-05-12 10:15:00")
      inquiry = {
        "message" => "Deploy now?",
        "fields" => [
          {
            "key" => "confirm",
            "label" => "Confirm deploy",
            "description" => "Approve the deployment.",
            "input_type" => "boolean",
            "required" => true,
            "options" => nil
          }
        ]
      }
      attachments = [
        {
          "type" => "link",
          "title" => "Issue 9",
          "url" => "https://github.com/firewalker06/tycho/issues/9",
          "description" => "StructuredOutput compatibility issue."
        }
      ]
      File.open(log_path, "w") do |f|
        f.puts "=== [#{started_at.strftime("%Y-%m-%d %H:%M:%S")}] start ==="
        f.puts "workspace=#{dir}"
        f.puts "prompt=Prefer scalar structured output"
        f.puts JSON.generate(
          "type" => "assistant",
          "message" => {
            "role" => "assistant",
            "content" => [
              {
                "type" => "tool_use",
                "name" => "StructuredOutput",
                "input" => {
                  "status" => "input_required",
                  "summary" => "Need deploy approval.",
                  "inquiry_json" => JSON.generate(inquiry),
                  "attachments_json" => JSON.generate(attachments)
                }
              }
            ]
          }
        )
      end

      agent = HQ::ManagedAgent.new(
        key: "scalar-structured-demo",
        name: "Scalar Structured Demo",
        project_key: "demo",
        template_key: "custom",
        workspace: dir,
        prompt: "Prefer scalar structured output",
        agent: "claude",
        started_at: started_at,
        finished_at: started_at + 20,
        last_exit_code: 0,
        runs: [
          HQ::ManagedAgent::AgentRun.new(
            started_at: started_at,
            finished_at: started_at + 20,
            exit_code: 0,
            status: "success",
            log_path: log_path,
            command: "claude test"
          )
        ],
        log_path: log_path
      )

      summary = agent.build_summary!
      structured = agent.structured_result
      assert(summary == "Need deploy approval.", "expected scalar structured summary")
      assert(structured["inquiry"]["message"] == "Deploy now?", "expected scalar inquiry JSON to normalize")
      assert(structured["inquiry"]["fields"].first["input_type"] == "boolean",
             "expected scalar inquiry fields to normalize")
      assert(structured["attachments"].first["url"] == "https://github.com/firewalker06/tycho/issues/9",
             "expected scalar attachments JSON to normalize")
      assert(!structured.key?("inquiry_json"), "expected scalar inquiry field to be removed")
      assert(!structured.key?("attachments_json"), "expected scalar attachments field to be removed")
    end
  end

  def assert_final_output_checklist_is_ephemeral_execution_context
    Dir.mktmpdir("hq-managed-agent-checklist-test") do |dir|
      checklist = HQ::ManagedAgent::FINAL_OUTPUT_CHECKLIST
      assert(checklist.include?("For `summary`, write a concise operator-facing Markdown summary"),
             "final output guidance should explain the summary field")
      log_path = File.join(dir, "checklist.raw.log")

      agent = HQ::ManagedAgent.new(
        key: "checklist",
        name: "Checklist",
        project_key: "demo",
        template_key: "custom",
        workspace: dir,
        prompt: "System prompt",
        agent: "codex",
        log_path: log_path
      )
      agent.add_user_message!("Create the plan")

      prompt = agent.send(:prompt_for_execution)
      assert(prompt.include?("USER:\nCreate the plan"),
             "composed prompt should include the persisted user message")
      assert(prompt.end_with?(checklist),
             "composed prompt should append the final output checklist")

      user_event = HQ::AgentMemory.new(agent).events.find { |event| event["type"] == "user_message" }
      assert(user_event["content"] == "Create the plan",
             "checklist should not be persisted into memory user messages")

      resumed_log_path = File.join(dir, "resumed.raw.log")
      prior_finished_at = Time.now - 60
      resumed = HQ::ManagedAgent.new(
        key: "checklist-resumed",
        name: "Checklist Resumed",
        project_key: "demo",
        template_key: "custom",
        workspace: dir,
        prompt: "System prompt",
        agent: "codex",
        session_id: "session-123",
        session_bootstrapped: true,
        runs: [
          HQ::ManagedAgent::AgentRun.new(
            started_at: prior_finished_at - 30,
            finished_at: prior_finished_at,
            exit_code: 0,
            status: "success",
            log_path: resumed_log_path,
            command: "codex exec"
          )
        ],
        log_path: resumed_log_path
      )
      resumed.add_user_message!("Attach the PR")

      resumed_prompt = resumed.send(:prompt_for_execution)
      assert(resumed_prompt.start_with?("Attach the PR"),
             "native resume prompt should start with the latest user message")
      assert(resumed_prompt.end_with?(checklist),
             "native resume prompt should append the final output checklist")

      resumed_user_event = HQ::AgentMemory.new(resumed).events.find { |event| event["type"] == "user_message" }
      assert(resumed_user_event["content"] == "Attach the PR",
             "native resume memory should keep the user message unchanged")
    end
  end

  def assert_agent_result_schema_describes_summary
    schema_path = File.expand_path("../config/schemas/agent_result.json", __dir__)
    schema = JSON.parse(File.read(schema_path))
    description = schema.dig("properties", "summary", "description").to_s

    assert(description.include?("Remote UI Summary page"),
           "agent result schema should describe how to write the summary field")
  end

  def assert_initial_user_message_attachments_seed_memory
    Dir.mktmpdir("hq-managed-agent-attachment-seed-test") do |dir|
      File.write(File.join(dir, "seeded-notes.md"), "# Seeded notes\n")
      attachment = {
        "kind" => "document",
        "title" => "seeded-notes.md",
        "url" => File.join(dir, "seeded-notes.md")
      }
      agent = HQ::ManagedAgent.new(
        key: "seeded-attachments",
        name: "Seeded Attachments",
        project_key: "demo",
        template_key: "custom",
        workspace: dir,
        prompt: "System prompt",
        agent: "codex",
        log_path: File.join(dir, "seeded.raw.log"),
        messages: [
          HQ::ManagedAgent::AgentMessage.new(role: "system", content: "System prompt", created_at: Time.now),
          HQ::ManagedAgent::AgentMessage.new(
            role: "user",
            content: "Read the uploaded notes.",
            created_at: Time.now,
            metadata: { "attachments" => [attachment] }
          )
        ]
      )

      event = HQ::AgentMemory.new(agent).events.find { |item| item["type"] == "user_message" }
      assert(event.dig("metadata", "attachments", 0, "title") == "seeded-notes.md",
             "expected seeded user message attachments to persist in memory")
    end
  end

  def assert_agent_runner_warns_when_command_cannot_execute
    Dir.mktmpdir("hq-agent-runner-test") do |dir|
      status_path = File.join(dir, "runner.status")
      missing_command = File.join(dir, "missing-agent-command")
      agent = HQ::ManagedAgent.new(
        key: "runner",
        name: "Runner",
        project_key: "demo",
        template_key: "custom",
        workspace: dir,
        prompt: "System prompt",
        agent: "codex",
        log_path: File.join(dir, "runner.raw.log")
      )

      output = IO.popen(
        { "TYCHO_STATUS_PATH" => status_path },
        [RbConfig.ruby, "-e", agent.send(:agent_runner_script), missing_command],
        err: %i[child out],
        &:read
      )

      assert($?.exitstatus == 127, "expected runner to exit 127 for missing command")
      assert(File.read(status_path) == "127", "expected runner status file to record 127")
      assert(output.include?("failed to execute #{missing_command.inspect}"),
             "expected missing command warning in runner output")
    end
  end

  def assert_start_records_missing_harness_without_spawning
    old_logs_dir = nil
    Dir.mktmpdir("hq-missing-harness-test") do |dir|
      logs_dir = File.join(dir, "agents")
      FileUtils.mkdir_p(logs_dir)
      old_logs_dir = replace_constant(HQ, :AGENT_LOGS_DIR, logs_dir)

      missing_command = File.join(dir, "missing-codex")
      log_path = File.join(logs_dir, "missing.raw.log")
      agent = HQ::ManagedAgent.new(
        key: "missing",
        name: "Missing",
        project_key: "demo",
        template_key: "custom",
        workspace: dir,
        prompt: "System prompt",
        agent: "codex",
        log_path: log_path
      )
      agent.define_singleton_method(:build_command) { { command: [missing_command, "exec"] } }
      agent.define_singleton_method(:spawn) { raise "missing harness should be caught before spawn" }

      result = agent.start!

      assert(result == false, "expected missing harness start to return false")
      assert(agent.pid.nil?, "expected missing harness start not to assign a pid")
      assert(agent.last_run&.status == "failed", "expected missing harness start to record a failed run")
      assert(agent.last_exit_code == 127, "expected missing harness start to use exit code 127")
      assert(agent.status == "failed", "expected missing harness start to leave the agent failed")
      log = File.read(log_path)
      assert(log.include?("start failed"), "expected missing harness log to record start failure")
      assert(log.include?("executable not found: #{missing_command}"),
             "expected missing harness log to name the missing executable")
    end
  ensure
    replace_constant(HQ, :AGENT_LOGS_DIR, old_logs_dir) if old_logs_dir
  end

  def assert(condition, message)
    raise message unless condition
  end

  def replace_constant(scope, name, value)
    old_value = scope.const_get(name)
    scope.send(:remove_const, name)
    scope.const_set(name, value)
    old_value
  end
end

ManagedAgentTest.run! if $PROGRAM_NAME == __FILE__
