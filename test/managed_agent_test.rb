# frozen_string_literal: true

require "tmpdir"
require "fileutils"
require "json"
require "stringio"

require_relative "../lib/hq/domain/managed_agent"
require_relative "../lib/hq/cli_command"

module ManagedAgentTest
  module_function

  def run!
    assert_new_agents_use_unique_log_stems
    assert_start_finalizes_unpolled_previous_run
    assert_cli_status_finalizes_unpolled_dead_pid
    assert_start_reconciles_session_after_restart
    assert_fallback_summary_uses_assistant_message_not_tool_json
    assert_utf8_raw_log_captures_memory_under_ascii_default_external
    assert_opencode_fallback_summary_uses_text_event_not_prompt
    assert_structured_output_summary_beats_later_agent_message
    assert_claude_scalar_json_structured_output_normalizes
    assert_opencode_assistant_json_structured_output_normalizes
    assert_final_output_checklist_is_ephemeral_execution_context
    assert_response_style_applies_to_cold_and_resumed_runs
    assert_response_style_can_be_disabled_and_run_session_is_recorded
    assert_agent_result_schema_describes_summary
    assert_no_action_status_conflicts_are_normalized
    assert_agent_updates_replace_the_prior_base_prompt
    assert_initial_user_message_attachments_seed_memory
    assert_model_and_reasoning_effort_persist_and_update
    assert_legacy_run_commands_backfill_model_and_reasoning_effort
    assert_model_and_reasoning_effort_arguments_apply_to_harnesses
    assert_start_records_missing_harness_without_spawning
    assert_external_process_environment_removes_ruby_loader_state
    assert_start_spawns_harness_without_ruby_runner_parent
    assert_agent_runner_warns_when_command_cannot_execute
    puts "managed_agent_test: ok"
  end

  def assert_response_style_applies_to_cold_and_resumed_runs
    style = "Lead with evidence and stop when the point has landed."
    agent = HQ::ManagedAgent.new(
      key: "styled-agent",
      name: "Styled",
      project_key: "demo",
      template_key: "custom",
      workspace: Dir.tmpdir,
      prompt: "Inspect the project.",
      response_style: style
    )

    cold_prompt = agent.send(:prompt_for_execution)
    assert(cold_prompt.include?("RESPONSE STYLE:\n#{style}"),
           "expected response style guidance on a cold run")
    assert(cold_prompt.index(style) < cold_prompt.index(HQ::ManagedAgent::FINAL_OUTPUT_CHECKLIST),
           "expected response style before structured final-output guidance")

    resumed = HQ::ManagedAgent.from_hash(agent.to_hash.merge(
      "session_id" => "codex-session",
      "session_bootstrapped" => true,
      "runs" => [{ "finished_at" => Time.now.iso8601, "status" => "success" }]
    ))
    resume_prompt = resumed.send(:prompt_for_execution)
    assert(resume_prompt.include?("RESPONSE STYLE:\n#{style}"),
           "expected response style guidance on a native resumed run")
    assert(!resume_prompt.include?("Inspect the project."),
           "expected a native resumed run not to replay the base prompt")
  end

  def assert_response_style_can_be_disabled_and_run_session_is_recorded
    agent = HQ::ManagedAgent.new(
      key: "unstyled-agent",
      name: "Unstyled",
      project_key: "demo",
      template_key: "custom",
      workspace: Dir.tmpdir,
      prompt: "Inspect the project.",
      response_style: false
    )
    assert(!agent.send(:prompt_for_execution).include?("RESPONSE STYLE:"),
           "expected response_style false to disable global guidance")
    assert(agent.to_hash["response_style"] == false,
           "expected an explicit response style opt-out to persist")

    run = HQ::ManagedAgent::AgentRun.from_hash(
      "status" => "success",
      "session_id" => "session-123"
    )
    assert(run.to_hash["session_id"] == "session-123",
           "expected the harness session id to round-trip with a run")
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

  def assert_cli_status_finalizes_unpolled_dead_pid
    old_agents_file = nil
    old_logs_dir = nil
    old_archive_dir = nil
    Dir.mktmpdir("hq-cli-agent-status-test") do |dir|
      logs_dir = File.join(dir, "agents")
      FileUtils.mkdir_p(logs_dir)
      old_agents_file = replace_constant(HQ, :AGENTS_FILE, File.join(dir, "managed_agents.json"))
      old_logs_dir = replace_constant(HQ, :AGENT_LOGS_DIR, logs_dir)
      old_archive_dir = replace_constant(HQ, :AGENT_ARCHIVE_DIR, File.join(logs_dir, "archive"))

      started_at = Time.now - 60
      log_path = File.join(logs_dir, "demo.raw.log")
      File.open(log_path, "w") do |f|
        f.puts "=== [#{started_at.strftime("%Y-%m-%d %H:%M:%S")}] start ==="
        f.puts "workspace=#{dir}"
        f.puts "prompt=SYSTEM: test"
        f.puts JSON.generate(
          "type" => "text",
          "sessionID" => "ses_cli_status",
          "part" => {
            "type" => "text",
            "text" => "{\"status\":\"success\",\"summary\":\"CLI_STATUS_DONE\"}"
          }
        )
      end
      File.write(log_path.sub(/\.raw\.log\z/, ".status"), "0")

      agent = HQ::ManagedAgent.new(
        key: "demo-agent-1",
        name: "Demo",
        project_key: "demo",
        template_key: "custom",
        workspace: dir,
        prompt: "test",
        agent: "opencode",
        pid: 999_999,
        started_at: started_at,
        log_path: log_path,
        runs: [HQ::ManagedAgent::AgentRun.new(
          started_at: started_at,
          status: "running",
          log_path: log_path,
          command: "opencode run"
        )]
      )
      File.write(HQ::AGENTS_FILE, JSON.pretty_generate([agent.to_hash]))

      code = HQ::CLICommand.agent_status("demo-agent-1", out: StringIO.new, err: StringIO.new)
      saved = JSON.parse(File.read(HQ::AGENTS_FILE)).first

      assert(code == 0, "expected CLI agent status to succeed")
      assert(saved["last_exit_code"] == 0, "expected CLI status to persist finalized exit code")
      assert(saved["summary"] == "CLI_STATUS_DONE", "expected CLI status to persist finalized summary")
      assert(saved["session_id"] == "ses_cli_status", "expected CLI status to persist OpenCode session id")
      assert(saved.dig("runs", 0, "session_id") == "ses_cli_status",
             "expected the finalized run to record the session id emitted by the harness")
      assert(saved.dig("runs", 0, "finished_at"), "expected CLI status to persist run finish time")
    end
  ensure
    replace_constant(HQ, :AGENTS_FILE, old_agents_file) if old_agents_file
    replace_constant(HQ, :AGENT_LOGS_DIR, old_logs_dir) if old_logs_dir
    replace_constant(HQ, :AGENT_ARCHIVE_DIR, old_archive_dir) if old_archive_dir
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

      status_path = agent.send(:status_file_path)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 2.0
      until File.exist?(status_path)
        raise "replacement run did not write its status file" if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

        sleep 0.01
      end
      agent.poll!
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

  def assert_opencode_fallback_summary_uses_text_event_not_prompt
    Dir.mktmpdir("hq-managed-agent-opencode-summary-test") do |dir|
      log_path = File.join(dir, "opencode-summary.raw.log")
      started_at = Time.parse("2026-06-27 22:21:20")
      finished_at = started_at + 6
      File.open(log_path, "w") do |f|
        f.puts "=== [#{started_at.strftime("%Y-%m-%d %H:%M:%S")}] start ==="
        f.puts "workspace=#{dir}"
        f.puts "prompt=SYSTEM:"
        f.puts "this is just a test. reply with OK"
        f.puts
        f.puts "For `summary`, write a concise operator-facing Markdown summary."
        f.puts
        f.puts JSON.generate(
          "type" => "step_start",
          "sessionID" => "ses_test",
          "part" => { "type" => "step-start", "sessionID" => "ses_test" }
        )
        f.puts JSON.generate(
          "type" => "text",
          "sessionID" => "ses_test",
          "part" => { "type" => "text", "text" => "OK" }
        )
        f.puts JSON.generate(
          "type" => "step_finish",
          "sessionID" => "ses_test",
          "part" => {
            "type" => "step-finish",
            "tokens" => { "input" => 3, "output" => 4 },
            "cost" => 0.08288375
          }
        )
      end

      run = HQ::ManagedAgent::AgentRun.new(
        started_at: started_at,
        finished_at: finished_at,
        exit_code: 0,
        status: "succeeded",
        log_path: log_path,
        command: "opencode run"
      )
      agent = HQ::ManagedAgent.new(
        key: "opencode-summary-demo",
        name: "OpenCode Summary Demo",
        project_key: "demo",
        template_key: "custom",
        workspace: dir,
        prompt: "this is just a test. reply with OK",
        agent: "opencode",
        started_at: started_at,
        finished_at: finished_at,
        last_exit_code: 0,
        runs: [run],
        log_path: log_path
      )

      summary = agent.build_summary!
      assert(summary == "OK",
             "OpenCode fallback summary should prefer text event, got #{summary.inspect}")
    end
  end

  def assert_utf8_raw_log_captures_memory_under_ascii_default_external
    old_default_external = Encoding.default_external
    Encoding.default_external = Encoding::US_ASCII

    Dir.mktmpdir("hq-managed-agent-utf8-log-test") do |dir|
      log_path = File.join(dir, "utf8.raw.log")
      started_at = Time.parse("2026-07-05 17:29:13")
      finished_at = started_at + 30
      line = JSON.generate(
        "type" => "item.completed",
        "item" => {
          "type" => "agent_message",
          "text" => "Résumé captured"
        }
      )
      File.binwrite(
        log_path,
        [
          "=== [#{started_at.strftime("%Y-%m-%d %H:%M:%S")}] start ===",
          "workspace=#{dir}",
          "prompt=USER:",
          "Tell me about café highlights.",
          line
        ].join("\n") + "\n"
      )

      run = HQ::ManagedAgent::AgentRun.new(
        started_at: started_at,
        finished_at: finished_at,
        exit_code: 0,
        status: "succeeded",
        log_path: log_path,
        command: "codex test"
      )
      agent = HQ::ManagedAgent.new(
        key: "utf8-log-demo",
        name: "UTF-8 Log Demo",
        project_key: "demo",
        template_key: "custom",
        workspace: dir,
        prompt: "Tell me about café highlights.",
        agent: "codex",
        started_at: started_at,
        finished_at: finished_at,
        last_exit_code: 0,
        runs: [run],
        log_path: log_path
      )

      summary = agent.build_summary!
      assert(summary == "Résumé captured", "expected UTF-8 assistant summary, got #{summary.inspect}")

      agent.send(:capture_run_memory!, run)
      assistant = HQ::AgentMemory.new(agent).events.find { |event| event["type"] == "assistant_message" }
      assert(assistant && assistant["content"] == "Résumé captured",
             "expected UTF-8 assistant memory event, got #{assistant.inspect}")
    end
  ensure
    Encoding.default_external = old_default_external if old_default_external
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
        "message" => "Release now?",
        "fields" => [
          {
            "key" => "confirm",
            "label" => "Confirm release",
            "description" => "Approve the release.",
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
                  "summary" => "Need release approval.",
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
      assert(summary == "Need release approval.", "expected scalar structured summary")
      assert(structured["inquiry"]["message"] == "Release now?", "expected scalar inquiry JSON to normalize")
      assert(structured["inquiry"]["fields"].first["input_type"] == "boolean",
             "expected scalar inquiry fields to normalize")
      assert(structured["attachments"].first["url"] == "https://github.com/firewalker06/tycho/issues/9",
             "expected scalar attachments JSON to normalize")
      assert(!structured.key?("inquiry_json"), "expected scalar inquiry field to be removed")
      assert(!structured.key?("attachments_json"), "expected scalar attachments field to be removed")
    end
  end

  def assert_opencode_assistant_json_structured_output_normalizes
    payload = {
      "status" => "success",
      "summary" => "OpenCode summary.",
      "attachments" => [
        { "type" => "file", "path" => "/tmp/opencode-report.md" }
      ]
    }
    structured = HQ::AgentStructuredResult.normalize_payload(
      "type" => "text",
      "sessionID" => "opencode-session-1",
      "part" => {
        "type" => "text",
        "text" => "```json\n#{JSON.generate(payload)}\n```"
      }
    )

    assert(structured["summary"] == "OpenCode summary.",
           "expected OpenCode assistant JSON to normalize")
    assert(structured["attachments"].first["path"] == "/tmp/opencode-report.md",
           "expected OpenCode attachments to normalize")
  end

  def assert_final_output_checklist_is_ephemeral_execution_context
    Dir.mktmpdir("hq-managed-agent-checklist-test") do |dir|
      checklist = HQ::ManagedAgent::FINAL_OUTPUT_CHECKLIST
      assert(checklist.include?("For `summary`, write a concise operator-facing Markdown summary"),
             "final output guidance should explain the summary field")
      assert(checklist.include?("did not complete a requested change, answer, commit, review, or deliverable"),
             "final output guidance should distinguish no-op checks from completed work")
      assert(checklist.include?("quiet outcome that suppresses operator unread and push notifications"),
             "final output guidance should disclose the quiet no-action consequence")
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
    statuses = schema.dig("properties", "status", "enum")
    status_description = schema.dig("properties", "status", "description").to_s

    assert(description.include?("Remote UI Summary page"),
           "agent result schema should describe how to write the summary field")
    assert(statuses.include?("no_action_needed"),
           "canonical agent result schema should allow no_action_needed")
    assert(status_description.include?("observational or recurring check") &&
           status_description.include?("quiet outcome"),
           "canonical status schema should define no-action semantics and consequences")

    old_schema_path = replace_constant(HQ, :AGENT_RESULT_SCHEMA, schema_path)
    agent = HQ::ManagedAgent.new(
      key: "schema-statuses",
      name: "Schema Statuses",
      project_key: "demo",
      template_key: "custom",
      workspace: Dir.tmpdir,
      prompt: "System prompt",
      agent: "claude"
    )
    claude_schema = JSON.parse(agent.send(:compact_claude_result_schema))
    claude_statuses = claude_schema.dig("properties", "status", "enum")
    assert(claude_statuses.include?("no_action_needed"),
           "Claude compact result schema should allow no_action_needed")
    assert(claude_schema.dig("properties", "status", "description") == status_description,
           "Claude compact result schema should inherit canonical status guidance")
  ensure
    replace_constant(HQ, :AGENT_RESULT_SCHEMA, old_schema_path) if old_schema_path
  end

  def assert_no_action_status_conflicts_are_normalized
    normalizer = HQ::AgentResultNormalizer.new(workspace: Dir.tmpdir)

    no_op = normalizer.normalize_structured_result(
      "status" => "no_action_needed",
      "summary" => "Checked open pull requests. No new or changed PR needs review."
    )
    assert(no_op["status"] == "no_action_needed",
           "legitimate observational no-op checks should retain no_action_needed")

    completed_work = normalizer.normalize_structured_result(
      "status" => "no_action_needed",
      "summary" => "Implemented the requested prompt changes and committed the result."
    )
    assert(completed_work["status"] == "success",
           "no-action results that explicitly report completed work should normalize to success")

    inquiry = normalizer.normalize_structured_result(
      "status" => "no_action_needed",
      "summary" => "Need operator confirmation before continuing.",
      "inquiry" => {
        "message" => "Proceed with deployment?",
        "fields" => [
          {
            "key" => "proceed",
            "label" => "Proceed",
            "description" => nil,
            "input_type" => "boolean",
            "required" => true,
            "options" => nil
          }
        ]
      }
    )
    assert(inquiry["status"] == "input_required",
           "no-action results with a structured inquiry should normalize to input_required")
  end

  def assert_agent_updates_replace_the_prior_base_prompt
    Dir.mktmpdir("hq-managed-agent-prompt-replacement-test") do |dir|
      created_at = Time.now
      agent = HQ::ManagedAgent.new(
        key: "prompt-replacement",
        name: "Prompt Replacement",
        project_key: "demo",
        template_key: "custom",
        workspace: dir,
        prompt: "Original base prompt",
        agent: "codex",
        log_path: File.join(dir, "prompt-replacement.raw.log"),
        messages: [
          HQ::ManagedAgent::AgentMessage.new(
            role: "system",
            content: "Project:\n- Key: demo\n- Name: Demo\n- Path: #{dir}",
            created_at:
          ),
          HQ::ManagedAgent::AgentMessage.new(role: "system", content: "Original base prompt", created_at:)
        ]
      )

      agent.update!(
        name: agent.name,
        template_key: agent.template_key,
        workspace: agent.workspace,
        prompt: "Replacement base prompt",
        sandbox_mode: agent.sandbox_mode,
        agent: agent.agent,
        model: agent.model,
        reasoning_effort: agent.reasoning_effort
      )

      prompt = agent.send(:composed_prompt)
      assert(prompt.include?("Project:\n- Key: demo"),
             "agent update should preserve project context")
      assert(!prompt.include?("Original base prompt"),
             "agent update should remove the prior base prompt from cold replay")
      assert(prompt.scan("Replacement base prompt").length == 1,
             "agent update should retain exactly one replacement base prompt")

      agent.update!(
        name: agent.name,
        template_key: agent.template_key,
        workspace: agent.workspace,
        prompt: "Final base prompt",
        sandbox_mode: agent.sandbox_mode,
        agent: agent.agent,
        model: agent.model,
        reasoning_effort: agent.reasoning_effort
      )
      next_prompt = agent.send(:composed_prompt)
      assert(!next_prompt.include?("Original base prompt") && !next_prompt.include?("Replacement base prompt"),
             "repeated agent updates should retire every prior active base prompt")
      assert(next_prompt.scan("Final base prompt").length == 1,
             "repeated agent updates should retain exactly one final base prompt")
    end
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

  def assert_external_process_environment_removes_ruby_loader_state
    agent = HQ::ManagedAgent.new(
      key: "env-agent",
      name: "Env Agent",
      project_key: "demo",
      template_key: "custom",
      workspace: Dir.pwd,
      prompt: "System prompt",
      agent: "claude"
    )

    env = agent.send(:external_process_environment, "BUNDLE_GEMFILE" => "/custom/Gemfile", "CUSTOM" => "1")

    assert(env["BUNDLE_BIN_PATH"].nil?, "expected Bundler bin path to be cleared for harnesses")
    assert(env["RUBYOPT"].nil?, "expected Ruby loader options to be cleared for harnesses")
    assert(env["GEM_HOME"].nil?, "expected Ruby gem home to be cleared for harnesses")
    assert(env["BUNDLE_GEMFILE"] == "/custom/Gemfile", "expected explicit harness env to remain authoritative")
    assert(env["CUSTOM"] == "1", "expected explicit harness env to be preserved")
  end

  def assert_start_spawns_harness_without_ruby_runner_parent
    old_harnesses = HQ.custom_harnesses
    Dir.mktmpdir("hq-direct-harness-test") do |dir|
      harness = File.join(dir, "direct-harness")
      File.write(harness, <<~SH)
        #!/bin/sh
        parent_args="$(ps -p "$PPID" -o args=)"
        case "$parent_args" in
          *" -e "*)
            echo "ruby-wrapper-parent: $parent_args"
            exit 42
            ;;
          *)
            echo "direct-parent"
            exit 0
            ;;
        esac
      SH
      File.chmod(0o755, harness)
      HQ.custom_harnesses = [
        HQ::HarnessConfig.new(
          key: "direct-wrapper",
          adapter: "claude",
          execution_command: ["env", "FOO=bar", harness]
        )
      ]
      agent = HQ::ManagedAgent.new(
        key: "direct-wrapper-agent",
        name: "Direct Wrapper Agent",
        project_key: "demo",
        template_key: "custom",
        workspace: dir,
        prompt: "System prompt",
        agent: "direct-wrapper",
        log_path: File.join(dir, "direct.raw.log")
      )

      agent.start!
      30.times do
        break unless agent.running?

        sleep 0.1
        agent.poll!
      end
      agent.poll!

      log = File.read(agent.log_path)
      assert(agent.last_exit_code == 0, "expected direct harness to exit cleanly, log: #{log}")
      assert(log.include?("direct-parent"), "expected harness process not to be parented by ruby -e runner")
    end
  ensure
    HQ.custom_harnesses = old_harnesses if defined?(old_harnesses)
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

  def assert_model_and_reasoning_effort_persist_and_update
    agent = HQ::ManagedAgent.new(
      key: "model-agent",
      name: "Model Agent",
      project_key: "demo",
      template_key: "custom",
      workspace: Dir.tmpdir,
      prompt: "System prompt",
      model: "gpt-5.1-codex-max",
      reasoning_effort: "HIGH"
    )

    data = agent.to_hash
    assert(data["model"] == "gpt-5.1-codex-max", "expected model to persist")
    assert(data["reasoning_effort"] == "high", "expected reasoning effort to normalize and persist")

    restored = HQ::ManagedAgent.from_hash(data)
    assert(restored.model == "gpt-5.1-codex-max", "expected model to restore")
    assert(restored.reasoning_effort == "high", "expected reasoning effort to restore")

    restored.update!(
      name: "Updated Model Agent",
      template_key: "reviewer",
      workspace: Dir.tmpdir,
      prompt: "Updated prompt",
      model: "",
      reasoning_effort: ""
    )

    assert(restored.model.nil?, "expected blank model update to clear the agent model")
    assert(restored.reasoning_effort.nil?, "expected blank reasoning effort update to clear the agent effort")
    assert(!restored.to_hash.key?("model"), "expected cleared model to be omitted from persisted hash")
    assert(!restored.to_hash.key?("reasoning_effort"), "expected cleared effort to be omitted from persisted hash")
  end

  def assert_legacy_run_commands_backfill_model_and_reasoning_effort
    session_id = "019e8b77-6fe8-7f02-bb5e-3d35902e1f4d"
    data = {
      "key" => "legacy-model-agent",
      "name" => "Legacy Model Agent",
      "project_key" => "demo",
      "template_key" => "custom",
      "workspace" => Dir.tmpdir,
      "prompt" => "System prompt",
      "agent" => "codex",
      "session_id" => session_id,
      "runs" => [
        {
          "command" => Shellwords.join([
            "/opt/homebrew/bin/codex", "exec", "--model", "gpt-5.5",
            "-c", "model_reasoning_effort=\"xhigh\"", "--json", "--", "Initial prompt"
          ])
        },
        {
          "command" => Shellwords.join([
            "/opt/homebrew/bin/codex", "exec", "resume", "--json",
            session_id, "--", "Follow-up prompt"
          ])
        }
      ]
    }

    restored = HQ::ManagedAgent.from_hash(data)
    assert(restored.model == "gpt-5.5", "expected legacy run command to backfill model")
    assert(restored.reasoning_effort == "xhigh", "expected legacy run command to backfill reasoning effort")
    assert(restored.to_hash["model"] == "gpt-5.5", "expected backfilled model to persist")
    assert(restored.to_hash["reasoning_effort"] == "xhigh", "expected backfilled effort to persist")

    resume_command = restored.send(:build_command)[:command]
    assert(argument_after(resume_command, "--model") == "gpt-5.5",
           "expected backfilled Codex resume command to include --model")
    assert(argument_after(resume_command, "-c") == "model_reasoning_effort=\"xhigh\"",
           "expected backfilled Codex resume command to include model_reasoning_effort")

    explicit = HQ::ManagedAgent.from_hash(data.merge("model" => "gpt-5.1", "reasoning_effort" => "medium"))
    assert(explicit.model == "gpt-5.1", "expected explicit persisted model to beat command backfill")
    assert(explicit.reasoning_effort == "medium", "expected explicit persisted effort to beat command backfill")
  end

  def assert_model_and_reasoning_effort_arguments_apply_to_harnesses
    codex = HQ::ManagedAgent.new(
      key: "codex-model-agent",
      name: "Codex Model Agent",
      project_key: "demo",
      template_key: "custom",
      workspace: Dir.tmpdir,
      prompt: "System prompt",
      agent: "codex",
      model: "gpt-5.1-codex-max",
      reasoning_effort: "xhigh"
    )
    codex_command = codex.send(:build_command)[:command]
    assert(argument_after(codex_command, "--model") == "gpt-5.1-codex-max",
           "expected Codex command to include --model")
    assert(argument_after(codex_command, "-c") == "model_reasoning_effort=\"xhigh\"",
           "expected Codex command to include model_reasoning_effort config")

    claude = HQ::ManagedAgent.new(
      key: "claude-model-agent",
      name: "Claude Model Agent",
      project_key: "demo",
      template_key: "custom",
      workspace: Dir.tmpdir,
      prompt: "System prompt",
      agent: "claude",
      model: "sonnet",
      reasoning_effort: "max"
    )
    claude_command = claude.send(:build_command)[:command]
    assert(argument_after(claude_command, "--model") == "sonnet",
           "expected Claude command to include --model")
    assert(argument_after(claude_command, "--effort") == "max",
           "expected Claude command to include --effort")

    opencode = HQ::ManagedAgent.new(
      key: "opencode-model-agent",
      name: "OpenCode Model Agent",
      project_key: "demo",
      template_key: "custom",
      workspace: Dir.tmpdir,
      prompt: "System prompt",
      agent: "opencode",
      model: "anthropic/claude-sonnet-4",
      reasoning_effort: "high"
    )
    opencode_command = opencode.send(:build_command)[:command]
    assert(File.basename(opencode_command[0]) == "opencode" && opencode_command[1..3] == ["run", "--format", "json"],
           "expected OpenCode command to use opencode run --format json")
    assert(argument_after(opencode_command, "--dir") == Dir.tmpdir,
           "expected OpenCode command to include --dir")
    assert(argument_after(opencode_command, "--model") == "anthropic/claude-sonnet-4",
           "expected OpenCode command to include --model")
    assert(argument_after(opencode_command, "--variant") == "high",
           "expected OpenCode command to include --variant")
    assert(opencode_command.include?("--dangerously-skip-permissions"),
           "expected OpenCode full-access command to include dangerous permission flag")

    resumed = HQ::ManagedAgent.from_hash(opencode.to_hash.merge(
      "session_id" => "opencode-session-1",
      "session_bootstrapped" => true,
      "runs" => [{ "finished_at" => Time.now.iso8601, "status" => "succeeded" }]
    ))
    resumed_command = resumed.send(:build_command)[:command]
    assert(argument_after(resumed_command, "--session") == "opencode-session-1",
           "expected OpenCode resume command to include --session")

    old_harnesses = HQ.custom_harnesses
    HQ.custom_harnesses = [
      HQ::HarnessConfig.new(
        key: "claude-wrapper",
        adapter: "claude",
        execution_command: "claude-wrapper --model sonnet"
      )
    ]
    wrapper = HQ::ManagedAgent.new(
      key: "wrapper-model-agent",
      name: "Wrapper Model Agent",
      project_key: "demo",
      template_key: "custom",
      workspace: Dir.tmpdir,
      prompt: "System prompt",
      agent: "claude-wrapper",
      model: "opus",
      reasoning_effort: "high"
    )
    wrapper_command = wrapper.send(:build_command)[:command]
    assert(wrapper_command.each_cons(2).select { |left, _right| left == "--model" }.map(&:last) == %w[sonnet opus],
           "expected custom Claude-compatible wrapper to keep its prefix model and append agent-level override")
    assert(argument_after(wrapper_command, "--effort") == "high",
           "expected custom Claude-compatible wrapper to include --effort")

    HQ.custom_harnesses = [
      HQ::HarnessConfig.new(
        key: "env-wrapper",
        adapter: "claude",
        execution_command: ["env", "AWS_REGION=us-east-1", "CLAUDE_CODE_USE_BEDROCK=1", "claude-wrapper"]
      )
    ]
    env_wrapper = HQ::ManagedAgent.new(
      key: "env-wrapper-agent",
      name: "Env Wrapper Agent",
      project_key: "demo",
      template_key: "custom",
      workspace: Dir.tmpdir,
      prompt: "System prompt",
      agent: "env-wrapper",
      model: "sonnet"
    )
    env_execution = env_wrapper.send(:build_command)
    assert(env_execution[:command].first == "claude-wrapper",
           "expected custom harness env prefix to be removed from command")
    assert(env_execution[:env] == { "AWS_REGION" => "us-east-1", "CLAUDE_CODE_USE_BEDROCK" => "1" },
           "expected custom harness env prefix to become child process environment")
  ensure
    HQ.custom_harnesses = old_harnesses if defined?(old_harnesses)
  end

  def argument_after(command, flag)
    index = command.index(flag)
    index ? command[index + 1] : nil
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
