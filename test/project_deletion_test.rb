# frozen_string_literal: true

require_relative "project_archiver_test"
require_relative "../lib/hq/domain/project_deletion"
require_relative "../lib/hq/remote_server"
require "timeout"

module ProjectDeletionTest
  module_function

  def run!
    [false, true].each do |remove_data|
      Dir.mktmpdir("tycho-delete-project") do |dir|
        ProjectArchiverTest.with_paths(dir) { verify_deletion(dir, remove_data:) }
      end
    end
    Dir.mktmpdir("tycho-delete-interrupted") do |dir|
      ProjectArchiverTest.with_paths(dir) { verify_interruption(dir) }
    end
    Dir.mktmpdir("tycho-delete-recovery") do |dir|
      ProjectArchiverTest.with_paths(dir) { verify_purge_retry(dir) }
    end
    Dir.mktmpdir("tycho-delete-routes") do |dir|
      ProjectArchiverTest.with_paths(dir) { verify_routes(dir) }
    end
    Dir.mktmpdir("tycho-delete-schedules") do |dir|
      ProjectArchiverTest.with_paths(dir) { verify_schedule_guard(dir) }
    end
    puts "project_deletion_test: ok"
  end

  def fixture(dir)
    workspace = File.join(dir, "workspace")
    FileUtils.mkdir_p(workspace)
    File.write(File.join(workspace, "keep.txt"), "source")
    config = File.join(dir, "hq.yml")
    File.write(config, { "projects" => [{ "key" => "demo", "name" => "Demo", "path" => workspace }] }.to_yaml)
    registry = HQ::Registry.new(path: config)
    project = HQ::Project.new(registry.projects.first)
    FileUtils.mkdir_p(project.log_dir)
    File.write(File.join(project.log_dir, "action.log"), "project log")
    agent = HQ::ManagedAgent.new(
      key: "demo-agent", name: "Demo agent", project_key: "demo", template_key: "custom",
      workspace:, prompt: "Prompt", log_path: File.join(HQ::AGENT_LOGS_DIR, "demo-agent.raw.log")
    )
    FileUtils.mkdir_p(HQ::AGENT_LOGS_DIR)
    File.write(agent.raw_log_path, "agent log")
    store = HQ::AgentStore.new(registry.projects)
    store.save([agent])
    [registry, store, workspace]
  end

  def verify_deletion(dir, remove_data:)
    registry, store, workspace = fixture(dir)
    jobs = HQ::ProjectDeletion.new(registry:)
    assert_raises { jobs.start("demo", confirmation: "wrong", remove_data:) }
    assert(jobs.status("demo").nil?, "invalid confirmation created job")
    result = jobs.start("demo", confirmation: "demo", remove_data:)
    assert(result["status"] == "queued", "request did not return queued receipt")
    result = wait(jobs)
    assert(result["status"] == "completed", "deletion failed: #{result.inspect}")
    assert(File.read(File.join(workspace, "keep.txt")) == "source", "workspace changed")
    assert(store.load.empty?, "active agent remains")
    assert(HQ::Registry.new(path: registry.path).projects.empty?, "project remains configured")
    archives = HQ::AgentArchiveStore.new.all
    assert(archives.length == (remove_data ? 0 : 1), "wrong agent archive count")
    project_logs = Dir.glob(File.join(HQ::PROJECT_ARCHIVE_DIR, "*", "action.log"))
    assert(project_logs.length == (remove_data ? 0 : 1), "wrong project log archive count")
    assert(jobs.start("demo", confirmation: "demo", remove_data:) == result, "duplicate request did not replay receipt")
    assert_raises { jobs.start("demo", confirmation: "demo", remove_data: !remove_data) }
    assert_raises { store.save([HQ::ManagedAgent.new(key: "stale-new", project_key: "demo", name: "Stale", workspace:)]) }
    # Explicit re-creation needs a new request identity; an old replay cannot delete it.
    original = YAML.safe_load_file(registry.archived_projects_path).fetch("projects").first
    HQ::FileStore.write_yaml(registry.path, { "projects" => [original] })
    assert(jobs.start("demo", confirmation: "demo", remove_data:) == result, "old receipt deleted re-created project")
    assert(HQ::Registry.new(path: registry.path).projects.length == 1, "old receipt removed new configuration")
    jobs.start("demo", confirmation: "demo", remove_data:, request_id: "next-generation")
    assert(wait(jobs)["status"] == "completed", "new deletion generation failed")
  end

  def verify_interruption(dir)
    registry, store, = fixture(dir)
    jobs = HQ::ProjectDeletion.new(registry:)
    root = File.join(File.dirname(HQ::AGENTS_FILE), "project_deletions")
    path = File.join(root, "#{Digest::SHA256.hexdigest("demo")}.json")
    HQ::FileStore.write_json(path, { "project_key" => "demo", "request_id" => "default", "status" => "running", "phase" => "archive", "remove_data" => false,
                                    "workspace" => registry.projects.first.path })
    assert(jobs.status("demo")["status"] == "failed", "interrupted job replayed")
    assert(store.load.length == 1, "status archived agents")
    assert_raises { store.create_from_template(HQ::Project.new(registry.projects.first), "custom") }
    result = jobs.start("demo", confirmation: "demo", remove_data: false)
    assert(result["status"] == "queued", "explicit retry was not queued")
    assert(wait(jobs)["status"] == "completed", "explicit retry failed")
  end

  def verify_purge_retry(dir)
    registry, store, workspace = fixture(dir)
    # A matching symlink must fail closed and leave its target unchanged.
    archive_root = HQ::AGENT_ARCHIVE_DIR
    FileUtils.mkdir_p(archive_root)
    manifest = File.join(workspace, "agent_manifest.json")
    File.write(manifest, JSON.generate("project_key" => "demo"))
    link = File.join(archive_root, "unsafe")
    File.symlink(workspace, link)
    jobs = HQ::ProjectDeletion.new(registry:)
    jobs.start("demo", confirmation: "demo", remove_data: true)
    failed = wait(jobs)
    assert(failed["status"] == "failed" && failed["phase"] == "archived", "unsafe purge did not fail after archive")
    assert(File.read(File.join(workspace, "keep.txt")) == "source", "symlink target changed")
    assert(store.load.empty?, "archive phase did not commit")
    assert(HQ::Registry.new(path: registry.path).projects.length == 1, "failure lost the project recovery entry")
    File.unlink(link)
    jobs.start("demo", confirmation: "demo", remove_data: true)
    assert(wait(jobs)["status"] == "completed", "purge retry did not resume archived phase")
    assert(File.exist?(manifest), "retry deleted workspace manifest")
  end

  def verify_routes(dir)
    registry, = fixture(dir)
    service = HQ::RemoteService.new(registry:)
    server = HQ::RemoteServer.new
    begin
      server.send(:route, service, "POST", "/projects/demo/deletion", { "confirmation" => "wrong", "request_id" => "http-test" })
      raise "invalid confirmation was accepted"
    rescue HQ::RemoteServer::Error => e
      assert(e.status == 409, "wrong error status")
    end
    response = server.send(:route, service, "POST", "/projects/demo/deletion", { "confirmation" => "demo", "request_id" => "http-test" })
    assert(response[:status] == 202 && response[:body][:deletion]["request_id"] == "http-test", "HTTP request did not return a durable accepted receipt")
    jobs = HQ::ProjectDeletion.new(registry:)
    wait(jobs)
    response = server.send(:route, service, "GET", "/projects/demo/deletion", {})
    assert(response[:body][:deletion]["status"] == "completed", "HTTP status did not survive new job service")
    assert(service.projects.empty?, "service did not reconcile removed project")
  end

  def verify_schedule_guard(dir)
    registry, store, = fixture(dir)
    File.write(HQ::SCHEDULES_FILE, { "schedules" => [{ "key" => "owned", "cron" => "0 9 * * *", "target" => {
      "type" => "agent", "project_key" => "demo", "message" => "Synthetic" } }] }.to_yaml)
    jobs = HQ::ProjectDeletion.new(registry:)
    assert_raises { jobs.start("demo", confirmation: "demo") }
    assert(jobs.status("demo").nil?, "schedule rejection created a deletion job")
    assert(store.load.length == 1, "schedule rejection archived agents")
    assert(HQ::Registry.new(path: registry.path).projects.length == 1, "schedule rejection removed project")
  end

  def wait(jobs)
    Timeout.timeout(10) do
      loop do
        result = jobs.status("demo")
        return result unless %w[queued running].include?(result["status"])
        sleep 0.01
      end
    end
  end

  def assert_raises
    yield
    raise "expected ArgumentError"
  rescue ArgumentError
    true
  end

  def assert(value, message)
    raise message unless value
  end
end

ProjectDeletionTest.run! if $PROGRAM_NAME == __FILE__
