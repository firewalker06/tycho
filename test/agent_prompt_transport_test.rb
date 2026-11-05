# frozen_string_literal: true

require "tmpdir"
require "json"
require "timeout"
require "open3"
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

      # Claude print mode receives the composed prompt through stdin. Check the
      # fresh and resumed command shapes with a real child process.
      ["line one\n日本語 🛰️\n\n", "claude-private-812\n" + ("é\n" * 600_000)].each do |prompt|
        [nil, "claude-session-812"].each do |session|
          agent = HQ::ManagedAgent.new(key: "claude-transport", name: "Claude Transport", project_key: "test",
                                       template_key: "custom", workspace: dir, prompt:, agent: "claude",
                                       session_id: session, log_path: File.join(dir, "claude.raw.log"))
          execution = agent.send(:build_command, prompt:)
          assert(execution[:prompt_transport] == "stdin", "Claude must declare stdin")
          assert(execution[:command].include?("--print") && execution[:command].include?("--output-format") &&
                 execution[:command].include?("stream-json"), "Claude must keep print stream-json output")
          assert(!execution[:command].include?(prompt), "Claude prompt leaked into argv")
          assert(execution[:command].include?("--resume") && execution[:command].include?(session),
                 "Claude resume arguments missing") if session
          input = HQ::AgentPromptTransport.input(execution[:stdin_data])
          reader, writer = IO.pipe
          pid = Process.spawn(RbConfig.ruby, script, *execution[:command].drop(1), in: input, out: writer)
          input.close
          writer.close
          result = JSON.parse(reader.read)
          reader.close
          _, status = Process.wait2(pid)
          assert(status.success?, "Claude fake child failed")
          assert(result["digest"] == Digest::SHA256.hexdigest(prompt) && result["size"] == prompt.bytesize,
                 "Claude prompt bytes changed")
          assert(!(result["argv"] + result["env"].values).any? { |value| value.include?(prompt) },
                 "Claude prompt leaked into child argv or environment")
          assert(!result["process"].include?("claude-private-812"), "Claude prompt leaked into process listing")
        end
      end

      # OpenCode run receives the composed prompt through stdin. Check the
      # fresh and resumed command shapes with a real child process.
      ["line one\n日本語 🛰️\n\n", "opencode-private-815\n" + ("é\n" * 600_000)].each do |prompt|
        [nil, "opencode-session-815"].each do |session|
          agent = HQ::ManagedAgent.new(key: "opencode-transport", name: "OpenCode Transport", project_key: "test",
                                       template_key: "custom", workspace: dir, prompt:, agent: "opencode",
                                       session_id: session, log_path: File.join(dir, "opencode.raw.log"))
          execution = agent.send(:build_command, prompt:)
          assert(execution[:prompt_transport] == "stdin", "OpenCode must declare stdin")
          assert(execution[:command][1, 3] == ["run", "--format", "json"], "OpenCode must keep JSON events")
          assert(!execution[:command].include?(prompt), "OpenCode prompt leaked into argv")
          assert(execution[:command].include?("--session") && execution[:command].include?(session),
                 "OpenCode resume arguments missing") if session
          input = HQ::AgentPromptTransport.input(execution[:stdin_data])
          reader, writer = IO.pipe
          pid = Process.spawn({ "LANG" => "C", "LC_ALL" => "C" }, RbConfig.ruby, script, *execution[:command].drop(1), in: input, out: writer)
          input.close
          writer.close
          result = JSON.parse(reader.read)
          reader.close
          _, status = Process.wait2(pid)
          assert(status.success?, "OpenCode fake child failed")
          assert(result["digest"] == Digest::SHA256.hexdigest(prompt) && result["size"] == prompt.bytesize,
                 "OpenCode prompt bytes changed")
          assert(!(result["argv"] + result["env"].values).any? { |value| value.include?(prompt) },
                 "OpenCode prompt leaked into child argv or environment")
          assert(!result["process"].include?("opencode-private-815"), "OpenCode prompt leaked into process listing")
        end
      end

      # agy print mode uses text stdin with its native stream-json output.
      ["agy first line\n日本語 🛰️\n\n", "agy-private-813\n" + ("é\n" * 600_000)].each do |prompt|
        [nil, "agy-session-813"].each do |session|
          agent = HQ::ManagedAgent.new(key: "agy-transport", name: "agy Transport", project_key: "test",
                                       template_key: "custom", workspace: dir, prompt:, agent: "agy",
                                       session_id: session, log_path: File.join(dir, "agy.raw.log"))
          execution = agent.send(:build_command, prompt:)
          assert(execution[:prompt_transport] == "stdin", "agy must declare stdin")
          assert(execution[:command].include?("--print") && execution[:command].include?("--input-format") &&
                 execution[:command].include?("text") && execution[:command].include?("--output-format") &&
                 execution[:command].include?("stream-json"), "agy must keep text stdin and stream-json output")
          assert(!execution[:command].include?(prompt), "agy prompt leaked into argv")
          assert(execution[:command].include?("--conversation") && execution[:command].include?(session),
                 "agy resume arguments missing") if session
          input = HQ::AgentPromptTransport.input(execution[:stdin_data])
          reader, writer = IO.pipe
          pid = Process.spawn(RbConfig.ruby, script, *execution[:command].drop(1), in: input, out: writer)
          input.close
          writer.close
          result = JSON.parse(reader.read)
          reader.close
          _, status = Process.wait2(pid)
          assert(status.success?, "agy fake child failed")
          assert(result["digest"] == Digest::SHA256.hexdigest(prompt) && result["size"] == prompt.bytesize,
                 "agy prompt bytes changed")
          assert(!(result["argv"] + result["env"].values).any? { |value| value.include?(prompt) },
                 "agy prompt leaked into child argv or environment")
          assert(!result["process"].include?("agy-private-813"), "agy prompt leaked into process listing")
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

      # Exercise the complete managed launch, including the recorder and correction runner.
      managed_script = File.join(dir, "opencode_managed_harness.rb")
      fixture = File.expand_path("fixtures/structured_output/valid.json", __dir__)
      File.write(managed_script, <<~'CHILD')
        require "json"
        fixture = ARGV.shift
        capture = ARGV.shift
        raise "runner config leaked" if ENV.key?("TYCHO_AGENT_RUNNER_CONFIG")
        prompt = STDIN.binmode.read.force_encoding(Encoding::UTF_8)
        first = !File.exist?(capture)
        File.binwrite(capture, prompt)
        File.binwrite("#{capture}.initial", prompt) if first
        payload = JSON.parse(File.binread(fixture).force_encoding(Encoding::UTF_8))
        payload["summary"] = first ? 42 : "応答 🛰️"
        raw = JSON.generate(payload)
        event = { "type" => "text", "sessionID" => "transport-session",
                  "part" => { "type" => "text", "text" => raw } }
        STDOUT.binmode.write(JSON.generate(event).encode(Encoding::UTF_8).b + "\n".b)
      CHILD
      capture = File.join(dir, "opencode-received")
      prompt = "managed-private-815\n日本語 🛰️\n" + ("a" * 1_100_000)
      agent = HQ::ManagedAgent.new(key: "managed-opencode-transport", name: "Managed", project_key: "test",
                                   template_key: "custom", workspace: dir, prompt:, agent: "opencode",
                                   log_path: File.join(dir, "managed-opencode.raw.log"),
                                   messages: [HQ::ManagedAgent::AgentMessage.new(role: "system", content: prompt, created_at: Time.now)])
      prefix = [RbConfig.ruby, managed_script, fixture, capture]
      agent.define_singleton_method(:harness_execution) { { command: prefix, env: { "LANG" => "C", "LC_ALL" => "C" } } }
      expected = agent.send(:build_command)[:stdin_data]
      agent.start!
      Timeout.timeout(15) { agent.instance_variable_get(:@process_monitors).values.each(&:join) }
      agent.poll!
      assert(agent.last_exit_code == 0, "complete managed launch failed")
      assert(File.binread("#{capture}.initial") == expected.b, "complete launch changed prompt bytes")
      feedback = JSON.parse(File.binread(capture).force_encoding(Encoding::UTF_8))
      assert(feedback["type"] == "structured_output_validation_error", "managed C-locale correction did not run")
      events = File.binread(agent.memory_path).force_encoding(Encoding::UTF_8).lines.map { |line| JSON.parse(line) }
      assert(events.any? { |event| event["content"].to_s.include?("応答 🛰️") }, "managed C-locale response changed")
      assert(File.binread(agent.raw_log_path).include?(prompt.b), "raw log lost exact prompt")
      assert(File.readlines(agent.memory_path).map { |line| JSON.parse(line) }.any? { |event| event["content"] == prompt }, "canonical transcript lost prompt")
      assert(!agent.last_run.command.include?("managed-private-815"), "saved command leaked prompt")
      # The same stdin seam must also work without the correction wrapper.
      agent.define_singleton_method(:structured_output_correction_supported?) { false }
      agent.add_user_message!("Resume via stdin.\n日本語")
      expected = agent.send(:build_command)[:stdin_data]
      agent.start!
      Timeout.timeout(15) { agent.instance_variable_get(:@process_monitors).values.each(&:join) }
      agent.poll!
      assert(agent.last_exit_code == 0 && File.binread(capture) == expected.b, "direct resumed launch changed stdin")

      # Cancel through the managed process group after OpenCode has read EOF.
      cancel_script = File.join(dir, "opencode_cancel.rb")
      cancel_capture = File.join(dir, "opencode-cancel-pid")
      File.write(cancel_script, <<~'CHILD')
        STDIN.read
        File.write(ARGV.shift, Process.pid.to_s)
        IO.select(nil)
      CHILD
      cancel_agent = HQ::ManagedAgent.new(key: "opencode-cancel", name: "Cancel", project_key: "test",
                                          template_key: "custom", workspace: dir, prompt: "cancel\n日本語",
                                          agent: "opencode", log_path: File.join(dir, "cancel.raw.log"))
      cancel_prefix = [RbConfig.ruby, cancel_script, cancel_capture]
      cancel_agent.define_singleton_method(:harness_execution) { { command: cancel_prefix, env: {} } }
      begin
        cancel_agent.start!
        Timeout.timeout(10) { Thread.pass until File.exist?(cancel_capture) && !File.zero?(cancel_capture) }
        native_pid = File.read(cancel_capture).to_i
        cancel_agent.stop!
        Timeout.timeout(15) { cancel_agent.instance_variable_get(:@process_monitors).values.each(&:join) }
        process = Open3.capture2("ps", "-p", native_pid.to_s, "-o", "stat=").first.strip
        assert(process.empty? || process.start_with?("Z"), "cancel left OpenCode running")
      ensure
        cancel_agent.retire_for_archive! if cancel_agent.running?
      end

      agy_capture = File.join(dir, "agy-received")
      agy_script = File.join(dir, "agy_managed_harness.rb")
      File.write(agy_script, <<~'CHILD')
        capture = ARGV.shift
        File.binwrite(capture, STDIN.read)
      CHILD
      agy_prompt = "agy-managed-private-813\n日本語 🛰️\n" + ("é" * 600_000)
      agy_agent = HQ::ManagedAgent.new(key: "managed-agy-transport", name: "Managed agy", project_key: "test",
                                       template_key: "custom", workspace: dir, prompt: agy_prompt, agent: "agy",
                                       log_path: File.join(dir, "managed-agy.raw.log"),
                                       messages: [HQ::ManagedAgent::AgentMessage.new(role: "system", content: agy_prompt, created_at: Time.now)])
      agy_prefix = [RbConfig.ruby, agy_script, agy_capture]
      agy_agent.define_singleton_method(:harness_execution) { { command: agy_prefix, env: {} } }
      agy_agent.define_singleton_method(:structured_output_correction_supported?) { false }
      agy_execution = agy_agent.send(:build_command)
      agy_expected = agy_execution[:stdin_data]
      assert(agy_execution[:prompt_transport] == "stdin" && !agy_execution[:command].include?(agy_prompt),
             "managed agy launch must keep prompt out of argv")
      agy_agent.start!
      Timeout.timeout(15) { agy_agent.instance_variable_get(:@process_monitors).values.each(&:join) }
      agy_agent.poll!
      assert(agy_agent.last_exit_code == 0 && File.binread(agy_capture) == agy_expected.b,
             "managed agy launch changed exact prompt bytes")
      assert(File.binread(agy_agent.raw_log_path).include?(agy_prompt.b), "agy raw log lost exact prompt")
      assert(File.readlines(agy_agent.memory_path).map { |line| JSON.parse(line) }
             .any? { |event| event["content"] == agy_prompt }, "agy canonical transcript lost exact prompt")
      assert(!agy_agent.last_run.command.include?("agy-managed-private-813"), "agy saved command leaked prompt")

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
