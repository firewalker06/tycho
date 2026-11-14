# frozen_string_literal: true

require "tmpdir"
require_relative "../lib/hq/domain/agent_focus"

FocusTestAgent = Struct.new(:focus_path, :attachments, :archived, keyword_init: true) do
  def archived? = archived
end

def assert(value, message)
  raise message unless value
end

def rejects(error = HQ::AgentFocus::Error)
  yield
  raise "expected #{error}"
rescue error
  nil
end

Dir.mktmpdir("focus-test") do |dir|
  agent = FocusTestAgent.new(focus_path: File.join(dir, "focus.json"), attachments: [{ "type" => "file", "path" => "report.md" }], archived: false)
  store = HQ::AgentFocus.new(agent)
  sections = [{ "title" => "Ready", "icon" => "todo_done", "items" => [{ "title" => "Review", "attachments" => [{ "type" => "file", "title" => "Report", "path" => "report.md" }] }] }]
  first = store.replace(sections, expected_revision: 0)
  assert(first["revision"] == 1, "revision must advance")
  assert(HQ::AgentFocus.new(agent).read == first, "saved data must survive reload")
  assert(store.replace(sections, expected_revision: 0) == first, "lost-response retry must not duplicate updates")
  rejects(HQ::AgentFocus::Conflict) { store.replace([], expected_revision: 0) }
  rejects { store.replace([], expected_revision: "1") }
  rejects { store.replace([{ "title" => "Ready", "items" => "bad" }], expected_revision: 1) }
  rejects { store.replace([{ "title" => "Ready", "icon" => "<svg>", "items" => [] }], expected_revision: 1) }
  ["javascript:alert(1)", "file:///etc/passwd", "https://user:secret@example.com"].each do |url|
    rejects { store.replace([{ "title" => "Ready", "items" => [{ "title" => "Review", "attachments" => [{ "type" => "link", "title" => "Bad", "url" => url }] }] }], expected_revision: 1) }
  end
  rejects { store.replace([{ "title" => "Ready", "items" => [{ "title" => "Review", "attachments" => [{ "type" => "file", "title" => "Bad", "path" => "/etc/passwd" }] }] }], expected_revision: 1) }
  rejects { store.replace([{ "title" => "x" * 2001, "items" => [] }], expected_revision: 1) }
  rejects { store.replace(Array.new(21) { { "title" => "Ready", "items" => [] } }, expected_revision: 1) }
  rejects { store.replace([{ "title" => "Ready", "items" => Array.new(101) { { "title" => "Item" } } }], expected_revision: 1) }
  assert(store.read == first, "invalid updates must preserve prior state")
  outcomes = 2.times.map do |index|
    Thread.new do
      HQ::AgentFocus.new(agent).replace([{ "title" => "Writer #{index}", "items" => [] }], expected_revision: 1)
      :saved
    rescue HQ::AgentFocus::Conflict
      :conflict
    end
  end.map(&:value)
  assert(outcomes.sort == %i[conflict saved], "concurrent writers must not lose updates")
  agent.archived = true
  rejects { store.replace([], expected_revision: 2) }
  agent.archived = false
  File.write(agent.focus_path, "broken")
  rejects { store.replace([], expected_revision: 2) }
  assert(File.read(agent.focus_path) == "broken", "corrupt saved data must not be overwritten")
end
puts "agent_focus_test: ok"
