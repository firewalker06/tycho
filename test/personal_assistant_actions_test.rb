# frozen_string_literal: true

require "tmpdir"
require "thread"
require_relative "../lib/hq/domain/personal_assistant_actions"

class PersonalAssistantActionsTest
  def self.run
    Dir.mktmpdir do |dir|
      calls = []
      actions = HQ::PersonalAssistantActions.new(path: File.join(dir, "proposals.json"), executor: ->(type, args) { calls << [type, args]; { "ok" => true } })
      read = actions.register_finalized!([{ "type" => "inspect_agents", "description" => "Inspect", "arguments" => {} }], active_key: "daily-1", source_run_id: "run-1").first
      assert(read["state"] == "executed" && calls.length == 1, "expected read-only action to execute directly")
      mutation = actions.register_finalized!([{ "type" => "message_agent", "description" => "Send", "arguments" => { "agent_key" => "a", "prompt" => "hello" } }], active_key: "daily-1", source_run_id: "run-2").first
      assert(mutation["source_run_id"] == "run-2" && mutation["active_key"] == "daily-1", "expected UI-safe immutable proposal provenance")
      assert_raises { actions.execute!(mutation["id"]) }
      done = actions.execute!(mutation["id"], confirmed: true)
      assert(done["state"] == "executed" && calls.length == 2, "expected confirmed mutation once")
      assert_raises { actions.execute!(mutation["id"], confirmed: true) }
      rejected = actions.register_finalized!([{ "type" => "start_agent", "description" => "Start", "arguments" => { "agent_key" => "a" } }], active_key: "daily-1", source_run_id: "run-3").first
      assert(actions.reject!(rejected["id"])["state"] == "rejected", "expected immutable rejection")
      assert_raises { actions.execute!(rejected["id"], confirmed: true) }
      assert_raises { actions.register_finalized!([{ "type" => "start_agent", "arguments" => { "agent_key" => "a", "parent_agent_key" => "evil" } }], active_key: "daily-1", source_run_id: "run-4") }
      duplicate = actions.register_finalized!([{ "type" => "message_agent", "description" => "Send", "arguments" => { "agent_key" => "a", "prompt" => "hello" } }], active_key: "daily-1", source_run_id: "run-2").first
      assert(duplicate["id"] == mutation["id"], "expected immutable payload deduplication")
      threads = 2.times.map { Thread.new { actions.execute!(mutation["id"], confirmed: true) rescue ArgumentError } }; threads.each(&:join)
      assert(calls.count { |type, _| type == "message_agent" } == 1, "expected concurrent confirmation to execute once")

      failing = HQ::PersonalAssistantActions.new(
        path: File.join(dir, "failing-proposals.json"),
        executor: ->(*) { raise "temporary failure" },
        verifier: ->(_type, _args, _proposal) { { "completed" => false, "no_effect" => true, "reason" => "No effect found" } }
      )
      failed = failing.register_finalized!([
                                             { "type" => "create_project", "description" => "Create", "arguments" => { "key" => "demo", "name" => "Demo", "path" => "/tmp", "group" => nil, "agent" => nil, "model" => nil, "reasoning_effort" => nil } }
                                           ], active_key: "daily-1", source_run_id: "run-5").first
      begin
        failing.execute!(failed["id"], confirmed: true)
      rescue RuntimeError
        nil
      end
      failed = failing.proposal(failed["id"])
      assert(failed["state"] == "failed" && failed.dig("recovery", "action") == "verify", "expected failed action verification recovery")
      reconciled = failing.verify!(failed["id"])
      assert(reconciled["state"] == "failed" && reconciled.dig("recovery", "action") == "replace", "expected replacement only after verified no effect")

      unknown = HQ::PersonalAssistantActions.new(
        path: File.join(dir, "unknown-proposals.json"),
        executor: ->(*) { raise "interrupted" },
        verifier: ->(*) { { "completed" => false, "reason" => "Outcome unknown" } }
      )
      proposal = unknown.register_finalized!([
                                                { "type" => "start_agent", "description" => "Start", "arguments" => { "agent_key" => "a" } }
                                              ], active_key: "daily-1", source_run_id: "run-6").first
      begin
        unknown.execute!(proposal["id"], confirmed: true)
      rescue RuntimeError
        nil
      end
      checked = unknown.verify!(proposal["id"])
      assert(checked.dig("recovery", "state") == "outcome_unknown" && checked.dig("recovery", "action") == "verify", "expected uncertain verification to forbid replacement")

      started = Queue.new
      release = Queue.new
      concurrent = HQ::PersonalAssistantActions.new(
        path: File.join(dir, "concurrent-proposals.json"),
        executor: ->(*) { started << true; release.pop; { "ok" => true } }
      )
      proposal = concurrent.register_finalized!([
                                                   { "type" => "start_agent", "description" => "Start", "arguments" => { "agent_key" => "a" } }
                                                 ], active_key: "daily-1", source_run_id: "run-7").first
      first = Thread.new { concurrent.execute!(proposal["id"], confirmed: true) }
      started.pop
      second = Thread.new { concurrent.execute!(proposal["id"], confirmed: true) rescue ArgumentError }
      assert(concurrent.proposal(proposal["id"])["state"] == "executing", "expected a losing concurrent claim to leave the active execution intact")
      release << true
      first.join; second.join
      assert(concurrent.proposal(proposal["id"])["state"] == "executed", "expected the original concurrent action to complete")
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
