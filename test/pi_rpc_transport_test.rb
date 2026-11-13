# frozen_string_literal: true

require "tmpdir"
require "json"
require "digest"
require "timeout"
require "open3"
require_relative "../lib/hq/domain/managed_agent"

module PiRpcTransportTest
  module_function

  def assert(value, message)
    raise message unless value
  end

  def run!
    Dir.mktmpdir("tycho-pi-rpc") do |dir|
      script = File.join(dir, "pi.rb")
      capture = File.join(dir, "capture.jsonl")
      File.write(script, <<~'CHILD')
        require "json"
        require "digest"
        require "open3"
        capture, scenario, fixtures = ARGV.shift(3)
        STDIN.binmode
        STDOUT.binmode
        $stdout.sync = true
        exit 12 if scenario == "early"
        state = JSON.parse(STDIN.gets.force_encoding(Encoding::UTF_8))
        raise "missing state request" unless state["type"] == "get_state"
        puts JSON.generate("type" => "response", "id" => state["id"], "command" => "get_state", "success" => true, "data" => { "sessionId" => scenario == "locale" ? "pi-session-🛰️" : "pi-session" })
        request = JSON.parse(STDIN.gets.force_encoding(Encoding::UTF_8))
        raise "missing prompt" unless request["type"] == "prompt"
        prompt = request.fetch("message")
        count = File.exist?(capture) ? File.readlines(capture).length : 0
        File.open(capture, "a") do |f|
          f.puts JSON.generate("prompt" => prompt, "argv" => ARGV, "env" => ENV.to_h, "pid" => Process.pid,
                               "process" => Open3.capture2("ps", "-p", Process.pid.to_s, "-o", "command=").first)
        end
        if %w[cancel cancel-stuck].include?(scenario)
          Signal.trap("TERM", "IGNORE") if scenario == "cancel-stuck"
          puts JSON.generate("type" => "pi.test.cancel_ready")
          STDIN.read
          IO.select(nil) if scenario == "cancel-stuck"
          exit 20
        end
        Signal.trap("TERM", "IGNORE") if scenario == "reject-stuck"
        puts JSON.generate("type" => "agent_start") unless %w[handled handled-stuck reject reject-stuck].include?(scenario)
        puts JSON.generate("type" => "response", "id" => request["id"], "command" => "prompt", "success" => !%w[reject reject-stuck].include?(scenario))
        if %w[reject reject-stuck].include?(scenario)
          STDIN.read
          IO.select(nil) if scenario == "reject-stuck"
          exit 21
        end
        completion = JSON.parse(STDIN.gets.force_encoding(Encoding::UTF_8))
        raise "missing completion state request" unless completion["type"] == "get_state"
        # Even an idle snapshot during automatic retry must not end an agent run.
        puts JSON.generate("type" => "response", "id" => completion["id"], "success" => true,
                           "data" => { "isStreaming" => false, "isCompacting" => false, "pendingMessageCount" => 0 })
        if %w[handled handled-stuck].include?(scenario)
          Signal.trap("TERM", "IGNORE") if scenario == "handled-stuck"
          raise "missing EOF after handled input" unless STDIN.read.empty?
          IO.select(nil) if scenario == "handled-stuck"
          puts JSON.generate("type" => "pi.test.handled_shutdown")
          exit 0
        end
        fixture = scenario == "correct" && count.zero? ? "multiple_violations.json" : "valid.json"
        raw = File.read(File.join(fixtures, fixture), encoding: Encoding::UTF_8)
        puts JSON.generate("type" => "message_end", "message" => { "role" => "assistant", "content" => [{ "type" => "text", "text" => raw }] })
        puts JSON.generate("type" => "agent_end", "willRetry" => true)
        # An agent_end is not final. The runner must still collect later events.
        puts JSON.generate("type" => "pi.test.after_agent_end")
        puts JSON.generate("type" => "agent_settled")
        raise "runner did not close stdin" unless STDIN.read.empty?
        puts JSON.generate("type" => "pi.test.shutdown")
      CHILD
      fixtures = File.expand_path("fixtures/structured_output", __dir__)
      ["", "\uFEFFline one\r\n日本語 🛰️\u2028\u2029\n\n", "pi-private-814\n" + ("é\n" * 600_000)].each do |prompt|
        [nil, "pi-session"].each do |session|
          agent = build_agent(dir, prompt, session:)
          prefix = [RbConfig.ruby, script, capture, "ok", fixtures]
          agent.define_singleton_method(:harness_execution) { { command: prefix, env: {} } }
          execution = agent.send(:build_command, prompt:)
          assert(execution[:prompt_transport] == "stdin", "Pi must use shared stdin transport")
          assert(execution[:stdin_data] == prompt, "builder changed prompt")
          assert(execution[:command].include?(session), "missing resume session") if session
          output, status = launch(execution)
          entry = JSON.parse(File.readlines(capture).last)
          assert(status.success?, "RPC child failed: #{output}")
          assert(entry["prompt"] == prompt, "RPC prompt bytes changed")
          unless prompt.empty?
            assert(!(entry["argv"] + entry["env"].values + execution[:description]).any? { |s| s.include?(prompt) }, "prompt leaked into argv/env/description")
          end
          assert(!entry["process"].include?("pi-private-814"), "prompt visible in ps")
          assert(output.include?("pi.test.shutdown") && output.include?("pi.test.after_agent_end"), "turn ended before settlement or EOF shutdown")
        end
      end
      %w[early reject].each do |scenario|
        agent = build_agent(dir, "x" * 2_000_000)
        prefix = [RbConfig.ruby, script, capture, scenario, fixtures]
        agent.define_singleton_method(:harness_execution) { { command: prefix, env: {} } }
        _output, status = launch(agent.send(:build_command))
        assert(!status.success?, "#{scenario} must fail")
      end

      # Locale must not affect either prompt bytes or reply decoding.
      prompt = "\uFEFF日本語 🛰️\r\n\u2028\u2029\n" + ("é\n" * 600_000)
      agent = build_agent(dir, prompt)
      prefix = [RbConfig.ruby, script, capture, "locale", fixtures]
      agent.define_singleton_method(:harness_execution) { { command: prefix, env: {} } }
      output, status = launch(agent.send(:build_command, prompt:), env: { "LANG" => "C", "LC_ALL" => "C" })
      assert(status.success? && JSON.parse(File.readlines(capture).last)["prompt"] == prompt, "C locale changed Unicode prompt: #{output}")
      session = output.lines.select { |line| line.start_with?("{") }.map { |line| JSON.parse(line) }.find { |event| event["type"] == "session" }
      assert(session["id"] == "pi-session-🛰️", "C locale changed UTF-8 reply")

      # A handled turn has no agent_settled event. Idle state must lead to EOF.
      prefix = [RbConfig.ruby, script, capture, "handled", fixtures]
      agent.define_singleton_method(:harness_execution) { { command: prefix, env: {} } }
      output, status = launch(agent.send(:build_command, prompt:))
      assert(status.success? && output.include?("pi.test.handled_shutdown"), "handled input did not exit after EOF")

      # Bound shutdown on success and error even if the child ignores EOF/TERM.
      %w[handled-stuck reject-stuck].each do |scenario|
        prefix = [RbConfig.ruby, script, capture, scenario, fixtures]
        agent.define_singleton_method(:harness_execution) { { command: prefix, env: {} } }
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        _output, status = launch(agent.send(:build_command, prompt:))
        elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
        assert(!status.success? && elapsed < 12, "#{scenario} shutdown was not bounded")
        child_pid = JSON.parse(File.readlines(capture).last)["pid"]
        assert_child_exited(child_pid)
      end

      prefix = [RbConfig.ruby, script, capture, "cancel-stuck", fixtures]
      agent.define_singleton_method(:harness_execution) { { command: prefix, env: {} } }
      _output, status = launch(agent.send(:build_command, prompt:), cancel: true)
      assert(status.exitstatus == 130, "cancel did not return its exit status")
      assert_child_exited(JSON.parse(File.readlines(capture).last)["pid"])

      assert_installed_pi_handled_input(dir)

      # Complete managed launches exercise recorder, correction, logs, memory,
      # and direct native resume with the same RPC child.
      File.delete(capture)
      prompt = "pi-managed-private-814\n日本語 🛰️\n" + ("é" * 600_000)
      agent = build_agent(dir, prompt)
      prefix = [RbConfig.ruby, script, capture, "correct", fixtures]
      agent.define_singleton_method(:harness_execution) { { command: prefix, env: {} } }
      expected = agent.send(:build_command)[:stdin_data]
      agent.start!
      Timeout.timeout(20) { agent.instance_variable_get(:@process_monitors).values.each(&:join) }
      agent.poll!
      entries = File.readlines(capture).map { |line| JSON.parse(line) }
      assert(agent.last_exit_code == 0 && entries.length == 2, "managed Pi correction failed")
      assert(entries.first["prompt"] == expected, "managed input changed")
      assert(entries.last["prompt"].include?("structured_output_validation_error"), "missing correction feedback")
      assert(entries.last["argv"].last(2) == ["--session", "pi-session"], "correction lost native session")
      entries.each do |entry|
        assert(!(entry["argv"] + entry["env"].values).any? { |s| s.include?(entry["prompt"]) }, "managed prompt leaked")
      end
      assert(File.binread(agent.raw_log_path).include?(prompt.b), "raw prompt changed")
      assert(File.readlines(agent.memory_path).any? { |line| JSON.parse(line)["content"] == prompt }, "canonical prompt changed")
      assert(!agent.last_run.command.include?("pi-managed-private-814"), "saved command leaked prompt")
      assert(agent.session_id == "pi-session", "managed session missing")
      agent.define_singleton_method(:structured_output_correction_supported?) { false }
      agent.add_user_message!("resume\n日本語")
      expected = agent.send(:build_command)[:stdin_data]
      agent.start!
      Timeout.timeout(20) { agent.instance_variable_get(:@process_monitors).values.each(&:join) }
      agent.poll!
      assert(agent.last_exit_code == 0 && JSON.parse(File.readlines(capture).last)["prompt"] == expected, "direct resume failed")

      # Cancel a managed run after the native child has accepted the prompt.
      cancel_capture = File.join(dir, "cancel.jsonl")
      agent = build_agent(dir, "cancel\n日本語")
      prefix = [RbConfig.ruby, script, cancel_capture, "cancel", fixtures]
      agent.define_singleton_method(:harness_execution) { { command: prefix, env: {} } }
      agent.start!
      Timeout.timeout(10) { Thread.pass until File.exist?(cancel_capture) && !File.zero?(cancel_capture) }
      native_pid = JSON.parse(File.readlines(cancel_capture).last)["pid"]
      agent.stop!
      Timeout.timeout(15) { agent.instance_variable_get(:@process_monitors).values.each(&:join) }
      # A stopped child can briefly remain a zombie; it must not remain running.
      process = Open3.capture2("ps", "-p", native_pid.to_s, "-o", "stat=").first.strip
      assert(process.empty? || process.start_with?("Z"), "cancel left Pi running")
    end
    puts "pi_rpc_transport_test: ok"
  end

  def assert_installed_pi_handled_input(dir)
    unless ENV["TYCHO_TEST_INSTALLED_PI"] == "1"
      puts "pi_rpc_transport_test: installed Pi check skipped (set TYCHO_TEST_INSTALLED_PI=1)"
      return
    end
    pi = ENV.fetch("PATH", "").split(File::PATH_SEPARATOR).map { |path| File.join(path, "pi") }
            .find { |path| File.file?(path) && File.executable?(path) }
    unless pi
      raise "TYCHO_TEST_INSTALLED_PI=1 requires pi on PATH"
    end
    received = File.join(dir, "installed-pi-prompt")
    extension = File.join(dir, "handled.mjs")
    File.write(extension, <<~JS)
      import fs from "node:fs";
      export default function(pi) {
        pi.on("input", async (event) => {
          fs.writeFileSync(#{JSON.generate(received)}, event.text, "utf8");
          return {action: "handled"};
        });
      }
    JS
    prompt = "\uFEFF日本語 🛰️ \"quotes\" \\path\t\r\n\u2028\u2029\n" + ("é\n" * 600_000)
    agent = build_agent(dir, prompt)
    prefix = [pi, "--offline", "--no-extensions", "--no-skills", "--no-prompt-templates",
              "--no-context-files", "--no-session", "-e", extension]
    agent.define_singleton_method(:harness_execution) { { command: prefix, env: {} } }
    env = { "HOME" => File.join(dir, "home"), "PI_CODING_AGENT_DIR" => File.join(dir, "pi-home"),
            "PI_OFFLINE" => "1", "TYCHO_HOME" => File.join(dir, "tycho-home"),
            "TYCHO_LOGS_ROOT" => File.join(dir, "logs"), "LANG" => "C", "LC_ALL" => "C" }
    output, status = launch(agent.send(:build_command, prompt:), env:)
    assert(status.success?, "installed Pi handled input failed: #{output}")
    assert(File.binread(received) == prompt.b, "installed Pi changed prompt bytes")
    assert(!output.include?("agent_settled"), "handled input unexpectedly ran the agent")
    assert(output.include?("tycho-completion"), "installed Pi completion state missing")
    puts "pi_rpc_transport_test: installed Pi handled UTF-8 input in C locale and exited on EOF"
  end

  def assert_child_exited(pid)
    Process.kill(0, pid)
    raise "runner left native child #{pid} running"
  rescue Errno::ESRCH
    nil
  end

  def build_agent(dir, prompt, session: nil)
    HQ::ManagedAgent.new(key: "pi-transport", name: "Pi", project_key: "test", template_key: "custom",
                         workspace: dir, prompt:, agent: "pi", session_id: session,
                         log_path: File.join(dir, "pi-#{SecureRandom.hex(4)}.raw.log"),
                         messages: [HQ::ManagedAgent::AgentMessage.new(role: "system", content: prompt, created_at: Time.now)])
  end

  def launch(execution, env: {}, cancel: false)
    input = HQ::AgentPromptTransport.input(execution[:stdin_data])
    reader, writer = IO.pipe
    pid = Process.spawn(env, *execution[:command], in: input, out: writer, err: [:child, :out], pgroup: true)
    input.close
    writer.close
    output = +""
    if cancel
      Timeout.timeout(10) do
        loop do
          line = reader.gets
          raise "child exited before cancel readiness" unless line

          output << line
          break if line.include?("pi.test.cancel_ready")
        end
      end
      Process.kill("TERM", pid)
    end
    output << Timeout.timeout(15) { reader.read }
    _, status = Process.wait2(pid)
    [output, status]
  ensure
    if pid && !status
      Process.kill("KILL", -pid)
      Process.wait(pid)
    end
    input&.close unless input&.closed?
    reader&.close unless reader&.closed?
    writer&.close unless writer&.closed?
  end
end

PiRpcTransportTest.run!
