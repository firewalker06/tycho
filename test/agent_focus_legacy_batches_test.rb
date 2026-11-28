# frozen_string_literal: true

require "tmpdir"
require "fileutils"
require_relative "support/focus_legacy_batch_cases"
require_relative "../lib/hq/domain/agent_focus"

LegacyBatchAgent = Struct.new(:focus_path) do
  def archived? = false
  def attachments = []
end

def assert(value, message)
  raise message unless value
end

def rejects_batch(store, sections, revision)
  before = File.binread(store.instance_variable_get(:@path))
  begin
    store.replace(sections, expected_revision: revision)
  rescue HQ::AgentFocus::Error
    assert(File.binread(store.instance_variable_get(:@path)) == before, "rejection must preserve saved bytes")
    return
  end
  raise "accepted a new or changed overlong entry"
end

failures = []
Dir.mktmpdir("focus-legacy-batches") do |dir|
  path = File.join(dir, "focus.json")
  store = HQ::AgentFocus.new(LegacyBatchAgent.new(path))
  FocusLegacyBatchCases.cases.each do |fixture|
    File.write(path, JSON.generate("revision" => 1, "updated_at" => nil, "sections" => fixture[:before]))
    begin
      saved = store.replace(fixture[:after], expected_revision: 1)
      assert(saved["sections"] == fixture[:after], "#{fixture[:name]}: preserve exact text")
      assert(saved["revision"] == 2, "#{fixture[:name]}: advance once")
      assert(store.replace(fixture[:after], expected_revision: 1) == saved, "#{fixture[:name]}: retry must be idempotent")
      assert(HQ::AgentFocus.new(LegacyBatchAgent.new(path)).read == saved, "#{fixture[:name]}: reload must preserve text")

      changed = Marshal.load(Marshal.dump(fixture[:after]))
      changed[0]["items"][0][fixture[:field]] += "!"
      rejects_batch(store, changed, 2)
      copied = Marshal.load(Marshal.dump(fixture[:after]))
      copied[0]["items"] << Marshal.load(Marshal.dump(copied[0]["items"][0]))
      rejects_batch(store, copied, 2)
      copied_group = Marshal.load(Marshal.dump(fixture[:after]))
      copied_group << Marshal.load(Marshal.dump(copied_group[0]))
      rejects_batch(store, copied_group, 2)
      puts "legacy batch: #{fixture[:name]}: pass"
    rescue HQ::AgentFocus::Error => error
      failures << "#{fixture[:name]}: #{error.message}"
    end
  end
end
raise failures.join("\n") unless failures.empty?
puts "agent_focus_legacy_batches_test: ok"
