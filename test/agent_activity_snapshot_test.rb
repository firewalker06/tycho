# frozen_string_literal: true

require_relative "../lib/hq/domain/agent_activity_snapshot"

module AgentActivitySnapshotTest
  module_function

  FakeAgent = Struct.new(
    :key, :name, :project_key, :template_key, :schedule_key, :agent, :model, :reasoning_effort, :status,
    :unread, :run_count, :created_at, :started_at, :finished_at, :last_activity_at, :last_exit_code,
    :last_result_label, :last_summary, :delegation_parent,
    keyword_init: true
  ) do
    def display_name = name
    def scheduled? = !schedule_key.nil?
    def unread? = unread
    def archived? = false
    def archived_at = nil
  end

  def run!
    snapshot = HQ::AgentActivitySnapshot.new
    assert(snapshot.snapshot[:ready] == false, "expected a new activity snapshot to be unready")

    agent = fake_agent(status: "running", unread: false)
    assert(snapshot.replace!([agent]), "expected the first replacement to publish activity")
    running = snapshot.snapshot
    assert(running[:revision] == 1, "expected the first activity revision")
    assert(running.dig(:agents, 0, :running), "expected running activity")
    assert(!snapshot.replace!([agent]), "expected identical activity not to advance the revision")

    finished = fake_agent(status: "awaiting-input", unread: true)
    assert(snapshot.upsert!(finished), "expected changed activity to publish")
    awaiting = snapshot.snapshot
    assert(awaiting[:revision] == 2 && awaiting[:unread_count] == 1,
           "expected unread activity to advance the revision")
    assert(awaiting.dig(:agents, 0, :awaiting_input), "expected inquiry activity")
    assert(snapshot.remove!(agent.key), "expected activity removal")
    assert(snapshot.snapshot[:agents].empty?, "expected the removed agent to leave the snapshot")

    parent = fake_agent(key: "parent-agent", status: "running", unread: false)
    child = fake_agent(
      key: "child-agent",
      status: "running",
      unread: false,
      delegation_parent: {
        "server_id" => "local-server",
        "agent_key" => parent.key,
        "name" => parent.name,
        "project_key" => parent.project_key
      }
    )
    snapshot.replace!([parent])
    snapshot.upsert!(child)
    delegated = snapshot.snapshot.fetch(:agents).to_h { |item| [item.fetch(:key), item] }
    assert(delegated.dig(parent.key, :delegation, :children, 0, :agent_key) == child.key,
           "expected activity to add a new child to the cached parent topology")
    assert(delegated.dig(child.key, :delegation, :parent, :agent_key) == parent.key,
           "expected activity to expose the child's parent topology")

    assert(snapshot.remove!(child.key), "expected delegated activity removal")
    assert(snapshot.snapshot.dig(:agents, 0, :delegation, :children).empty?,
           "expected removing a child to refresh the cached parent topology")
    puts "agent_activity_snapshot_test: ok"
  end

  def fake_agent(status:, unread:, key: "agent-1", delegation_parent: nil)
    now = Time.now
    FakeAgent.new(
      key: key,
      name: "Agent one",
      project_key: "web",
      template_key: "custom",
      agent: "codex",
      model: "gpt-5",
      reasoning_effort: "medium",
      status: status,
      unread: unread,
      run_count: 1,
      created_at: now,
      started_at: now,
      finished_at: status == "running" ? nil : now,
      last_activity_at: now,
      last_exit_code: status == "running" ? nil : 0,
      last_result_label: status == "awaiting-input" ? "awaiting input" : nil,
      last_summary: "Waiting",
      delegation_parent: delegation_parent
    )
  end

  def assert(condition, message)
    raise message unless condition
  end
end

AgentActivitySnapshotTest.run! if $PROGRAM_NAME == __FILE__
