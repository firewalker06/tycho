# frozen_string_literal: true

require "tmpdir"
require "fileutils"
require "json"

require_relative "../lib/hq/domain/constants"
require_relative "../lib/hq/hooks"

module HooksTest
  module_function

  def run!
    assert_yaml_loading
    assert_per_project_merge
    assert_wildcard_matching
    assert_shell_runner_timeout
    assert_ruby_runner_dispatch
    assert_blocking_response_parsing
    assert_dispatcher_async_publish
    puts "hooks_test: ok"
  end

  def assert_yaml_loading
    Dir.mktmpdir("hq-hooks-yaml") do |dir|
      yaml_path = File.join(dir, "hooks.yml")
      File.write(yaml_path, <<~YAML)
        hooks:
          agent.run.started:
            - command: "/bin/true"
              env:
                FOO: bar
      YAML

      reg = HQ::Hooks::Registry.new
      reg.load!(global_path: yaml_path, projects: [], ruby_dirs: [])
      handlers = reg.handlers_for("agent.run.started")
      assert(handlers.length == 1, "expected one handler, got #{handlers.length}")
      h = handlers.first
      assert(h[:type] == :shell, "expected shell handler")
      assert(h[:command] == "/bin/true", "expected command /bin/true, got #{h[:command]}")
      assert(h[:env]["FOO"] == "bar", "expected env FOO=bar")
      assert(h[:blocking] == false, "expected non-blocking default")
      assert(h[:timeout] == 10, "expected default async timeout 10")
    end
  end

  def assert_per_project_merge
    Dir.mktmpdir("hq-hooks-merge") do |dir|
      yaml_path = File.join(dir, "hooks.yml")
      File.write(yaml_path, <<~YAML)
        hooks:
          agent.run.started:
            - command: "/bin/global"
      YAML

      project = OpenStructLike.new(
        key: "web",
        path: "/tmp/web",
        hooks: { "agent.run.started" => [{ "command" => "/bin/project" }] }
      )

      reg = HQ::Hooks::Registry.new
      reg.load!(global_path: yaml_path, projects: [project], ruby_dirs: [])
      handlers = reg.handlers_for("agent.run.started", project_key: "web")
      assert(handlers.length == 2, "expected global+project handlers")
      assert(handlers[0][:command] == "/bin/global", "global handler first")
      assert(handlers[1][:command] == "/bin/project", "project handler second")

      other = reg.handlers_for("agent.run.started", project_key: "docs")
      assert(other.length == 1, "expected only global for unrelated project")
    end
  end

  def assert_wildcard_matching
    reg = HQ::Hooks::Registry.new
    reg.register_ruby_handler("agent.*") { |_| nil }
    reg.register_ruby_handler("agent.run.*") { |_| nil }
    reg.register_ruby_handler("*") { |_| nil }

    matched = reg.handlers_for("agent.run.started")
    assert(matched.length == 3, "expected agent.*, agent.run.*, * to all match — got #{matched.length}")

    not_agent = reg.handlers_for("config.loaded")
    assert(not_agent.length == 1, "expected only '*' wildcard to match config.loaded — got #{not_agent.length}")
  end

  def assert_shell_runner_timeout
    Dir.mktmpdir("hq-hooks-timeout") do |dir|
      # Redirect hooks log to the temp dir
      old_log = HQ::HOOKS_LOG_FILE
      HQ.send(:remove_const, :HOOKS_LOG_FILE)
      HQ.const_set(:HOOKS_LOG_FILE, File.join(dir, "hooks.log"))
      HQ::Hooks::ShellRunner.instance_variable_set(:@hooks_log, nil)

      hook = {
        type: :shell,
        pattern: "test",
        command: "/bin/sleep 5",
        env: {},
        blocking: false,
        timeout: 1
      }
      started = Time.now
      HQ::Hooks::ShellRunner.call(hook, "test", { "agent_key" => "x" })
      elapsed = Time.now - started
      assert(elapsed < 3, "expected timeout to kill process within 3s, got #{elapsed}s")
    ensure
      if old_log
        HQ.send(:remove_const, :HOOKS_LOG_FILE)
        HQ.const_set(:HOOKS_LOG_FILE, old_log)
        HQ::Hooks::ShellRunner.instance_variable_set(:@hooks_log, nil)
      end
    end
  end

  def assert_ruby_runner_dispatch
    received = []
    hook = {
      type: :ruby,
      pattern: "x",
      handler: ->(payload) { received << payload },
      blocking: false,
      timeout: 10
    }
    HQ::Hooks::RubyRunner.call(hook, "x", { "a" => 1 })
    assert(received.length == 1, "expected handler invoked once")
    assert(received.first["a"] == 1, "expected payload delivered")

    # Exception path — should not propagate
    raising_hook = hook.merge(handler: ->(_) { raise "boom" })
    HQ::Hooks::RubyRunner.call(raising_hook, "x", {})
  end

  def assert_blocking_response_parsing
    Dir.mktmpdir("hq-hooks-blocking") do |dir|
      old_log = HQ::HOOKS_LOG_FILE
      HQ.send(:remove_const, :HOOKS_LOG_FILE)
      HQ.const_set(:HOOKS_LOG_FILE, File.join(dir, "hooks.log"))
      HQ::Hooks::ShellRunner.instance_variable_set(:@hooks_log, nil)

      script = File.join(dir, "respond.sh")
      File.write(script, <<~SH)
        #!/bin/sh
        cat >/dev/null
        printf '{"answer":"yes"}'
      SH
      FileUtils.chmod(0o755, script)

      hook = {
        type: :shell,
        pattern: "agent.inquiry.available",
        command: script,
        env: {},
        blocking: true,
        timeout: 5
      }
      response = HQ::Hooks::ShellRunner.call(hook, "agent.inquiry.available",
                                             { "agent_key" => "x", "project_key" => "y" },
                                             blocking: true)
      assert(response.is_a?(Hash), "expected Hash response, got #{response.inspect}")
      assert(response["answer"] == "yes", "expected parsed answer=yes")
    ensure
      if old_log
        HQ.send(:remove_const, :HOOKS_LOG_FILE)
        HQ.const_set(:HOOKS_LOG_FILE, old_log)
        HQ::Hooks::ShellRunner.instance_variable_set(:@hooks_log, nil)
      end
    end
  end

  def assert_dispatcher_async_publish
    received = []
    reg = HQ::Hooks::Registry.new
    reg.register_ruby_handler("test.event") { |payload| received << payload }
    dispatcher = HQ::Hooks::Dispatcher.new(registry: reg)
    dispatcher.start!
    dispatcher.publish("test.event", { "a" => 1 })

    deadline = Time.now + 2
    sleep 0.05 while received.empty? && Time.now < deadline

    dispatcher.stop!
    assert(received.length == 1, "expected async handler invoked, got #{received.length}")
    assert(received.first["a"] == 1, "expected payload delivered")
  end

  class OpenStructLike
    def initialize(attrs)
      @attrs = attrs
    end

    def method_missing(name, *)
      @attrs.key?(name) ? @attrs[name] : super
    end

    def respond_to_missing?(name, _priv = false)
      @attrs.key?(name) || super
    end
  end

  def assert(condition, message)
    raise message unless condition
  end
end

HooksTest.run! if $PROGRAM_NAME == __FILE__
