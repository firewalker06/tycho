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
  boundary = [{ "title" => "😀" * 40, "subtitle" => "😀" * 60, "items" => [{ "title" => "界" * 40, "subtitle" => "界" * 60 }] }]
  File.write(input, JSON.generate(boundary))
  limited = command.call("agent", "focus", key, "--file", input, "--revision", "2", "--json")
  raise "CLI boundary write was truncated" unless limited["sections"][0]["title"] == boundary[0]["title"]
  %w[title subtitle].each do |field|
    [false, true].each do |item|
      invalid = Marshal.load(Marshal.dump(boundary))
      (item ? invalid[0]["items"][0] : invalid[0])[field] += "x"
      File.write(input, JSON.generate(invalid))
      out, err, status = Open3.capture3(env, "bundle", "exec", "bin/tycho", "agent", "focus", key, "--file", input, "--revision", "3", "--json")
      limit = field == "title" ? 40 : 60
      raise "CLI accepted invalid text: #{out} #{err}" if status.success?
      raise "CLI limit feedback is missing" unless "#{out} #{err}".include?("#{limit} characters")
    end
  end
  raise "CLI rejection changed saved text" unless command.call("agent", "focus", key, "--json") == limited
  require_relative "support/focus_legacy_batch_cases"
  agents = JSON.parse(File.read(File.join(env.fetch("TYCHO_LOGS_ROOT"), "managed_agents.json")))
  focus_path = agents.find { |agent| agent["key"] == key }.fetch("log_path").sub(/\.raw\.log\z/, ".focus.json")
  FocusLegacyBatchCases.cases.first(2).each do |fixture|
    File.write(focus_path, JSON.generate("revision" => 1, "updated_at" => nil, "sections" => fixture[:before]))
    File.write(input, JSON.generate(fixture[:after]))
    saved = command.call("agent", "focus", key, "--file", input, "--revision", "1", "--json")
    raise "CLI rejected or changed #{fixture[:name]}" unless saved["revision"] == 2 && saved["sections"] == fixture[:after]
    raise "CLI batch retry changed the revision" unless command.call("agent", "focus", key, "--file", input, "--revision", "1", "--json") == saved
    changed = Marshal.load(Marshal.dump(fixture[:after]))
    changed[0]["items"][0][fixture[:field]] += "!"
    copied = Marshal.load(Marshal.dump(fixture[:after]))
    copied[0]["items"] << Marshal.load(Marshal.dump(copied[0]["items"][0]))
    [changed, copied].each do |invalid|
      before = File.binread(focus_path)
      File.write(input, JSON.generate(invalid))
      out, err, status = Open3.capture3(env, "bundle", "exec", "bin/tycho", "agent", "focus", key, "--file", input, "--revision", "2", "--json")
      raise "CLI accepted invalid batch: #{out} #{err}" if status.success?
      raise "CLI rejection changed saved data" unless File.binread(focus_path) == before
    end
    puts "CLI legacy batch: #{fixture[:name]}: pass"
  end
  puts "agent_focus_cli: ok (file, integer revision, JSON, stdin clear)"
end
