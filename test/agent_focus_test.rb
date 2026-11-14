# frozen_string_literal: true

require "tmpdir"
require "open3"
require_relative "support/test_environment"
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

Dir.mktmpdir("tycho-focus-cli-") do |dir|
  workspace = File.join(dir, "workspace")
  FileUtils.mkdir_p(workspace)
  config = File.join(dir, "hq.yml")
  prompts = File.join(dir, "system_prompts.yml")
  input = File.join(dir, "focus.json")
  File.write(config, "projects:\n  - key: fixture\n    name: Focus fixture\n    path: #{workspace}\n    agent: codex\n")
  File.write(prompts, "custom: Synthetic only\n")
  File.write(input, JSON.generate([{title: "CLI smoke", icon: "note", items: [{title: "Saved through CLI"}]}]))
  env = TestEnvironment.command_env(dir).merge("TYCHO_CONFIG_PATH" => config, "TYCHO_SYSTEM_PROMPTS_PATH" => prompts)
  command = lambda do |*args, stdin: ""|
    out, err, status = Open3.capture3(env, "bundle", "exec", "bin/tycho", *args, stdin_data: stdin)
    raise "CLI failed: #{err} #{out}" unless status.success?
    JSON.parse(out)
  end
  created = command.call("agent", "create", "fixture", "Synthetic only", "--name", "Focus fixture", "--json")
  key = created.fetch("key")
  empty = command.call("agent", "focus", key, "--json")
  raise "bad initial revision" unless empty["revision"] == 0
  saved = command.call("agent", "focus", key, "--file", input, "--revision", "0", "--json")
  raise "bad saved revision" unless saved["revision"] == 1
  cleared = command.call("agent", "focus", key, "--file", "-", "--revision", "1", stdin: "[]")
  raise "stdin clear failed" unless cleared["revision"] == 2 && cleared["sections"] == []
  puts "agent_focus_cli: ok (file, integer revision, JSON, stdin clear)"
end
