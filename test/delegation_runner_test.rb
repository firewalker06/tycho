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
      upload_workspace = File.join(dir, "upload-workspace")
      logs = File.join(dir, "logs")
      config = File.join(dir, "hq.yml")
      prompts = File.join(dir, "system_prompts.yml")
      harness = File.join(dir, "fake-codex.rb")
      FileUtils.mkdir_p(workspace)
      FileUtils.mkdir_p(upload_workspace)
      File.write(config, <<~YAML)
        projects:
          - key: demo
            name: Demo
            path: #{workspace}
            agent: codex
          - key: uploads
            name: Uploads
            path: #{upload_workspace}
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
          "summary_sections" => nil,
          "inquiry" => nil,
          "attachments" => nil,
          "memory_handoff" => nil
        }
        resumed_session = ARGV.find { |argument| argument.start_with?("fake-") }
        session_id = resumed_session || "fake-#{Process.pid}"
        File.write(output, JSON.generate(payload)) if output
        puts JSON.generate("type" => "thread.started", "thread_id" => session_id)
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

      clean_env = env.merge("TYCHO_AGENT_KEY" => nil)
      parent = run_cli(clean_env, "agent", "create", "demo", "Coordinate delegated work", "--run", "--json")
      parent_payload = JSON.parse(parent)
      raise "ordinary create outside a managed agent gained a parent" if parent_payload.dig("delegation", "parent")

      parent_key = parent_payload.fetch("key")
      agents_path = File.join(logs, "managed_agents.json")
      wait_for_agent(agents_path, parent_key, minimum_runs: 1)
      managed_agent_env = clean_env.merge("TYCHO_AGENT_KEY" => parent_key)
      implicit_root = run_cli(
        managed_agent_env, "agent", "create", "uploads", "No explicit parent", "--json"
      )
      if JSON.parse(implicit_root).dig("delegation", "parent")
        raise "TYCHO_AGENT_KEY implicitly created a delegation"
      end
      child = run_cli(
        managed_agent_env,
        "agent", "create", "uploads", "Finish delegated work",
        "--parent-agent", parent_key, "--json"
      )
      child_key = JSON.parse(child).fetch("key")
      unless JSON.parse(child).dig("delegation", "parent", "agent_key") == parent_key
        raise "explicit parent key did not create a delegated child"
      end
      run_cli(
        managed_agent_env,
        "agent", "send", child_key, "Execute the delegated work",
        "--parent-agent", parent_key, "--json"
      )
      unrelated = run_cli(managed_agent_env, "agent", "create", "demo", "Create unrelated root", "--root", "--json")
      if JSON.parse(unrelated).dig("delegation", "parent")
        raise "--root unexpectedly created a parent relationship"
      end
      _stdout, conflict_error, conflict_status = capture_cli(
        managed_agent_env, "agent", "create", "demo", "Conflicting parent choice",
        "--root", "--parent-agent", parent_key
      )
      if conflict_status.success? || !conflict_error.include?("Choose either --parent-agent or --root")
        raise "conflicting delegation choices did not fail clearly"
      end
      deadline = Time.now + 12
      parent_record = nil
      until Time.now >= deadline
        agents = File.exist?(agents_path) ? JSON.parse(File.read(agents_path)) : []
        parent_record = agents.find { |agent| agent["key"] == parent_key }
        break if parent_record && parent_record.fetch("total_run_count", 0) >= 2

        sleep 0.1
      end
      unless parent_record&.fetch("total_run_count", 0).to_i >= 2
        ledger_debug = File.exist?(File.join(logs, "agent_delegations.json")) ? File.read(File.join(logs, "agent_delegations.json")) : "missing ledger"
        log_debug = File.exist?(File.join(logs, "hq.log")) ? File.read(File.join(logs, "hq.log")) : "missing log"
        raise "detached completion did not resume parent\n#{JSON.pretty_generate(JSON.parse(File.read(agents_path)))}\n#{ledger_debug}\n#{log_debug}"
      end

      memory_path = parent_record.fetch("log_path").sub(/\.raw\.log\z/, ".memory.jsonl")
      events = File.readlines(memory_path).map { |line| JSON.parse(line) }
      callback = events.find { |event| event.dig("metadata", "delegation_callback") }
      raise "missing detached callback message" unless callback
      raise "callback did not name child" unless callback.dig("metadata", "agent_reference", "agent_key") == child_key

      child_record = wait_for_agent(agents_path, child_key, minimum_runs: 1)
      child_memory_path = child_record.fetch("log_path").sub(/\.raw\.log\z/, ".memory.jsonl")
      child_events = File.readlines(child_memory_path).map { |line| JSON.parse(line) }
      signed_prompt = child_events.find { |event| event["content"] == "Execute the delegated work" }
      unless signed_prompt&.dig("metadata", "message_author", "agent_key") == parent_key &&
             signed_prompt.dig("metadata", "message_author", "name") == parent_payload.fetch("name")
        raise "local --parent-agent send did not persist the parent signature"
      end

      reports = []
      deadline = Time.now + 12
      until Time.now >= deadline
        ledger = JSON.parse(File.read(File.join(logs, "agent_delegations.json")))
        reports = ledger.fetch("reports").select { |report| report.dig("child", "agent_key") == child_key }
        break if reports.length == 1 && reports.first["resume_state"] == "resumed"

        sleep 0.05
      end
      raise "expected one deduplicated child report" unless reports.length == 1
      raise "expected automatic resume record" unless reports.first["resume_state"] == "resumed"

      wait_for_agent(agents_path, parent_key, minimum_runs: 2)
      wait_for_store_idle(agents_path)
      assert_nested_callbacks(clean_env, agents_path, logs, parent_key, parent_runs: 2)
    end
    puts "delegation_runner_test: ok"
  end

  def assert_nested_callbacks(env, agents_path, logs, root_key, parent_runs:)
    # A -> B -> C: B is both a delegated child and a callback receiver.
    middle = JSON.parse(run_cli(env, "agent", "create", "uploads", "Coordinate nested work",
                               "--parent-agent", root_key, "--json"))
    middle_key = middle.fetch("key")
    leaf = JSON.parse(run_cli(env, "agent", "create", "uploads", "Finish leaf work",
                             "--parent-agent", middle_key, "--run", "--json"))
    leaf_key = leaf.fetch("key")
    wait_for_agent(agents_path, leaf_key, minimum_runs: 1)
    middle_record = wait_for_agent(agents_path, middle_key, minimum_runs: 1)
    root_record = wait_for_agent(agents_path, root_key, minimum_runs: parent_runs + 1)
    wait_for_store_idle(agents_path)

    ledger = JSON.parse(File.read(File.join(logs, "agent_delegations.json")))
    [middle_key, leaf_key].each do |key|
      relation = ledger.fetch("relationships").find { |item| item.dig("child", "agent_key") == key }
      unless relation["owner"] == "parent" && relation["ownership_generation"] == 1
        raise "nested callback changed edge ownership for #{key}"
      end
      reports = ledger.fetch("reports").select { |report| report.dig("child", "agent_key") == key }
      unless reports.length == 1 && reports.first["resume_state"] == "resumed"
        raise "nested completion did not reach its recorded parent exactly once for #{key}"
      end
    end
    unless middle_record.fetch("runs").last.values_at("delegation_owner", "delegation_generation") == ["parent", 1]
      raise "callback resumed middle agent without its upstream ownership stamp"
    end
    [[middle_record, leaf_key], [root_record, middle_key]].each do |record, child_key|
      path = record.fetch("log_path").sub(/\.raw\.log\z/, ".memory.jsonl")
      events = File.readlines(path).map { |line| JSON.parse(line) }
      callback = events.find do |event|
        metadata = event["metadata"] || {}
        metadata["delegation_callback"] && metadata.dig("agent_reference", "agent_key") == child_key
      end
      unless callback && callback.dig("metadata", "message_author", "type") == "agent"
        raise "nested callback lost internal agent provenance for #{child_key}"
      end
      # The canonical batch entries retain their protected source at each hop.
      entries = callback.dig("metadata", "prompt_queue_entries") || []
      unless entries.any? { |entry| entry["source"] == "delegation_callback" }
        raise "nested callback lost its protected queue source: #{callback.fetch('metadata').keys}"
      end
    end

    # A direct user prompt is still Takeover. A later C report must not
    # reclaim B on behalf of A or create an upstream completion callback.
    run_cli(env, "agent", "send", middle_key, "User takes control", "--json")
    wait_for_agent(agents_path, middle_key, minimum_runs: 2)
    run_cli(env, "agent", "send", leaf_key, "Finish another leaf turn",
            "--parent-agent", middle_key, "--json")
    wait_for_agent(agents_path, leaf_key, minimum_runs: 2)
    middle_record = wait_for_agent(agents_path, middle_key, minimum_runs: 3)
    wait_for_store_idle(agents_path)
    ledger = JSON.parse(File.read(File.join(logs, "agent_delegations.json")))
    relation = ledger.fetch("relationships").find { |item| item.dig("child", "agent_key") == middle_key }
    unless relation.values_at("owner", "ownership_generation") == ["user", 2] &&
           middle_record.fetch("runs").last.values_at("delegation_owner", "delegation_generation") == ["user", 2]
      raise "nested callback reclaimed a real user takeover"
    end
    upstream = ledger.fetch("reports").select { |report| report.dig("child", "agent_key") == middle_key }
    raise "user-owned nested run reported upstream" unless upstream.length == 1

    run_cli(env, "agent", "send", middle_key, "Parent reclaims delegated work",
            "--parent-agent", root_key, "--json")
    wait_for_agent(agents_path, middle_key, minimum_runs: 4)
    wait_for_agent(agents_path, root_key, minimum_runs: parent_runs + 2)
    wait_for_store_idle(agents_path)
    ledger = JSON.parse(File.read(File.join(logs, "agent_delegations.json")))
    relation = ledger.fetch("relationships").find { |item| item.dig("child", "agent_key") == middle_key }
    reports = ledger.fetch("reports").select { |report| report.dig("child", "agent_key") == middle_key }
    unless relation.values_at("owner", "ownership_generation") == ["parent", 3] &&
           reports.map { |report| report["ownership_generation"] }.sort == [1, 3]
      raise "parent reclaim lost its new generation or replayed a user-owned nested run"
    end
  end

  def run_cli(env, *args)
    stdout, stderr, status = capture_cli(env, *args)
    raise "CLI failed: #{stderr}\n#{stdout}" unless status.success?

    stdout
  end

  def capture_cli(env, *args)
    command = [env, RbConfig.ruby, File.join(ROOT, "bin", "tycho"), *args]
    Open3.capture3(*command, chdir: ROOT)
  end

  def wait_for_agent(path, key, minimum_runs:)
    deadline = Time.now + 12
    loop do
      agents = File.exist?(path) ? JSON.parse(File.read(path)) : []
      record = agents.find { |agent| agent["key"] == key }
      return record if record && record.fetch("total_run_count", 0).to_i >= minimum_runs && record["finished_at"]
      if Time.now >= deadline
        raise "agent #{key} did not finish: #{record ? JSON.generate(record) : "missing"}"
      end

      sleep 0.1
    end
  end

  def wait_for_store_idle(path)
    File.open("#{path}.lock", File::RDWR | File::CREAT, 0o600) do |file|
      file.flock(File::LOCK_EX)
    ensure
      file.flock(File::LOCK_UN)
    end
  end

end

DelegationRunnerTest.run! if $PROGRAM_NAME == __FILE__
