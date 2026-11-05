# frozen_string_literal: true

require "tmpdir"
require "json"
require "timeout"
require_relative "../lib/hq/domain/managed_agent"

module AgentPromptTransportTest
  module_function

  def assert(value, message)
    raise message unless value
  end

  def run!
    Dir.mktmpdir("tycho-prompt-transport") do |dir|
      script = File.join(dir, "harness.rb")
      File.write(script, <<~'CHILD')
        require "json"
        require "digest"
        require "open3"
        prompt = STDIN.read
        puts JSON.generate("argv" => ARGV, "process" => Open3.capture2("ps", "-p", Process.pid.to_s, "-o", "command=").first, "env" => ENV.to_h, "digest" => Digest::SHA256.hexdigest(prompt), "size" => prompt.bytesize)
      CHILD
      require "digest"
      ["", "line one\n日本語 🛰️\n\n", "private-marker-811\n" + ("é\n" * 600_000)].each do |prompt|
        [nil, "session-811"].each do |session|
          agent = HQ::ManagedAgent.new(key: "transport", name: "Transport", project_key: "test",
                                       template_key: "custom", workspace: dir, prompt:, agent: "codex",
                                       session_id: session, log_path: File.join(dir, "raw.log"))
          execution = agent.send(:build_command, prompt:)
          assert(execution[:prompt_transport] == "stdin", "Codex must declare stdin")
          assert(execution[:command].last == "-", "Codex must select stdin")
          assert(prompt.empty? || !execution[:command].include?(prompt), "prompt leaked into command")
          assert(prompt.empty? || !execution[:description].include?(prompt), "prompt leaked into description")
          assert(execution[:command].include?(session), "missing resume ID") if session
          launch = agent.send(:structured_output_runner_launch, execution[:command], execution[:env], execution)
          assert(prompt.empty? || !launch[:env].values.compact.join("\0").include?(prompt), "prompt leaked into runner environment")
          input = HQ::AgentPromptTransport.input(execution[:stdin_data])
          reader, writer = IO.pipe
          pid = Process.spawn(RbConfig.ruby, script, *execution[:command].drop(1), in: input, out: writer)
          input.close
          writer.close
          result = JSON.parse(reader.read)
          reader.close
          _, status = Process.wait2(pid)
          assert(status.success?, "child failed")
          assert(result["digest"] == Digest::SHA256.hexdigest(prompt) && result["size"] == prompt.bytesize, "prompt bytes changed")
          assert(prompt.empty? || !(result["argv"] + result["env"].values).any? { |value| value.include?(prompt) }, "child argv or environment contains prompt")
          assert(prompt.empty? || !result["process"].include?(prompt.lines.first.chomp), "OS process listing contains prompt")
        end
      end

      # Exercise the complete managed launch, including the recorder and correction runner.
      managed_script = File.join(dir, "managed_harness.rb")
      fixture = File.expand_path("fixtures/structured_output/valid.json", __dir__)
      File.write(managed_script, <<~'CHILD')
        require "json"
        fixture = ARGV.shift
        capture = ARGV.shift
        raise "runner config leaked" if ENV.key?("TYCHO_AGENT_RUNNER_CONFIG")
        prompt = STDIN.read
        File.binwrite(capture, prompt)
        raw = File.read(fixture)
        File.write(ARGV[ARGV.index("-o") + 1], raw)
        puts JSON.generate("type" => "thread.started", "thread_id" => "transport-session")
        puts JSON.generate("type" => "item.completed", "item" => { "type" => "agent_message", "text" => raw })
      CHILD
      capture = File.join(dir, "received")
      prompt = "managed-private-811\n日本語 🛰️\n" + ("a" * 1_100_000)
      agent = HQ::ManagedAgent.new(key: "managed-transport", name: "Managed", project_key: "test",
                                   template_key: "custom", workspace: dir, prompt:, agent: "codex",
                                   log_path: File.join(dir, "managed.raw.log"),
                                   messages: [HQ::ManagedAgent::AgentMessage.new(role: "system", content: prompt, created_at: Time.now)])
      prefix = [RbConfig.ruby, managed_script, fixture, capture]
      agent.define_singleton_method(:harness_execution) { { command: prefix, env: {} } }
      expected = agent.send(:build_command)[:stdin_data]
      agent.start!
      Timeout.timeout(15) { agent.instance_variable_get(:@process_monitors).values.each(&:join) }
      agent.poll!
      assert(agent.last_exit_code == 0, "complete managed launch failed")
      assert(File.binread(capture) == expected.b, "complete launch changed prompt bytes")
      assert(File.binread(agent.raw_log_path).include?(prompt.b), "raw log lost exact prompt")
      assert(File.readlines(agent.memory_path).map { |line| JSON.parse(line) }.any? { |event| event["content"] == prompt }, "canonical transcript lost prompt")
      assert(!agent.last_run.command.include?("managed-private-811"), "saved command leaked prompt")
      # The same stdin seam must also work without the correction wrapper.
      agent.define_singleton_method(:structured_output_correction_supported?) { false }
      agent.add_user_message!("Resume via stdin.\n日本語")
      expected = agent.send(:build_command)[:stdin_data]
      agent.start!
      Timeout.timeout(15) { agent.instance_variable_get(:@process_monitors).values.each(&:join) }
      agent.poll!
      assert(agent.last_exit_code == 0 && File.binread(capture) == expected.b, "direct resumed launch changed stdin")

      # A child that closes stdin before reading must not leave a blocked writer.
      before = Thread.list
      input = HQ::AgentPromptTransport.input("x" * 2_000_000)
      pid = Process.spawn(RbConfig.ruby, "-e", "STDIN.close; exit 0", in: input)
      input.close
      Process.wait(pid)
      writers = Thread.list - before
      Timeout.timeout(5) { writers.each(&:join) }

      # Cancellation while the child does not read must release both pipe ends.
      before = Thread.list
      input = HQ::AgentPromptTransport.input("x" * 2_000_000)
      ready, signal = IO.pipe
      pid = Process.spawn(RbConfig.ruby, "-e", 'STDOUT.puts "ready"; STDOUT.flush; IO.select([STDIN]); loop { IO.select(nil) }', in: input, out: signal)
      input.close
      signal.close
      ready.gets
      Process.kill("TERM", pid)
      Process.wait(pid)
      ready.close
      writers = Thread.list - before
      Timeout.timeout(5) { writers.each(&:join) }
    end
    puts "agent_prompt_transport_test: ok"
  end
end

AgentPromptTransportTest.run!
