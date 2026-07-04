# frozen_string_literal: true

require "fileutils"
require "tmpdir"

TEST_LOGS_ROOT = File.expand_path("logs/app_agent_persistence", __dir__)
ENV["TYCHO_LOGS_ROOT"] = TEST_LOGS_ROOT
FileUtils.rm_rf(TEST_LOGS_ROOT)
FileUtils.mkdir_p(TEST_LOGS_ROOT)

require_relative "../lib/hq/app"
require_relative "../lib/hq/remote_server"

module AppAgentPersistenceTest
  module_function

  def run!
    assert_tui_refresh_preserves_agent_created_from_remote_ui
    assert_tui_refresh_does_not_resurrect_agent_archived_from_remote_ui
    assert_tui_hides_configured_projects_without_dropping_persisted_agents
    puts "app_agent_persistence_test: ok"
  ensure
    FileUtils.rm_rf(TEST_LOGS_ROOT)
  end

  def assert_tui_refresh_preserves_agent_created_from_remote_ui
    with_temp_agent_store do |dir|
      old_config_path = ENV["TYCHO_CONFIG_PATH"]
      old_system_prompts_path = ENV["TYCHO_SYSTEM_PROMPTS_PATH"]
      workspace = File.join(dir, "workspace")
      FileUtils.mkdir_p(workspace)
      config_path, prompts_path = write_config(dir, workspace)
      ENV["TYCHO_CONFIG_PATH"] = config_path
      ENV["TYCHO_SYSTEM_PROMPTS_PATH"] = prompts_path

      app = HQ::App.new
      create_tui_agent(app, name: "TUI Agent", prompt: "Created in the TUI.")
      registry = HQ::Registry.new(path: config_path, system_prompts_path: prompts_path)
      remote_agent = HQ::RemoteService.new(registry: registry).create_agent(
        "project_key" => "web",
        "template_key" => "custom",
        "name" => "Remote UI Agent",
        "prompt" => "Created in Remote UI.",
        "agent" => "codex"
      )

      finish_tui_refresh(app)

      tui_names = app.instance_variable_get(:@agents).map(&:name)
      persisted_names = HQ::AgentStore.new(registry.projects).load.map(&:name)
      assert(tui_names.include?(remote_agent[:name]),
             "expected TUI refresh to show agent created from Remote UI")
      assert(persisted_names.include?("TUI Agent"), "expected TUI-created agent to remain after refresh")
      assert(persisted_names.include?(remote_agent[:name]),
             "expected TUI refresh to preserve agent created from Remote UI")
    ensure
      ENV["TYCHO_CONFIG_PATH"] = old_config_path if defined?(old_config_path)
      if defined?(old_system_prompts_path) && old_system_prompts_path
        ENV["TYCHO_SYSTEM_PROMPTS_PATH"] = old_system_prompts_path
      else
        ENV.delete("TYCHO_SYSTEM_PROMPTS_PATH")
      end
    end
  end

  def assert_tui_refresh_does_not_resurrect_agent_archived_from_remote_ui
    with_temp_agent_store do |dir|
      old_config_path = ENV["TYCHO_CONFIG_PATH"]
      old_system_prompts_path = ENV["TYCHO_SYSTEM_PROMPTS_PATH"]
      workspace = File.join(dir, "workspace")
      FileUtils.mkdir_p(workspace)
      config_path, prompts_path = write_config(dir, workspace)
      ENV["TYCHO_CONFIG_PATH"] = config_path
      ENV["TYCHO_SYSTEM_PROMPTS_PATH"] = prompts_path

      app = HQ::App.new
      create_tui_agent(app, name: "TUI Agent", prompt: "Created in the TUI.")
      target = app.instance_variable_get(:@agents).find { |agent| agent.name == "TUI Agent" }
      raise "expected TUI-created agent" unless target

      registry = HQ::Registry.new(path: config_path, system_prompts_path: prompts_path)
      HQ::RemoteService.new(registry: registry).archive_agent(target.key)

      finish_tui_refresh(app)

      tui_keys = app.instance_variable_get(:@agents).map(&:key)
      persisted_keys = HQ::AgentStore.new(registry.projects).load.map(&:key)
      assert(!tui_keys.include?(target.key),
             "expected TUI refresh to drop agent archived from Remote UI")
      assert(!persisted_keys.include?(target.key),
             "expected TUI save to avoid resurrecting Remote-archived agent")
    ensure
      ENV["TYCHO_CONFIG_PATH"] = old_config_path if defined?(old_config_path)
      if defined?(old_system_prompts_path) && old_system_prompts_path
        ENV["TYCHO_SYSTEM_PROMPTS_PATH"] = old_system_prompts_path
      else
        ENV.delete("TYCHO_SYSTEM_PROMPTS_PATH")
      end
    end
  end

  def assert_tui_hides_configured_projects_without_dropping_persisted_agents
    with_temp_agent_store do |dir|
      old_config_path = ENV["TYCHO_CONFIG_PATH"]
      old_system_prompts_path = ENV["TYCHO_SYSTEM_PROMPTS_PATH"]
      visible_workspace = File.join(dir, "visible")
      hidden_workspace = File.join(dir, "hidden")
      FileUtils.mkdir_p(visible_workspace)
      FileUtils.mkdir_p(hidden_workspace)
      config_path = File.join(dir, "hq.yml")
      prompts_path = File.join(dir, "system_prompts.yml")
      File.write(config_path, <<~YAML)
        groups:
          Hidden:
            hidden: true
        projects:
          - key: web
            name: Web
            path: #{visible_workspace}
          - key: secret
            name: Secret
            group: Hidden
            path: #{hidden_workspace}
      YAML
      File.write(prompts_path, <<~YAML)
        custom: Default prompt for %{project_key}.
      YAML
      ENV["TYCHO_CONFIG_PATH"] = config_path
      ENV["TYCHO_SYSTEM_PROMPTS_PATH"] = prompts_path
      registry = HQ::Registry.new(path: config_path, system_prompts_path: prompts_path)
      hidden_agent = HQ::ManagedAgent.new(
        key: "secret-agent-1",
        name: "Secret Agent",
        project_key: "secret",
        template_key: "custom",
        workspace: hidden_workspace,
        prompt: "Stay hidden.",
        agent: "codex"
      )
      HQ::AgentStore.new(registry.projects).save([hidden_agent])

      app = HQ::App.new
      assert(app.instance_variable_get(:@projects).map(&:key) == ["web"],
             "expected TUI project list to omit hidden projects")
      assert(app.instance_variable_get(:@agents).empty?,
             "expected TUI agent list to omit agents for hidden projects")

      create_tui_agent(app, name: "Visible Agent", prompt: "Created in the TUI.")
      finish_tui_refresh(app)

      persisted_names = HQ::AgentStore.new(registry.projects).load.map(&:name)
      assert(persisted_names.include?("Secret Agent"),
             "expected TUI save to preserve hidden project agents")
      assert(persisted_names.include?("Visible Agent"),
             "expected TUI save to persist visible project agents")
      assert(!app.instance_variable_get(:@agents).map(&:name).include?("Secret Agent"),
             "expected hidden agent to stay out of the TUI after refresh")
    ensure
      ENV["TYCHO_CONFIG_PATH"] = old_config_path if defined?(old_config_path)
      if defined?(old_system_prompts_path) && old_system_prompts_path
        ENV["TYCHO_SYSTEM_PROMPTS_PATH"] = old_system_prompts_path
      else
        ENV.delete("TYCHO_SYSTEM_PROMPTS_PATH")
      end
    end
  end

  def create_tui_agent(app, name:, prompt:)
    projects = app.instance_variable_get(:@projects)
    project = projects.find { |candidate| candidate.key == "web" }
    app.instance_variable_set(:@screen, :projects)
    app.instance_variable_get(:@selected)[:projects] = projects.index(project) || 0
    app.send(:open_agent_editor_for_selected_project)

    editor = app.instance_variable_get(:@agent_editor)
    editor.name_input.value = name
    editor.prompt_input.value = prompt
    editor.instance_variable_set(:@field_index, editor.create_button_index)
    app.send(:save_agent_editor)
  end

  def finish_tui_refresh(app)
    app.send(:begin_refresh!)
    app.instance_variable_get(:@progress_threads).each(&:join)
    progress = app.instance_variable_get(:@progress)
    progress.instance_variable_set(:@percent_shown, 1.0)
    app.send(:handle_progress_tick)
  end

  def with_temp_agent_store
    Dir.mktmpdir("hq-app-agent-persistence-test") do |dir|
      old_agents_file = replace_constant(HQ, :AGENTS_FILE, File.join(dir, "managed_agents.json"))
      old_logs_dir = replace_constant(HQ, :AGENT_LOGS_DIR, File.join(dir, "agents"))
      old_archive_dir = replace_constant(HQ, :AGENT_ARCHIVE_DIR, File.join(dir, "agents", "archive"))
      old_project_logs_dir = replace_constant(HQ, :PROJECT_LOGS_DIR, File.join(dir, "projects"))
      old_project_archive_dir = replace_constant(HQ, :PROJECT_ARCHIVE_DIR, File.join(dir, "projects", "archived"))

      FileUtils.mkdir_p(HQ::AGENT_LOGS_DIR)
      FileUtils.mkdir_p(HQ::AGENT_ARCHIVE_DIR)
      FileUtils.mkdir_p(HQ::PROJECT_LOGS_DIR)
      FileUtils.mkdir_p(HQ::PROJECT_ARCHIVE_DIR)
      yield dir
    ensure
      replace_constant(HQ, :AGENTS_FILE, old_agents_file) if old_agents_file
      replace_constant(HQ, :AGENT_LOGS_DIR, old_logs_dir) if old_logs_dir
      replace_constant(HQ, :AGENT_ARCHIVE_DIR, old_archive_dir) if old_archive_dir
      replace_constant(HQ, :PROJECT_LOGS_DIR, old_project_logs_dir) if old_project_logs_dir
      replace_constant(HQ, :PROJECT_ARCHIVE_DIR, old_project_archive_dir) if old_project_archive_dir
    end
  end

  def write_config(dir, workspace)
    config_path = File.join(dir, "hq.yml")
    prompts_path = File.join(dir, "system_prompts.yml")
    File.write(config_path, <<~YAML)
      projects:
        - key: web
          name: Web
          path: #{workspace}
    YAML
    File.write(prompts_path, <<~YAML)
      custom: Default prompt for %{project_key}.
    YAML
    [config_path, prompts_path]
  end

  def assert(condition, message)
    raise message unless condition
  end

  def replace_constant(mod, name, value)
    old = mod.const_get(name)
    mod.send(:remove_const, name)
    mod.const_set(name, value)
    old
  end
end

AppAgentPersistenceTest.run! if $PROGRAM_NAME == __FILE__
