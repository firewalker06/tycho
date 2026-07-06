# frozen_string_literal: true

require "tmpdir"
require "stringio"
require "fileutils"
require "open3"
require "rbconfig"

require_relative "../lib/hq/registry"
require_relative "../lib/hq/cli_command"
require_relative "../lib/hq/domain/project"
require_relative "../lib/hq/domain/agent_store"

module RegistryTest
  module_function

  def run!
    assert_registry_loads_system_prompts_from_sibling_config
    assert_registry_loads_model_and_effort_defaults
    assert_registry_ignores_hq_env_aliases
    assert_registry_uses_tycho_home_defaults
    assert_registry_resolves_hidden_groups_and_project_overrides
    assert_registry_loads_custom_claude_harnesses
    assert_registry_persists_remote_servers
    assert_custom_harness_resolves_executable_after_env_assignments
    assert_custom_harness_extracts_env_assignments_for_execution
    assert_registry_rejects_unsupported_custom_harness_adapters
    assert_agent_store_prepends_project_tool_system_prompt
    assert_agent_store_backfills_project_tool_system_prompt
    puts "registry_test: ok"
  end

  def assert_registry_loads_system_prompts_from_sibling_config
    Dir.mktmpdir("hq-registry-test") do |dir|
      config_path = File.join(dir, "hq.yml")
      prompts_path = File.join(dir, "system_prompts.yml")

      File.write(config_path, <<~YAML)
        projects:
          - key: demo
            name: Demo
            group: Personal
            path: #{File.join(dir, "demo")}
      YAML

      File.write(prompts_path, <<~YAML)
        custom: ""
        implementer: Work inside %{project_path}. Ship it.
        reviewer: Review %{project_key} at %{workspace}.
        inline: Inline prompt from system prompts.
      YAML

      registry = HQ::Registry.new(path: config_path)
      project = registry.projects.fetch(0)
      prompts = project.agent_templates.each_with_object({}) { |template, result| result[template.key] = template.prompt }

      assert(prompts["custom"] == "", "expected blank custom prompt from system prompts")
      assert(prompts["implementer"] == "Work inside #{File.join(dir, "demo")}. Ship it.",
             "expected implementer prompt to interpolate project_path")
      assert(prompts["reviewer"] == "Review demo at #{File.join(dir, "demo")}.",
             "expected reviewer prompt to load from the flat system prompt list")
      assert(prompts["inline"] == "Inline prompt from system prompts.",
             "expected inline prompt to load from flat system prompts")
      names = project.agent_templates.each_with_object({}) { |template, result| result[template.key] = template.name }
      assert(names["custom"] == "Custom", "expected template names to be derived from prompt keys")
    end
  end

  def assert_registry_loads_model_and_effort_defaults
    Dir.mktmpdir("hq-registry-model-test") do |dir|
      config_path = File.join(dir, "hq.yml")
      prompts_path = File.join(dir, "system_prompts.yml")

      File.write(config_path, <<~YAML)
        projects:
          - key: demo
            name: Demo
            group: Personal
            path: #{File.join(dir, "demo")}
            agent: codex
            model: gpt-5.1-codex-max
            reasoning_effort: HIGH
      YAML

      File.write(prompts_path, <<~YAML)
        custom: ""
        reviewer:
          name: Reviewer
          prompt: Review %{project_key} at %{workspace}.
          agent: claude
          model: sonnet
          reasoning_effort: xhigh
      YAML

      registry = HQ::Registry.new(path: config_path)
      project = registry.projects.fetch(0)
      custom = project.agent_templates.find { |template| template.key == "custom" }
      reviewer = project.agent_templates.find { |template| template.key == "reviewer" }

      assert(project.model == "gpt-5.1-codex-max", "expected project-level model to load")
      assert(project.reasoning_effort == "high", "expected project-level effort to normalize")
      assert(custom.model == "gpt-5.1-codex-max", "expected flat prompt template to inherit project model")
      assert(custom.reasoning_effort == "high", "expected flat prompt template to inherit project effort")
      assert(reviewer.agent == "claude", "expected structured prompt template to override harness")
      assert(reviewer.model == "sonnet", "expected structured prompt template to override model")
      assert(reviewer.reasoning_effort == "xhigh", "expected structured prompt template to override effort")
      assert(reviewer.prompt == "Review demo at #{File.join(dir, "demo")}.",
             "expected structured prompt template to interpolate prompt text")
    end
  end

  def assert_registry_persists_remote_servers
    Dir.mktmpdir("hq-registry-remote-server-test") do |dir|
      config_path = File.join(dir, "hq.yml")
      File.write(config_path, <<~YAML)
        projects: []
      YAML

      registry = HQ::Registry.new(path: config_path)
      server = registry.add_remote_server!(name: "tycho-peer", url: "http://127.0.0.1:7374/")
      persisted = YAML.safe_load(File.read(config_path), aliases: true)
      remote = persisted.fetch("remote_servers").fetch(0)

      assert(server.key == "tycho-peer", "expected remote server key to be derived from name")
      assert(remote["key"] == "tycho-peer", "expected remote server key to persist")
      assert(remote["name"] == "tycho-peer", "expected remote server name to persist")
      assert(remote["url"] == "http://127.0.0.1:7374", "expected remote server URL to be normalized")
      assert(!remote.key?("token"), "expected UI-added remote server tokens to stay out of hq.yml")
      assert(!remote.key?("token_encrypted"), "expected UI-added remote server tokens to stay out of hq.yml")
      assert(server.resolved_token.empty?, "expected UI-added remote server token to stay browser-local")
      assert(registry.remote_servers.length == 1, "expected registry to reload persisted remote server")

      removed = registry.remove_remote_server!("tycho-peer")
      persisted_after_remove = YAML.safe_load(File.read(config_path), aliases: true)
      assert(removed == "tycho-peer", "expected removed remote server key")
      assert(!persisted_after_remove.key?("remote_servers"), "expected empty remote_servers list to be removed")
      assert(registry.remote_servers.empty?, "expected registry remote server list to reload after removal")
    end
  end

  def assert_registry_ignores_hq_env_aliases
    Dir.mktmpdir("tycho-registry-env-test") do |dir|
      home_dir = File.join(dir, ".tycho")
      config_dir = File.join(home_dir, "config")
      hq_dir = File.join(dir, "hq")
      FileUtils.mkdir_p(config_dir)
      FileUtils.mkdir_p(hq_dir)
      tycho_config_path = File.join(config_dir, "hq.yml")
      hq_config_path = File.join(hq_dir, "hq.yml")

      File.write(tycho_config_path, <<~YAML)
        projects:
          - key: tycho
            name: Tycho Env
            path: #{File.join(dir, "tycho-project")}
      YAML
      File.write(File.join(config_dir, "system_prompts.yml"), "---\ncustom: \"\"\n")

      File.write(hq_config_path, <<~YAML)
        projects:
          - key: hq
            name: HQ Env
            path: #{File.join(dir, "hq-project")}
      YAML
      File.write(File.join(hq_dir, "system_prompts.yml"), "---\ncustom: \"\"\n")

      script = <<~RUBY
        $LOAD_PATH.unshift("lib")
        require "hq/registry"
        registry = HQ::Registry.new
        puts registry.path
        puts registry.projects.map(&:key).join(",")
      RUBY
      env = {
        "TYCHO_HOME" => home_dir,
        "HQ_CONFIG_PATH" => hq_config_path
      }
      out, err, status = Open3.capture3(env, RbConfig.ruby, "-e", script, chdir: File.expand_path("..", __dir__))
      assert(status.success?, "expected registry subprocess to succeed, err: #{err}")
      lines = out.lines.map(&:chomp)
      assert(lines[0] == tycho_config_path, "expected TYCHO_HOME config path, got #{lines[0].inspect}")
      assert(lines[1] == "tycho", "expected HQ_CONFIG_PATH to be ignored, got #{lines[1].inspect}")
    end
  end

  def assert_registry_uses_tycho_home_defaults
    Dir.mktmpdir("tycho-home-default-test") do |dir|
      home_dir = File.join(dir, ".tycho")
      config_dir = File.join(home_dir, "config")
      logs_dir = File.join(home_dir, "logs")
      FileUtils.mkdir_p(config_dir)
      File.write(File.join(config_dir, "hq.yml"), <<~YAML)
        projects:
          - key: user
            name: User Scoped
            path: #{File.join(dir, "workspace")}
      YAML
      File.write(File.join(config_dir, "system_prompts.yml"), "---\ncustom: \"\"\n")

      script = <<~RUBY
        $LOAD_PATH.unshift("lib")
        require "hq/registry"
        registry = HQ::Registry.new
        puts registry.path
        puts HQ::LOGS_DIR
        puts HQ::SCHEDULES_FILE
        puts HQ.default_hooks_path
        puts registry.projects.map(&:key).join(",")
      RUBY
      env = {
        "TYCHO_HOME" => home_dir
      }
      out, err, status = Open3.capture3(env, RbConfig.ruby, "-e", script, chdir: File.expand_path("..", __dir__))
      assert(status.success?, "expected TYCHO_HOME registry subprocess to succeed, err: #{err}")
      lines = out.lines.map(&:chomp)
      assert(lines[0] == File.join(config_dir, "hq.yml"), "expected user config path, got #{lines[0].inspect}")
      assert(lines[1] == logs_dir, "expected user logs path, got #{lines[1].inspect}")
      assert(lines[2] == File.join(config_dir, "schedules.yml"),
             "expected user schedule config path, got #{lines[2].inspect}")
      assert(lines[3] == File.join(config_dir, "hooks.yml"),
             "expected user hooks config path, got #{lines[3].inspect}")
      assert(File.exist?(File.join(config_dir, "schedules.yml")),
             "expected first run to create schedules.yml from example")
      assert(File.exist?(File.join(config_dir, "hooks.yml")),
             "expected first run to create hooks.yml from example")
      assert(File.read(File.join(config_dir, "hooks.yml")).include?("hooks: {}"),
             "expected copied hooks example to be inert by default")
      assert(lines[4] == "user", "expected user-scoped project, got #{lines[4].inspect}")
    end
  end

  def assert_registry_resolves_hidden_groups_and_project_overrides
    Dir.mktmpdir("hq-registry-hidden-test") do |dir|
      config_path = File.join(dir, "hq.yml")

      File.write(config_path, <<~YAML)
        groups:
          Cookpad:
            hidden: true
        projects:
          - key: web
            name: Web
            group: Cookpad
            path: #{File.join(dir, "web")}
          - key: web-charlie
            name: Web Charlie
            group: Cookpad
            path: #{File.join(dir, "web-charlie")}
            hidden: false
          - key: lab
            name: Lab
            group: Research
            path: #{File.join(dir, "lab")}
            hidden: true
      YAML

      registry = HQ::Registry.new(path: config_path)
      projects = registry.projects.each_with_object({}) { |project, by_key| by_key[project.key] = project }

      assert(registry.groups["Cookpad"].hidden == true, "expected group hidden config to load")
      assert(projects["web"].hidden == true, "expected project to inherit hidden group")
      assert(projects["web"].hidden_config.nil?, "expected inherited project hidden config to stay unset")
      assert(projects["web"].group_hidden == true, "expected inherited group hidden value")
      assert(projects["web-charlie"].hidden == false, "expected project hidden false to override group")
      assert(projects["web-charlie"].hidden_config == false, "expected explicit project visibility override")
      assert(projects["lab"].hidden == true, "expected project-level hidden to hide project")
      assert(projects["lab"].group_hidden.nil?, "expected missing group config to stay nil")
    end
  end

  def assert_registry_loads_custom_claude_harnesses
    Dir.mktmpdir("hq-registry-custom-harness-test") do |dir|
      config_path = File.join(dir, "hq.yml")
      File.write(config_path, <<~YAML)
        custom_harnesses:
          - key: claude-wrapper
            adapter: claude
            execution_command:
              - /usr/local/bin/claude-wrapper
              - --profile
              - demo
        projects:
          - key: web
            name: Web
            path: #{File.join(dir, "web")}
            agent: claude-wrapper
      YAML

      registry = HQ::Registry.new(path: config_path)
      harness = registry.custom_harnesses.first

      assert(harness.key == "claude-wrapper", "expected custom harness key")
      assert(harness.adapter == "claude", "expected custom harness to use Claude adapter")
      assert(harness.command_parts == ["/usr/local/bin/claude-wrapper", "--profile", "demo"],
             "expected custom harness command to preserve argv parts")
      assert(registry.projects.first.agent == "claude-wrapper",
             "expected project to accept custom harness key")
    end
  end

  def assert_custom_harness_resolves_executable_after_env_assignments
    Dir.mktmpdir("hq-harness-path-test") do |dir|
      bin_dir = File.join(dir, "bin")
      FileUtils.mkdir_p(bin_dir)
      executable = File.join(bin_dir, "wrapped-claude")
      File.write(executable, "#!/bin/sh\n")
      File.chmod(0o755, executable)

      harness = HQ::HarnessConfig.new(
        key: "wrapped",
        adapter: "claude",
        execution_command: ["env", "AWS_REGION=us-east-1", "wrapped-claude", "--profile", "demo"]
      )

      assert(harness.resolved_command_parts(path: bin_dir) ==
             ["env", "AWS_REGION=us-east-1", executable, "--profile", "demo"],
             "expected custom harness to resolve the command after env assignments")
    end
  end

  def assert_custom_harness_extracts_env_assignments_for_execution
    Dir.mktmpdir("hq-harness-env-test") do |dir|
      bin_dir = File.join(dir, "bin")
      FileUtils.mkdir_p(bin_dir)
      executable = File.join(bin_dir, "wrapped-claude")
      File.write(executable, "#!/bin/sh\n")
      File.chmod(0o755, executable)

      harness = HQ::HarnessConfig.new(
        key: "wrapped",
        adapter: "claude",
        execution_command: ["env", "AWS_REGION=us-east-1", "CLAUDE_CODE_USE_BEDROCK=1", "wrapped-claude", "--profile", "demo"]
      )
      execution = harness.resolved_execution(path: bin_dir)

      assert(execution[:command] == [executable, "--profile", "demo"],
             "expected executable command to omit env prefix and assignments")
      assert(execution[:env] == { "AWS_REGION" => "us-east-1", "CLAUDE_CODE_USE_BEDROCK" => "1" },
             "expected env prefix assignments to move into execution environment")
    end
  end

  def assert_registry_rejects_unsupported_custom_harness_adapters
    Dir.mktmpdir("hq-registry-custom-harness-error-test") do |dir|
      config_path = File.join(dir, "hq.yml")
      File.write(config_path, <<~YAML)
        custom_harnesses:
          - key: custom-codex
            adapter: codex
            execution_command: custom-codex
        projects:
          - key: web
            name: Web
            path: #{File.join(dir, "web")}
      YAML

      begin
        HQ::Registry.new(path: config_path)
      rescue HQ::ConfigError => e
        assert(e.message.include?("Unsupported adapter"), "expected unsupported adapter error")
        return
      end

      raise "expected unsupported custom harness adapter to fail"
    end
  end

  def assert_agent_store_prepends_project_tool_system_prompt
    Dir.mktmpdir("hq-registry-tool-prompt-test") do |dir|
      config_path = File.join(dir, "hq.yml")
      prompts_path = File.join(dir, "system_prompts.yml")
      old_agents_file = replace_constant(HQ, :AGENTS_FILE, File.join(dir, "agents.json"))

      File.write(config_path, <<~YAML)
        projects:
          - key: web
            name: Web
            path: #{File.join(dir, "web")}
          - key: docs
            name: Docs
            path: #{File.join(dir, "docs")}
      YAML
      File.write(prompts_path, <<~YAML)
        custom: Work on %{project_key}.
      YAML

      registry = HQ::Registry.new(path: config_path)
      web, docs = registry.projects

      agent = HQ::AgentStore.new(registry.projects).create_from_template(web, "custom")
      system_messages = agent.messages.select { |message| message.role == "system" }
      assert(system_messages.length == 2, "expected project context and template prompt to be separate system messages")
      assert(system_messages[0].content.include?("Project:"),
             "expected first system message to include project context")
      assert(system_messages[0].content.include?("- Path: #{File.join(dir, "web")}"),
             "expected first system message to include workspace path")
      assert(system_messages[1].content == "Work on web.",
             "expected second system message to be the selected template prompt")
      conversation_roles = agent.conversation_messages.map(&:role)
      assert(conversation_roles.first(2) == %w[system system],
             "expected chat conversation to render both leading system messages")

      project_agent = HQ::AgentStore.new(registry.projects).create_from_template(HQ::Project.new(web), "custom")
      project_context = project_agent.messages.select { |message| message.role == "system" }.first.content
      assert(project_context.include?("Project:"),
             "expected Project-created agents to include project context")

      docs_agent = HQ::AgentStore.new(registry.projects).create_from_template(docs, "custom")
      docs_system_messages = docs_agent.messages.select { |message| message.role == "system" }
      assert(docs_system_messages.length == 2,
             "expected every project to include project context and template prompt")
      assert(docs_system_messages.last.content == "Work on docs.",
             "expected final system prompt to be the template prompt")
    ensure
      replace_constant(HQ, :AGENTS_FILE, old_agents_file) if old_agents_file
    end
  end

  def assert_agent_store_backfills_project_tool_system_prompt
    old_agents_file = nil
    Dir.mktmpdir("hq-agent-context-backfill-test") do |dir|
      config_path = File.join(dir, "hq.yml")
      old_agents_file = replace_constant(HQ, :AGENTS_FILE, File.join(dir, "agents.json"))
      memory_path = File.join(dir, "web-agent-1.memory.jsonl")
      raw_log_path = File.join(dir, "web-agent-1.raw.log")
      created_at = "2026-05-02T08:34:06+07:00"

      File.write(config_path, <<~YAML)
        projects:
          - key: web
            name: Web
            path: #{File.join(dir, "web")}
      YAML
      agent_data = [{
        "key" => "web-agent-1",
        "name" => "Maintenance",
        "project_key" => "web",
        "template_key" => "custom",
        "workspace" => File.join(dir, "web"),
        "prompt" => "Maintenance for web",
        "created_at" => created_at,
        "log_path" => raw_log_path,
        "messages" => [
          { "role" => "system", "content" => "Maintenance for web", "created_at" => created_at }
        ]
      }]
      memory_event = {
        "type" => "system_prompt",
        "content" => "Maintenance for web",
        "created_at" => created_at,
        "pinned" => true
      }
      File.write(HQ::AGENTS_FILE, JSON.pretty_generate(agent_data))
      File.write(memory_path, "#{JSON.generate(memory_event)}\n")

      registry = HQ::Registry.new(path: config_path)
      agent = HQ::AgentStore.new(registry.projects).load.fetch(0)
      system_messages = agent.messages.select { |message| message.role == "system" }
      assert(system_messages.length == 2, "expected existing agent messages to gain project context")
      assert(system_messages.first.content.include?("Project:"),
             "expected backfilled project context")
      memory_events = File.readlines(memory_path, chomp: true).map { |line| JSON.parse(line) }
      assert(memory_events.first["content"].include?("Project:"),
             "expected existing memory file to be prepended with project context")
    ensure
      replace_constant(HQ, :AGENTS_FILE, old_agents_file) if old_agents_file
    end
  end

  def capture_stdout
    old_stdout = $stdout
    buffer = StringIO.new
    $stdout = buffer
    yield
    buffer.string
  ensure
    $stdout = old_stdout
  end

  def assert(condition, message)
    raise message unless condition
  end

  def replace_constant(scope, name, value)
    old_value = scope.const_get(name)
    scope.send(:remove_const, name)
    scope.const_set(name, value)
    old_value
  end
end

RegistryTest.run! if $PROGRAM_NAME == __FILE__
