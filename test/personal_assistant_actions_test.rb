# frozen_string_literal: true

require "tmpdir"
require_relative "../lib/hq/domain/personal_assistant_actions"

class PersonalAssistantActionsTest
  def self.run
    Dir.mktmpdir do |dir|
      calls = []
      actions = HQ::PersonalAssistantActions.new(path: File.join(dir, "proposals.json"), executor: ->(type, args) { calls << [type, args]; { "ok" => true } })
      read = actions.register!([{ "type" => "inspect_agents", "description" => "Inspect", "arguments" => {} }], active_key: "daily-1").first
      assert(read["state"] == "executed" && calls.length == 1, "expected read-only action to execute directly")
      mutation = actions.register!([{ "type" => "message_agent", "description" => "Send", "arguments" => { "agent_key" => "a", "prompt" => "hello" } }], active_key: "daily-1").first
      assert_raises { actions.execute!(mutation["id"]) }
      done = actions.execute!(mutation["id"], confirmed: true)
      assert(done["state"] == "executed" && calls.length == 2, "expected confirmed mutation once")
      assert_raises { actions.execute!(mutation["id"], confirmed: true) }
      rejected = actions.register!([{ "type" => "start_agent", "description" => "Start", "arguments" => { "agent_key" => "a" } }], active_key: "daily-1").first
      assert(actions.reject!(rejected["id"])["state"] == "rejected", "expected immutable rejection")
      assert_raises { actions.execute!(rejected["id"], confirmed: true) }
      assert_raises { actions.register!([{ "type" => "start_agent", "arguments" => { "agent_key" => "a", "parent_agent_key" => "evil" } }], active_key: "daily-1") }
      duplicate = actions.register!([{ "type" => "message_agent", "description" => "Send", "arguments" => { "agent_key" => "a", "prompt" => "hello" } }], active_key: "daily-1").first
      assert(duplicate["id"] == mutation["id"], "expected immutable payload deduplication")
    end
    puts "personal_assistant_actions_test: OK"
  end

  def self.assert(value, message)
    raise message unless value
  end
  def self.assert_raises
    yield
    raise "expected failure"
  rescue ArgumentError
    true
  end
end

PersonalAssistantActionsTest.run if $PROGRAM_NAME == __FILE__
