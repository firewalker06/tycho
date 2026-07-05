# frozen_string_literal: true

require "fileutils"
require "json"
require "stringio"
require "tmpdir"

require_relative "../lib/hq/cli_command"
require_relative "../lib/hq/domain/managed_agent"

module CLICommandTest
  module_function

  def run!
    assert_debug_claude_is_listed_in_usage
    assert_debug_claude_run_agent_uses_claude_defaults
    puts "cli_command_test: ok"
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
