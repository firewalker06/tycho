# frozen_string_literal: true

require "tmpdir"
require "json"
require "digest"
require "open3"
require "timeout"
require_relative "../lib/hq/registry"
require_relative "../lib/hq/domain/managed_agent"

module CustomPromptTransportTest
  module_function

  def assert(value, message)
    raise message unless value
  end

  def run!
    Dir.mktmpdir("tycho-custom-transport-") do |dir|
      registry = HQ::Registry.allocate
      base = { "key" => "wrapper", "adapter" => "claude", "execution_command" => "wrapper" }
      [nil, "stdin", {}, { "version" => 2, "mode" => "stdin" },
       { "version" => "1", "mode" => "stdin" }, { "version" => 1, "mode" => "env" },
       { "version" => 1, "mode" => "stdin", "extra" => true }, { 1 => "stdin", "version" => 1 }].each do |invalid|
        begin
          registry.send(:build_custom_harnesses, [base.merge("prompt_transport" => invalid)])
          raise "invalid transport accepted: #{invalid.inspect}"
        rescue HQ::ConfigError => e
          assert(e.message.include?("prompt_transport"), "unclear validation error")
        end
      end
      assert(registry.send(:build_custom_harnesses, [base]).first.prompt_transport.nil?, "default changed")
      script = File.join(dir, "wrapper.rb")
      File.write(script, <<~'CHILD')
        require "json"
        require "digest"
        require "open3"
        mode, capture = ARGV.shift(2)
        index = ARGV.index("--tycho-prompt-file")
        path = index && ARGV[index + 1]
        prompt = case mode
                 when "file" then File.binread(path)
                 when "argv" then ARGV.last.b
                 else STDIN.binmode.read
                 end
        record = {
          "digest" => Digest::SHA256.hexdigest(prompt), "size" => prompt.bytesize,
          "argv" => ARGV, "env" => ENV.to_h,
          "ps" => Open3.capture2("ps", "-p", Process.pid.to_s, "-o", "command=").first,
          "path" => path, "permissions" => path && (File.stat(path).mode & 0777),
          "directory_permissions" => path && (File.stat(File.dirname(path)).mode & 0777)
        }
        File.open(capture, "ab") { |f| f.puts(JSON.generate(record)) }
        if ENV["BLOCK_CUSTOM"] == "1"
          STDOUT.puts("ready")
          STDOUT.flush
          STDIN.read
          IO.select(nil, nil, nil, 60)
        end
        count = File.readlines(capture).length
        payload = count.odd? ? {} : { "status" => "success", "summary" => "応答 🛰️" }
        puts JSON.generate("type" => "session", "id" => "custom-session",
                           "thread_id" => "custom-session", "sessionID" => "custom-session",
                           "conversation_id" => "custom-session")
        puts JSON.generate("type" => "assistant", "session_id" => "custom-session",
                           "structured_output" => payload)
        puts JSON.generate("event" => "result", "result" => {
          "conversation_id" => "custom-session", "status" => "SUCCESS",
          "response" => JSON.generate(payload), "structured_output" => payload })
      CHILD
      %w[codex claude agy pi opencode].each do |adapter|
        %w[argv stdin file].each do |mode|
          profile = HQ::HarnessConfig.new(key: "shape", adapter: adapter,
            execution_command: [RbConfig.ruby, script, mode, File.join(dir, "shape-capture")],
            prompt_transport: { "version" => 1, "mode" => mode })
          HQ.custom_harnesses = [profile]
          [nil, "native-resume"].each do |session|
            prompt = "adapter-shape 日本語\n"
            agent = HQ::ManagedAgent.new(key: "shape", name: "Shape", project_key: "test",
              template_key: "custom", workspace: dir, prompt: prompt, agent: "shape",
              session_id: session, log_path: File.join(dir, "shape.log"))
            execution = agent.send(:build_command, prompt: prompt)
            output, error, status = Open3.capture3({ "LANG" => "C", "LC_ALL" => "C" },
              *execution[:command], stdin_data: execution[:stdin_data].to_s.b, binmode: true)
            assert(status.success?, "#{adapter} #{mode} failed: #{error}")
            record = JSON.parse(File.readlines(File.join(dir, "shape-capture")).last)
            assert(record["digest"] == Digest::SHA256.hexdigest(prompt), "#{adapter} bytes changed")
            assert(record["argv"].include?(session), "#{adapter} resume missing") if session
            if adapter == "pi"
              assert(record["argv"].include?("json"), "custom Pi must use JSON events")
            end
          end
        end
      end
      %w[argv stdin file].each do |mode|
        profile = registry.send(:build_custom_harnesses, [
          base.merge("execution_command" => [RbConfig.ruby, script, mode, File.join(dir, "capture")],
                     "prompt_transport" => { "version" => 1, "mode" => mode })
        ]).first
        HQ.custom_harnesses = [profile]
        prompts = ["", "PRIVATE_CUSTOM_816\n日本語 🛰️\n\n"]
        prompts << "PRIVATE_CUSTOM_816\n" + ("é\n" * 600_000) unless mode == "argv"
        prompts.each do |prompt|
          [nil, "resumed-session"].each do |session|
            capture = File.join(dir, "capture")
            File.unlink(capture) if File.exist?(capture)
            agent = HQ::ManagedAgent.new(key: "custom", name: "Custom", project_key: "test",
              template_key: "custom", workspace: dir, prompt: prompt, agent: "wrapper",
              session_id: session, log_path: File.join(dir, "raw.log"))
            execution = agent.send(:build_command, prompt: prompt)
            input = HQ::AgentPromptTransport.input(execution[:stdin_data])
            output, error, status = Open3.capture3({ "LANG" => "C", "LC_ALL" => "C" },
              *execution[:command], stdin_data: "", binmode: true) if mode == "argv"
            unless mode == "argv"
              reader, writer = IO.pipe
              pid = Process.spawn({ "LANG" => "C", "LC_ALL" => "C" }, *execution[:command],
                in: input, out: writer)
              input.close
              writer.close
              Timeout.timeout(15) { reader.read }
              reader.close
              _, status = Process.wait2(pid)
            end
            assert(status.success?, "custom #{mode} failed: #{error}")
            record = JSON.parse(File.read(capture))
            assert(record["digest"] == Digest::SHA256.hexdigest(prompt), "bytes changed")
            assert(record["size"] == prompt.bytesize, "size changed")
            assert(record["argv"].include?(session), "resume missing") if session
            assert(prompt.empty? || !execution[:description].join.include?(prompt), "description leaked")
            unless mode == "argv" || prompt.empty?
              assert(!(record["argv"] + record["env"].values).join.include?(prompt), "prompt exposed")
              assert(!record["ps"].include?("PRIVATE_CUSTOM_816"), "ps exposed prompt")
            end
            if mode == "file"
              assert(record["permissions"] == 0600 && record["directory_permissions"] == 0700, "unsafe file")
              assert(!File.exist?(File.dirname(record["path"])), "file directory remains")
            end
          end
        end

        # Use the actual shared correction-runner configuration from the managed agent.
        %w[codex claude agy pi opencode].each do |adapter|
          profile.adapter = adapter
          capture = File.join(dir, "capture")
          File.unlink(capture)
          schema = File.join(dir, "schema.json")
          File.write(schema, JSON.generate("type" => "object", "required" => ["status", "summary"]))
          agent = HQ::ManagedAgent.new(key: "correction", name: "Correction", project_key: "test",
            template_key: "custom", workspace: dir, prompt: "日本語\n", agent: "wrapper",
            log_path: File.join(dir, "correction.log"))
          agent.define_singleton_method(:result_schema_path) { schema }
          execution = agent.send(:build_command, prompt: "日本語\n")
          launch = agent.send(:structured_output_runner_launch, execution[:command], execution[:env], execution)
          output, error, status = Timeout.timeout(15) do
            Open3.capture3(launch[:env].merge("LANG" => "C", "LC_ALL" => "C"), *launch[:command],
              stdin_data: launch[:stdin_data].b, binmode: true)
          end
          assert(status.success?, "correction #{mode}: #{error} #{output}")
          records = File.readlines(capture).map { |line| JSON.parse(line) }
          assert(records.size == 2, "correction did not retry")
          assert(records.last["argv"].include?("custom-session"), "correction lost session")
          if mode == "file"
            assert(records.all? { |record| !File.exist?(File.dirname(record["path"])) }, "retry file remains")
          end
        end
      end

      %w[argv stdin file].each do |mode|
        capture = File.join(dir, "managed-#{mode}.jsonl")
        profile = HQ::HarnessConfig.new(key: "managed-wrapper", adapter: "claude",
          execution_command: [RbConfig.ruby, script, mode, capture],
          prompt_transport: { "version" => 1, "mode" => mode })
        HQ.custom_harnesses = [profile]
        prompt = "MANAGED_CUSTOM_816\n日本語 🛰️\n\n"
        agent = HQ::ManagedAgent.new(key: "managed-#{mode}", name: "Managed", project_key: "test",
          template_key: "custom", workspace: dir, prompt: prompt, agent: "managed-wrapper",
          log_path: File.join(dir, "managed-#{mode}.log"),
          messages: [HQ::ManagedAgent::AgentMessage.new(role: "system", content: prompt, created_at: Time.now)])
        agent.start!
        Timeout.timeout(15) { agent.instance_variable_get(:@process_monitors).values.each(&:join) }
        agent.poll!
        assert(File.binread(agent.raw_log_path).include?(prompt.b), "managed raw log lost prompt")
        assert(File.binread(agent.memory_path).include?("MANAGED_CUSTOM_816"), "managed memory lost prompt")
        assert(!agent.runs.last.command.include?("MANAGED_CUSTOM_816"), "managed metadata leaked")
        if mode == "file"
          records = File.readlines(capture).map { |line| JSON.parse(line) }
          assert(records.all? { |record| !File.exist?(File.dirname(record["path"])) }, "managed file remains")
        end
      end

      # Cancel each transport through its real wrapper process.
      %w[argv stdin file].each do |mode|
        capture = File.join(dir, "cancel-#{mode}.json")
        command = [RbConfig.ruby, script, mode, capture]
        if mode == "file"
          command = [RbConfig.ruby, "--disable-gems",
            File.expand_path("../lib/hq/domain/custom_prompt_file_runner.rb", __dir__)] + command
        elsif mode == "argv"
          command << "cancel 日本語"
        end
        Open3.popen3({ "BLOCK_CUSTOM" => "1" }, *command) do |input, output, error, waiter|
          input.write("cancel 日本語") unless mode == "argv"
          input.close
          assert(Timeout.timeout(10) { output.gets } == "ready\n", "#{mode} cancel child not ready")
          path = JSON.parse(File.read(capture))["path"]
          Process.kill("TERM", waiter.pid)
          status = Timeout.timeout(10) { waiter.value }
          assert(!status.success?, "#{mode} cancel did not stop wrapper")
          assert(!File.exist?(File.dirname(path)), "cancel left private file") if path
        end
      end

      # Failed spawn also releases its private directory.
      output, error, status = Open3.capture3(RbConfig.ruby, "--disable-gems",
        File.expand_path("../lib/hq/domain/custom_prompt_file_runner.rb", __dir__),
        File.join(dir, "missing"), stdin_data: "private")
      assert(!status.success?, "missing wrapper accepted")
      assert(Dir.children(HQ::CustomPromptFiles.root).empty?, "failed spawn left private file")
    ensure
      HQ.custom_harnesses = []
    end
    puts "custom_prompt_transport_test: ok"
  end
end

CustomPromptTransportTest.run!
