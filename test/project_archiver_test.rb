# frozen_string_literal: true

require "fileutils"
require "tmpdir"
require "yaml"

require_relative "../lib/hq/domain/project_archiver"

module ProjectArchiverTest
  module_function

  NoopScheduler = Struct.new(:unused) do
    def reconcile_archived_agent!(*)
      false
    end
  end

  FailingAgentStore = Struct.new(:delegate, :message) do
    def load
      delegate.load
    end

    def archive_agents!(*)
      raise message
    end
  end

  def run!
    Dir.mktmpdir("hq-project-archiver-test") do |dir|
      with_paths(dir) { assert_failure_restores_state(dir) }
    end
    puts "project_archiver_test: ok"
  end

  def assert_failure_restores_state(dir)
    workspace = File.join(dir, "workspace")
    FileUtils.mkdir_p(workspace)
    config_path = File.join(dir, "hq.yml")
    prompts_path = File.join(dir, "system_prompts.yml")
    File.write(config_path, "projects:\n  - key: demo\n    name: Demo\n    path: #{workspace}\n")
    File.write(prompts_path, "custom: Prompt\n")
    registry = HQ::Registry.new(path: config_path, system_prompts_path: prompts_path)
    project = HQ::Project.new(registry.projects.fetch(0))
    agent = HQ::ManagedAgent.new(
      key: "demo-agent", name: "Demo Agent", project_key: "demo", template_key: "custom",
      workspace: workspace, prompt: "Prompt", log_path: File.join(HQ::AGENT_LOGS_DIR, "demo-agent.raw.log")
    )
    FileUtils.mkdir_p(project.log_dir)
    FileUtils.mkdir_p(HQ::AGENT_LOGS_DIR)
    File.write(File.join(project.log_dir, "project.log"), "project")
    File.write(agent.raw_log_path, "agent")
    store = HQ::AgentStore.new(registry.projects)
    store.save([agent])
    failing_store = FailingAgentStore.new(store, "agent save failed")
    archiver = HQ::ProjectArchiver.new(registry: registry, agent_store: failing_store, scheduler: NoopScheduler.new)

    begin
      archiver.archive("demo")
      raise "expected archive failure"
    rescue RuntimeError => e
      raise unless e.message == "agent save failed"
    end

    assert(File.exist?(File.join(project.log_dir, "project.log")), "expected project logs to roll back")
    assert(File.exist?(agent.raw_log_path), "expected agent logs to roll back")
    assert(store.load.map(&:key) == ["demo-agent"], "expected active agents to roll back")
    active = YAML.safe_load_file(config_path).fetch("projects")
    assert(active.any? { |entry| entry["key"] == "demo" }, "expected active project config to roll back")
    archived_path = File.join(dir, "hq.archived.yml")
    assert(!File.exist?(archived_path), "expected archived project config to roll back")
  end

  def with_paths(dir)
    logs = File.join(dir, "logs")
    replacements = {
      AGENTS_FILE: File.join(logs, "managed_agents.json"),
      AGENT_LOGS_DIR: File.join(logs, "agents"),
      AGENT_ARCHIVE_DIR: File.join(logs, "agents", "archive"),
      PROJECT_LOGS_DIR: File.join(logs, "projects"),
      PROJECT_ARCHIVE_DIR: File.join(logs, "projects", "archived"),
      SCHEDULES_FILE: File.join(dir, "schedules.yml"),
      SCHEDULES_STATE_FILE: File.join(logs, "schedules.json")
    }
    old = replacements.to_h { |name, value| [name, replace_constant(name, value)] }
    yield
  ensure
    old&.each { |name, value| replace_constant(name, value) }
  end

  def replace_constant(name, value)
    old = HQ.const_get(name)
    HQ.send(:remove_const, name)
    HQ.const_set(name, value)
    old
  end

  def assert(condition, message)
    raise message unless condition
  end
end

ProjectArchiverTest.run! if $PROGRAM_NAME == __FILE__
