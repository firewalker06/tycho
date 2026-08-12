# frozen_string_literal: true

require "json"
require "tmpdir"

require_relative "../lib/hq/domain/delegation_coordinator"
require_relative "../lib/hq/domain/managed_agent"

class DelegationTest
  FakeRun = Struct.new(:run_id, :session_id, keyword_init: true)

  class FakeAgent
    attr_reader :key, :name, :project_key, :workspace, :last_run, :session_id, :structured_result
    attr_accessor :run_count

    def initialize(key:, root:, workspace: nil, status: "success", summary: "Done", running: false)
      @key = key
      @name = key.tr("-", " ")
      @project_key = "demo"
      @workspace = workspace || File.join(root, "workspace")
      @memory_path = File.join(root, "#{key}.memory.jsonl")
      @last_run = FakeRun.new(run_id: "run-#{key}", session_id: "session-#{key}")
      @session_id = @last_run.session_id
      @run_count = 1
      @status = status
      @summary = summary
      @running = running
      @structured_result = { "status" => status, "attachments" => [] }
      @delegation_parent = nil
    end

    def display_name = @name
    def memory_path = @memory_path
    def effective_status = @status
    def last_summary = @summary
    def latest_inquiry = @status == "input_required" ? { "message" => "Choose", "fields" => [] } : nil
    def running? = @running
    def archived? = false
    def archive_path = nil

    def start!
      @running = true
      true
    end

    def stop!
      @running = false
    end

    def associate_parent!(reference)
      raise ArgumentError, "conflict" if @delegation_parent && @delegation_parent != reference

      @delegation_parent ||= reference
    end
  end

  def self.run!
    Dir.mktmpdir("tycho-delegation") do |dir|
      identity = { "id" => "server-1", "name" => "Test host" }
      store_path = File.join(dir, "delegations.json")
      store = HQ::DelegationStore.new(path: store_path, server_identity: identity)
      archive_store = HQ::AgentArchiveStore.new(root: File.join(dir, "archive"))
      coordinator = HQ::DelegationCoordinator.new(delegation_store: store, archive_store: archive_store)
      parent = FakeAgent.new(key: "parent", root: dir)
      child = FakeAgent.new(key: "child", root: dir)
      sibling = FakeAgent.new(key: "sibling", root: dir, running: true)
      agents = [parent, child, sibling]

      relation, created = coordinator.attach!(agents:, child:, parent_key: parent.key)
      assert(created && relation.dig("parent", "run_id") == "run-parent", "expected origin run identity")
      repeated, repeated_created = coordinator.attach!(agents:, child:, parent_key: parent.key)
      assert(!repeated_created && repeated["id"] == relation["id"], "expected idempotent same-parent attachment")
      assert_raises("self-parent") { coordinator.attach!(agents:, child: parent, parent_key: parent.key) }
      assert_raises("unknown parent") { coordinator.attach!(agents:, child:, parent_key: "missing") }
      assert_raises("cross-server") do
        coordinator.attach!(agents:, child: FakeAgent.new(key: "remote-child", root: dir),
                            parent_key: parent.key, parent_server_id: "server-2")
      end

      other_parent = FakeAgent.new(key: "other-parent", root: dir)
      agents << other_parent
      assert_raises("conflicting re-parent") do
        coordinator.attach!(agents:, child:, parent_key: other_parent.key)
      end

      grandchild = FakeAgent.new(key: "grandchild", root: dir)
      agents << grandchild
      coordinator.attach!(agents:, child: grandchild, parent_key: child.key)
      assert_raises("cycle") { coordinator.attach!(agents:, child: parent, parent_key: grandchild.key) }

      coordinator.process!(agents)
      report = store.reports.find { |item| item["child_run_id"] == "run-child" }
      assert(report && report["delivered_at"], "expected durable callback delivery")
      assert(report["resume_state"] == "workspace_busy", "expected same-workspace resume deferral")
      assert(!parent.running?, "expected stopped parent to remain stopped while sibling runs")

      sibling.stop!
      coordinator.process!(agents)
      report = HQ::DelegationStore.new(path: store_path, server_identity: identity).reports
        .find { |item| item["child_run_id"] == "run-child" }
      assert(parent.running? && report["resume_state"] == "resumed", "expected one safe automatic parent resume")
      events = File.readlines(parent.memory_path).map { |line| JSON.parse(line) }
      callback_events = events.select { |event| event.dig("metadata", "delegation_callback") }
      assert(callback_events.length == 1, "expected callback message deduplication")
      assert(events.any? { |event| event["type"] == "delegation_event" }, "expected contextual creation event")

      %w[failed blocked input_required].each do |status|
        terminal = FakeAgent.new(key: "child-#{status}", root: dir, status: status, workspace: File.join(dir, status))
        agents << terminal
        coordinator.attach!(agents:, child: terminal, parent_key: parent.key)
        store.record_report!(child: terminal)
        stored = store.reports.find { |item| item["child_run_id"] == terminal.last_run.run_id }
        assert(stored && stored["status"] == status, "expected #{status} report")
        assert(stored["inquiry"], "expected inquiry payload") if status == "input_required"
      end

      reloaded = HQ::DelegationStore.new(path: store_path, server_identity: identity)
      assert(reloaded.relation_for_child("child")["id"] == relation["id"], "expected restart persistence")

      archived_parent = HQ::ManagedAgent.new(
        key: "archived-parent",
        name: "Archived parent",
        project_key: "demo",
        template_key: "default",
        workspace: File.join(dir, "archived-workspace"),
        prompt: "Review children",
        log_path: File.join(dir, "archived-parent.raw.log")
      )
      archived_child = FakeAgent.new(key: "archived-child", root: dir,
                                     workspace: File.join(dir, "archived-child-workspace"))
      coordinator.attach!(agents: [archived_parent, archived_child], child: archived_child,
                          parent_key: archived_parent.key)
      archive_path = archived_parent.archive_logs!(File.join(dir, "archive"))
      coordinator.process!([archived_child])
      archived_events = File.readlines(File.join(archive_path, File.basename(archived_parent.memory_path)))
        .map { |line| JSON.parse(line) }
      assert(archived_events.any? { |event| event.dig("metadata", "delegation_callback") },
             "expected callback delivery after parent archival")
      archived_report = store.reports.find { |item| item["child_run_id"] == archived_child.last_run.run_id }
      assert(archived_report["resume_state"] == "parent_archived", "expected archived parent to remain stopped")
    end
    puts "delegation_test: ok"
  end

  def self.assert(condition, message)
    raise message unless condition
  end

  def self.assert_raises(message)
    yield
    raise "expected #{message} rejection"
  rescue HQ::DelegationStore::Error
    true
  end
end

DelegationTest.run! if $PROGRAM_NAME == __FILE__
