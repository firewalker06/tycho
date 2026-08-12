# frozen_string_literal: true

require "json"
require "fileutils"
require "open3"
require "rbconfig"
require "tmpdir"

module DelegationRunnerTest
  module_function

  ROOT = File.expand_path("..", __dir__)

  def run!
    Dir.mktmpdir("tycho-delegation-runner") do |dir|
      workspace = File.join(dir, "workspace")
      logs = File.join(dir, "logs")
      config = File.join(dir, "hq.yml")
      prompts = File.join(dir, "system_prompts.yml")
      harness = File.join(dir, "fake-codex.rb")
      FileUtils.mkdir_p(workspace)
      File.write(config, <<~YAML)
        projects:
          - key: demo
            name: Demo
            path: #{workspace}
            agent: codex
      YAML
      File.write(prompts, "{}\n")
      File.write(harness, <<~'RUBY')
        #!/usr/bin/env ruby
        require "json"
        output_index = ARGV.index("-o")
        output = output_index ? ARGV[output_index + 1] : nil
        payload = {
          "status" => "success",
          "summary" => "Completed by detached fake harness",
          "inquiry" => nil,
          "attachments" => nil
        }
        File.write(output, JSON.generate(payload)) if output
        puts JSON.generate("type" => "thread.started", "thread_id" => "fake-#{Process.pid}")
        puts JSON.generate("type" => "item.completed", "item" => {
          "type" => "agent_message", "text" => JSON.generate(payload)
        })
      RUBY
      FileUtils.chmod(0o755, harness)
      env = {
        "TYCHO_HOME" => dir,
        "TYCHO_CONFIG_PATH" => config,
        "TYCHO_SYSTEM_PROMPTS_PATH" => prompts,
        "TYCHO_LOGS_ROOT" => logs,
        "TYCHO_CODEX_BIN" => harness
      }

      parent = run_cli(env, "agent", "create", "demo", "Coordinate delegated work", "--json")
      parent_key = JSON.parse(parent).fetch("key")
      child = run_cli(env, "agent", "create", "demo", "Finish delegated work",
                      "--parent-agent", parent_key, "--run", "--json")
      child_key = JSON.parse(child).fetch("key")

      agents_path = File.join(logs, "managed_agents.json")
      deadline = Time.now + 12
      parent_record = nil
      until Time.now >= deadline
        agents = File.exist?(agents_path) ? JSON.parse(File.read(agents_path)) : []
        parent_record = agents.find { |agent| agent["key"] == parent_key }
        break if parent_record && parent_record.fetch("total_run_count", 0) >= 1

        sleep 0.1
      end
      unless parent_record&.fetch("total_run_count", 0).to_i >= 1
        ledger_debug = File.exist?(File.join(logs, "agent_delegations.json")) ? File.read(File.join(logs, "agent_delegations.json")) : "missing ledger"
        log_debug = File.exist?(File.join(logs, "hq.log")) ? File.read(File.join(logs, "hq.log")) : "missing log"
        raise "detached completion did not resume parent\n#{JSON.pretty_generate(JSON.parse(File.read(agents_path)))}\n#{ledger_debug}\n#{log_debug}"
      end

      memory_path = parent_record.fetch("log_path").sub(/\.raw\.log\z/, ".memory.jsonl")
      events = File.readlines(memory_path).map { |line| JSON.parse(line) }
      callback = events.find { |event| event.dig("metadata", "delegation_callback") }
      raise "missing detached callback message" unless callback
      raise "callback did not name child" unless callback.dig("metadata", "agent_reference", "agent_key") == child_key

      ledger = JSON.parse(File.read(File.join(logs, "agent_delegations.json")))
      reports = ledger.fetch("reports").select { |report| report.dig("child", "agent_key") == child_key }
      raise "expected one deduplicated child report" unless reports.length == 1
      raise "expected automatic resume record" unless reports.first["resume_state"] == "resumed"
    end
    puts "delegation_runner_test: ok"
  end

  def run_cli(env, *args)
    command = [env, RbConfig.ruby, File.join(ROOT, "bin", "tycho"), *args]
    stdout, stderr, status = Open3.capture3(*command, chdir: ROOT)
    raise "CLI failed: #{stderr}\n#{stdout}" unless status.success?

    stdout
  end
end

DelegationRunnerTest.run! if $PROGRAM_NAME == __FILE__
