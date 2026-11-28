# frozen_string_literal: true

require "tmpdir"
require "fileutils"
require_relative "../lib/hq/domain/agent_focus"

TextLimitAgent = Struct.new(:focus_path) do
  def archived? = false
  def attachments = []
end

def assert(value, message)
  raise message unless value
end

def rejects_text(store, sections, revision, limit)
  before = File.binread(store.instance_variable_get(:@path))
  begin
    store.replace(sections, expected_revision: revision)
    raise "accepted invalid #{limit}-character text"
  rescue HQ::AgentFocus::Error => error
    assert(error.message.include?("#{limit} characters"), "wrong limit error: #{error.message}")
  end
  assert(File.binread(store.instance_variable_get(:@path)) == before, "rejection must not write or truncate data")
end

def copy(value)
  Marshal.load(Marshal.dump(value))
end

Dir.mktmpdir("focus-text-limits") do |dir|
  path = File.join(dir, "focus.json")
  store = HQ::AgentFocus.new(TextLimitAgent.new(path))
  # Ruby String#length counts code points, including combining marks and ZWJ.
  ["a", "😀", "界", "e\u0301", "👩‍💻"].each do |unit|
    title = (unit * 40).each_char.take(40).join
    subtitle = (unit * 60).each_char.take(60).join
    saved = store.replace([{ "title" => title, "subtitle" => subtitle, "items" => [{ "title" => title, "subtitle" => subtitle }] }], expected_revision: store.read["revision"])
    assert(saved["sections"][0]["title"] == title && saved["sections"][0]["items"][0]["subtitle"] == subtitle, "boundary text must stay exact")
    %w[title subtitle].each do |field|
      [false, true].each do |item|
        invalid = copy(saved["sections"])
        target = item ? invalid[0]["items"][0] : invalid[0]
        target[field] += "x"
        rejects_text(store, invalid, saved["revision"], field == "title" ? 40 : 60)
      end
    end
  end

  legacy = [{ "title" => "G" * 70, "subtitle" => " Group\r\n" * 15, "icon" => "note", "items" => [
    { "title" => "I" * 70, "subtitle" => " Item\r\n" * 15, "attachments" => [] }
  ] }, { "title" => "Other", "subtitle" => nil, "icon" => "note", "items" => [] }]
  File.write(path, JSON.generate("revision" => 10, "updated_at" => nil, "sections" => legacy))
  assert(store.read["sections"] == legacy, "read must preserve legacy text and line endings")
  edited = copy(legacy)
  edited[0]["completed"] = true
  edited[0]["icon"] = "todo_done"
  edited[0]["items"][0]["completed"] = true
  edited.reverse!
  saved = store.replace(edited, expected_revision: 10)
  assert(saved["sections"][1]["title"] == legacy[0]["title"], "completion/reorder must preserve long titles")
  assert(saved["sections"][1]["items"][0]["subtitle"] == legacy[0]["items"][0]["subtitle"], "completion must preserve subtitle bytes")
  assert(store.replace(edited, expected_revision: 10) == saved, "legacy exact retry must stay idempotent")
  %w[title subtitle].each do |field|
    [false, true].each do |item|
      invalid = copy(saved["sections"])
      target = item ? invalid[1]["items"][0] : invalid[1]
      target[field] += "x"
      rejects_text(store, invalid, 11, field == "title" ? 40 : 60)
    end
  end
  renamed = copy(saved["sections"])
  renamed[1]["title"] = "Renamed"
  renamed[1]["items"][0]["title"] = "Renamed task"
  saved = store.replace(renamed, expected_revision: 11)
  assert(saved["sections"][1]["subtitle"] == legacy[0]["subtitle"], "title edits must preserve unchanged legacy subtitles")
  shortened = copy(saved["sections"])
  shortened[1]["title"] = "New group heading"
  shortened[1]["subtitle"] = "New group description"
  saved = store.replace(shortened, expected_revision: 12)
  assert(saved["sections"][1]["items"][0]["subtitle"] == legacy[0]["items"][0]["subtitle"], "group edits must not invalidate unchanged item text")
  invalid = copy(saved["sections"])
  invalid << copy(invalid[1])
  rejects_text(store, invalid, 13, 60)

  # Exact duplicate legacy entries can be completed or removed, but not copied.
  duplicates = [legacy[0], copy(legacy[0])]
  File.write(path, JSON.generate("revision" => 20, "updated_at" => nil, "sections" => duplicates))
  completed = copy(duplicates)
  completed[0]["completed"] = true
  saved = store.replace(completed, expected_revision: 20)
  rejects_text(store, saved["sections"] + [copy(saved["sections"][0])], 21, 40)
  removed = store.replace([saved["sections"][0]], expected_revision: 21)
  assert(removed["sections"].length == 1, "deleting duplicate legacy work must remain possible")
  shared = ["First", "Second"].map do |title|
    { "title" => title, "subtitle" => "Shared legacy description " * 4, "items" => [{ "title" => title * 15 }] }
  end
  File.write(path, JSON.generate("revision" => 30, "updated_at" => nil, "sections" => shared))
  renamed = copy(shared).reverse
  renamed.each { |section| section["title"] += " renamed" }
  saved = store.replace(renamed, expected_revision: 30)
  assert(saved["sections"][0]["items"][0]["title"] == shared[1]["items"][0]["title"], "shared legacy descriptions must not confuse reordered renamed groups")

end
puts "agent_focus_text_limits_test: ok"
