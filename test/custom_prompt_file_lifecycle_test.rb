# frozen_string_literal: true

require "tmpdir"
require "json"
require "open3"
require "timeout"
require_relative "../lib/hq/registry"
require_relative "../lib/hq/domain/agent_store"

module CustomPromptFileLifecycleTest
  module_function

  def assert(value, message)
    raise message unless value
  end

  def join(agent)
    Timeout.timeout(20) { agent.instance_variable_get(:@process_monitors).values.each(&:join) }
    agent.poll!
  end

  def run!
    Dir.mktmpdir("tycho-file-lifecycle-") do |dir|
      wrapper = File.join(dir, "wrapper.rb")
      ready_path = File.join(dir, "ready")
      gate_path = File.join(dir, "gate")
      File.mkfifo(ready_path)
      File.mkfifo(gate_path)
      ready = File.open(ready_path, "r+")
      gate = File.open(gate_path, "r+")
      File.write(wrapper, <<~'CHILD')
        require "json"
        ready, gate = ARGV.shift(2)
        path = ARGV[ARGV.index("--tycho-prompt-file") + 1]
        prompt = File.binread(path)
        if ARGV.include?("--close-lease")
          lease = File.stat(File.join(File.dirname(path), "lease"))
          (3..64).each do |fd|
            io = IO.for_fd(fd, autoclose: false)
            io.close if io.stat.ino == lease.ino && io.stat.dev == lease.dev
          rescue ArgumentError, Errno::EBADF
            next
          end
        end
        File.open(ready, "w") { |f| f.puts(JSON.generate("pid" => Process.pid, "path" => path, "prompt" => prompt)) }
        File.open(gate, "r") { |f| f.read(1) }
        puts JSON.generate("type" => "assistant", "session_id" => "file-lifecycle",
                           "structured_output" => { "status" => "success", "summary" => "done" })
      CHILD
      prefix = [RbConfig.ruby, wrapper, ready_path, gate_path]
      HQ.custom_harnesses = [HQ::HarnessConfig.new(key: "lifecycle", adapter: "claude", execution_command: prefix,
        prompt_transport: { "version" => 1, "mode" => "file" })]
      read_ready = -> { JSON.parse(Timeout.timeout(15) { ready.gets }) }
      make_agent = lambda do |key, correction|
        agent = HQ::ManagedAgent.new(key: key, name: "Lifecycle", project_key: "test", template_key: "custom",
          workspace: dir, prompt: "PRIVATE_LIFECYCLE\n日本語 🛰️\n", agent: "lifecycle",
          log_path: File.join(dir, "#{key}.log"))
        agent.define_singleton_method(:structured_output_correction_supported?) { correction }
        agent
      end

      # CLI Stop, Remote UI Stop, and archive all use these managed lifecycle paths.
      [false, true].each do |correction|
        %w[stop archive kill-native-group].each do |action|
          agent = make_agent.call("#{action}-#{correction}", correction)
          agent.start!
          record = read_ready.call
          path = record.fetch("path")
          assert(File.file?(path), "managed prompt was not created")
          case action
          when "stop" then agent.stop!
          when "archive" then agent.retire_for_archive!
          else
            group = Process.getpgid(record.fetch("pid"))
            assert(group != Process.getpgrp, "native child must have its own process group")
            Process.kill("KILL", -group)
          end
          join(agent)
          assert(!agent.running?, "managed agent still running")
          assert(!File.exist?(File.dirname(path)), "#{action} correction=#{correction} left prompt directory")
        ensure
          agent&.stop! if agent&.running?
        end
      end

      runner = File.expand_path("../lib/hq/domain/custom_prompt_file_runner.rb", __dir__)
      crash = lambda do |close_lease = false|
        stale = nil
        command = prefix + (close_lease ? ["--close-lease"] : [])
        Open3.popen3(RbConfig.ruby, "--disable-gems", runner, *command) do |input, output, error, waiter|
          input.write("CRASH_PRIVATE\n日本語 🛰️\n")
          input.close
          record = read_ready.call
          stale = record.fetch("path")
          Timeout.timeout(10) do
            loop do
              owner = JSON.parse(File.read(File.join(File.dirname(stale), "owner.json")))
              break if owner["child_pid"] == record.fetch("pid")
              Thread.pass
            end
          end
          Process.kill("KILL", waiter.pid)
          waiter.value
          HQ::CustomPromptFiles.recover!
          assert(File.file?(stale), "recovery removed a live wrapper's prompt after runner crash")
          Process.kill("KILL", record.fetch("pid"))
          Timeout.timeout(10) { output.read }
          assert(File.file?(stale), "crash fixture did not leave a prompt")
        end
        stale
      end

      # Re-run a stopped agent to cover recovery before the next native launch.
      next_agent = make_agent.call("next-run", false)
      2.times do
        stale = crash.call
        next_agent.start!
        record = read_ready.call
        assert(!File.exist?(File.dirname(stale)), "next run retained crash prompt")
        assert(File.file?(record.fetch("path")), "next run removed active prompt")
        next_agent.stop!
        join(next_agent)
      end

      config = File.join(dir, "hq.yml")
      File.write(config, "projects: []\n")
      stale = crash.call
      HQ::Registry.new(path: config)
      assert(!File.exist?(File.dirname(stale)), "Tycho registry startup retained crash prompt")
      stale = crash.call(true)
      HQ::AgentStore.new([])
      assert(!File.exist?(File.dirname(stale)), "agent store recovery retained crash prompt")

      # Ignore unknown content, symlinks, wrong markers, and live PIDs, even if
      # the directory name looks like a Tycho-created prompt directory.
      outside = File.join(dir, "outside")
      Dir.mkdir(outside)
      File.write(File.join(outside, "prompt"), "unrelated")
      linked = File.join(HQ::CustomPromptFiles.root, "prompt-99999999-#{'a' * 32}")
      File.symlink(outside, linked)
      owned, lease = HQ::CustomPromptFiles.create
      lease.close
      HQ::CustomPromptFiles.recover!
      assert(File.directory?(owned), "recovery ignored live owner PID")
      HQ::CustomPromptFiles.remove(owned)
      stale = crash.call
      directory = File.dirname(stale)
      File.write(File.join(directory, "unrelated"), "keep")
      HQ::CustomPromptFiles.recover!
      assert(File.file?(stale), "recovery removed an unknown directory entry")
      File.unlink(File.join(directory, "unrelated"))
      File.unlink(stale)
      File.symlink(File.join(outside, "prompt"), stale)
      HQ::CustomPromptFiles.recover!
      assert(File.symlink?(stale), "recovery followed a prompt symlink")
      File.unlink(stale)
      File.write(stale, "stale", perm: 0o600)
      File.write(File.join(directory, "owner.json"), '{"format":"unrelated"}')
      HQ::CustomPromptFiles.recover!
      assert(File.file?(stale), "recovery removed an unrelated ownership marker")
      assert(File.read(File.join(outside, "prompt")) == "unrelated", "recovery changed unrelated file")
      File.unlink(linked)
      HQ::CustomPromptFiles.remove(directory)
    ensure
      ready&.close
      gate&.close
      HQ.custom_harnesses = []
    end
    puts "custom_prompt_file_lifecycle_test: ok"
  end
end

CustomPromptFileLifecycleTest.run!
