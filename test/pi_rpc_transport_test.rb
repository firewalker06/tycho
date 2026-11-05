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
        $stdout.sync = true
        exit 12 if scenario == "early"
        state = JSON.parse(STDIN.gets)
        raise "missing state request" unless state["type"] == "get_state"
        puts JSON.generate("type" => "response", "id" => state["id"], "command" => "get_state", "success" => true, "data" => { "sessionId" => "pi-session" })
        request = JSON.parse(STDIN.gets)
        raise "missing prompt" unless request["type"] == "prompt"
        prompt = request.fetch("message")
        count = File.exist?(capture) ? File.readlines(capture).length : 0
        File.open(capture, "a") do |f|
          f.puts JSON.generate("prompt" => prompt, "argv" => ARGV, "env" => ENV.to_h, "pid" => Process.pid,
                               "process" => Open3.capture2("ps", "-p", Process.pid.to_s, "-o", "command=").first)
        end
        if scenario == "cancel"
          STDIN.read
          exit 20
        end
        puts JSON.generate("type" => "response", "id" => request["id"], "command" => "prompt", "success" => scenario != "reject")
        if scenario == "reject"
          STDIN.read
          exit 21
        end
        fixture = scenario == "correct" && count.zero? ? "multiple_violations.json" : "valid.json"
        raw = File.read(File.join(fixtures, fixture))
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

  def build_agent(dir, prompt, session: nil)
    HQ::ManagedAgent.new(key: "pi-transport", name: "Pi", project_key: "test", template_key: "custom",
                         workspace: dir, prompt:, agent: "pi", session_id: session,
                         log_path: File.join(dir, "pi-#{SecureRandom.hex(4)}.raw.log"),
                         messages: [HQ::ManagedAgent::AgentMessage.new(role: "system", content: prompt, created_at: Time.now)])
  end

  def launch(execution)
    input = HQ::AgentPromptTransport.input(execution[:stdin_data])
    reader, writer = IO.pipe
    pid = Process.spawn(*execution[:command], in: input, out: writer, err: [:child, :out])
    input.close
    writer.close
    output = Timeout.timeout(15) { reader.read }
    _, status = Process.wait2(pid)
    [output, status]
  ensure
    input&.close unless input&.closed?
    reader&.close unless reader&.closed?
    writer&.close unless writer&.closed?
  end
end

PiRpcTransportTest.run!
