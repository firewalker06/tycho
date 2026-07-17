# frozen_string_literal: true

require "fileutils"
require "json"
require "open3"
require "rbconfig"
require "stringio"
require "tmpdir"
require "yaml"

require_relative "../lib/hq/cli_command"
require_relative "../lib/hq/domain/managed_agent"

module CLICommandTest
  ROOT = File.expand_path("..", __dir__)
  EXECUTABLE = File.join(ROOT, "bin", "tycho")

  module_function

  def run!
    assert_project_commands_manage_full_lifecycle
    assert_debug_claude_is_listed_in_usage
    assert_debug_claude_run_agent_uses_claude_defaults
    puts "cli_command_test: ok"
  end

  def assert_project_commands_manage_full_lifecycle
    Dir.mktmpdir("hq-cli-project-test") do |dir|
      workspace = File.join(dir, "workspace")
      config_path = File.join(dir, "hq.yml")
      prompts_path = File.join(dir, "system_prompts.yml")
      logs_root = File.join(dir, "logs")
      FileUtils.mkdir_p(workspace)
      File.write(config_path, "projects: []\n")
      File.write(prompts_path, "{}\n")
      env = {
        "TYCHO_CONFIG_PATH" => config_path,
        "TYCHO_SYSTEM_PROMPTS_PATH" => prompts_path,
        "TYCHO_LOGS_ROOT" => logs_root
      }

      created = run_tycho(env, "project", "demo", "--path", workspace, "--name", "Demo Project",
                          "--group", "Core", "--harness", "codex", "--model", "gpt-test",
                          "--reasoning-effort", "high", "--response-style", "disabled",
                          "--pr-url", "https://github.com/example/demo/pull/7", "--hidden", "true", "--json")
      assert(created.fetch(:status).success?, "expected shorthand project creation to succeed: #{created.fetch(:stderr)}")
      created_payload = JSON.parse(created.fetch(:stdout))
      assert(created_payload["key"] == "demo", "expected created project key")
      assert(created_payload["path"] == workspace, "expected created project path")
      assert(created_payload["harness"] == "codex", "expected created project harness")
      assert(created_payload["response_style"] == false, "expected disabled response style")
      assert(created_payload["hidden"] == true, "expected hidden project override")

      shown = run_tycho(env, "project", "show", "demo", "--json")
      assert(shown.fetch(:status).success?, "expected project show to succeed: #{shown.fetch(:stderr)}")
      shown_payload = JSON.parse(shown.fetch(:stdout))
      assert(shown_payload["model"] == "gpt-test", "expected project show to expose model")
      assert(shown_payload["pr_url"].end_with?("/pull/7"), "expected project show to expose PR URL")

      updated = run_tycho(env, "project", "update", "demo", "--name", "Demo Updated", "--group=",
                          "--model=", "--reasoning-effort", "low", "--response-style", "default",
                          "--pr-url=", "--hidden", "inherit", "--json")
      assert(updated.fetch(:status).success?, "expected project update to succeed: #{updated.fetch(:stderr)}")
      updated_payload = JSON.parse(updated.fetch(:stdout))
      assert(updated_payload["name"] == "Demo Updated", "expected updated project name")
      assert(updated_payload["group"].nil?, "expected project group to clear")
      assert(updated_payload["model"].nil?, "expected project model to clear")
      assert(updated_payload["reasoning_effort"] == "low", "expected project effort to update")
      assert(updated_payload["response_style"].nil?, "expected response style to return to global default")
      assert(updated_payload["pr_url"].nil?, "expected PR URL to clear")
      assert(updated_payload["hidden_override"].nil?, "expected visibility to inherit")

      explicit = run_tycho(env, "project", "create", "explicit", "--path", workspace, "--json")
      assert(explicit.fetch(:status).success?, "expected explicit project create to succeed: #{explicit.fetch(:stderr)}")
      assert(JSON.parse(explicit.fetch(:stdout))["key"] == "explicit", "expected explicit project create key")
      agent_created = run_tycho(env, "agent", "create", "explicit", "Check this project")
      assert(agent_created.fetch(:status).success?, "expected project fixture agent creation to succeed")
      agent_key = JSON.parse(File.read(File.join(logs_root, "managed_agents.json"))).fetch(0).fetch("key")
      explicit_archived = run_tycho(env, "project", "archive", "explicit", "--json")
      assert(explicit_archived.fetch(:status).success?, "expected project archive with agents to succeed")
      assert(JSON.parse(explicit_archived.fetch(:stdout)).fetch("archived_agent_keys") == [agent_key],
             "expected project archive to include managed agents")
      assert(JSON.parse(File.read(File.join(logs_root, "managed_agents.json"))).empty?,
             "expected project archive to remove managed agents from active state")

      archived = run_tycho(env, "project", "archive", "demo", "--json")
      assert(archived.fetch(:status).success?, "expected project archive to succeed: #{archived.fetch(:stderr)}")
      archived_payload = JSON.parse(archived.fetch(:stdout))
      assert(archived_payload.dig("project", "key") == "demo", "expected archived project payload")
      active = YAML.safe_load_file(config_path, aliases: true).fetch("projects")
      archived_config = YAML.safe_load_file(File.join(dir, "hq.archived.yml"), aliases: true).fetch("projects")
      assert(active.none? { |project| project["key"] == "demo" }, "expected archived project to leave active config")
      assert(archived_config.any? { |project| project["key"] == "demo" }, "expected archived project config")

      missing = run_tycho(env, "project", "show", "demo", "--json")
      assert(!missing.fetch(:status).success?, "expected archived project to be absent from project show")
      assert(missing.fetch(:stderr).include?("Unknown project: demo"), "expected clear missing-project error")
    end
  end

  def assert_debug_claude_is_listed_in_usage
    err = StringIO.new
    HQ::CLICommand.usage(nil, err: err)

    assert(err.string.include?("tycho debug claude [--run-agent]"),
           "expected usage to list the Claude debug command")
  end

  def assert_debug_claude_run_agent_uses_claude_defaults
    Dir.mktmpdir("hq-cli-debug-claude-test") do |dir|
      config_path = File.join(dir, "hq.yml")
      prompts_path = File.join(dir, "system_prompts.yml")
      logs_dir = File.join(dir, "logs")
      agents_file = File.join(logs_dir, "managed_agents.json")
      agent_logs_dir = File.join(logs_dir, "agents")
      FileUtils.mkdir_p(agent_logs_dir)
      File.write(config_path, <<~YAML)
        projects:
          - key: tycho
            name: Tycho
            path: #{dir}
            agent: codex
            model: gpt-5.1-codex-max
            reasoning_effort: high
      YAML
      File.write(prompts_path, <<~YAML)
        custom: Base prompt
      YAML

      with_env("TYCHO_CONFIG_PATH" => config_path, "TYCHO_SYSTEM_PROMPTS_PATH" => prompts_path) do
        with_constant(HQ, :AGENTS_FILE, agents_file) do
          with_constant(HQ, :AGENT_LOGS_DIR, agent_logs_dir) do
            with_stubbed_agent_start do |started_agents|
              out = StringIO.new
              err = StringIO.new
              code = HQ::CLICommand.debug_claude({ run_agent: true }, out: out, err: err)
              saved = JSON.parse(File.read(agents_file)).fetch(0)
              started = started_agents.fetch(0)

              assert(code == 0, "expected debug Claude managed-agent diagnostic to succeed")
              assert(err.string.empty?, "expected no stderr output")
              assert(out.string.include?("Tycho Claude managed-agent diagnostic"),
                     "expected managed-agent diagnostic header")
              assert(started.agent == "claude", "expected diagnostic to force the Claude harness")
              assert(started.model.nil?, "expected diagnostic to leave Claude model unset")
              assert(started.reasoning_effort.nil?, "expected diagnostic to leave Claude effort unset")
              assert(saved["agent"] == "claude", "expected persisted diagnostic agent to use Claude")
              assert(!saved.key?("model"), "expected persisted diagnostic agent to omit model override")
              assert(!saved.key?("reasoning_effort"), "expected persisted diagnostic agent to omit effort override")
            end
          end
        end
      end
    end
  end

  def with_stubbed_agent_start
    started_agents = []
    original_start = HQ::ManagedAgent.instance_method(:start!)
    original_poll = HQ::ManagedAgent.instance_method(:poll!)
    original_running = HQ::ManagedAgent.instance_method(:running?)
    HQ::ManagedAgent.define_method(:start!) do
      started_agents << self
      @started_at = Time.now
      @finished_at = @started_at
      @pid = 12_345
      @last_exit_code = 0
      @summary = "OK"
      @runs << HQ::ManagedAgent::AgentRun.new(
        started_at: @started_at,
        finished_at: @finished_at,
        exit_code: 0,
        status: "succeeded",
        log_path: @log_path,
        command: "claude --print"
      )
      true
    end
    HQ::ManagedAgent.define_method(:poll!) { nil }
    HQ::ManagedAgent.define_method(:running?) { false }
    yield started_agents
  ensure
    HQ::ManagedAgent.define_method(:start!, original_start) if original_start
    HQ::ManagedAgent.define_method(:poll!, original_poll) if original_poll
    HQ::ManagedAgent.define_method(:running?, original_running) if original_running
  end

  def run_tycho(env, *args)
    stdout, stderr, status = Open3.capture3(env, RbConfig.ruby, EXECUTABLE, *args, chdir: ROOT)
    { stdout: stdout, stderr: stderr, status: status }
  end

  def with_env(values)
    previous = values.each_with_object({}) { |(key, _), memo| memo[key] = ENV.key?(key) ? ENV[key] : :__unset__ }
    values.each { |key, value| ENV[key] = value }
    yield
  ensure
    previous.each do |key, value|
      value == :__unset__ ? ENV.delete(key) : ENV[key] = value
    end
  end

  def with_constant(scope, name, value)
    old_value = scope.const_get(name)
    scope.send(:remove_const, name)
    scope.const_set(name, value)
    yield
  ensure
    scope.send(:remove_const, name)
    scope.const_set(name, old_value)
  end

  def assert(condition, message)
    raise message unless condition
  end
end

CLICommandTest.run! if $PROGRAM_NAME == __FILE__
