# frozen_string_literal: true

require "fileutils"
require "tmpdir"
require "thread"

# This file exercises only the action store, but constants still initialize
# HQ's runtime directories. Isolate them before requiring HQ so a future
# default path cannot touch the operator's FRED files.
WORKER_TEST_HOME = Dir.mktmpdir("tycho-worker-home")
WORKER_TEST_TMPDIR = File.join(WORKER_TEST_HOME, "tmp")
FileUtils.mkdir_p(WORKER_TEST_TMPDIR)
%w[
  TYCHO_CONFIG_PATH TYCHO_SYSTEM_PROMPTS_PATH TYCHO_RESPONSE_STYLE_PATH
  TYCHO_LOGS_ROOT TYCHO_SCHEDULES_PATH TYCHO_SCHEDULES_ROOT
  TYCHO_SCHEDULES_STATE_PATH TYCHO_SCHEDULER_DAEMON_PATH
].each { |name| ENV.delete(name) }
ENV["TYCHO_HOME"] = WORKER_TEST_HOME
ENV["TMPDIR"] = WORKER_TEST_TMPDIR
ENV["TMP"] = WORKER_TEST_TMPDIR
ENV["TEMP"] = WORKER_TEST_TMPDIR
ENV["TYCHO_CODEX_BIN"] = File.join(WORKER_TEST_HOME, "missing-codex")

require_relative "../lib/hq/domain/personal_assistant_actions"
require_relative "../lib/hq/domain/personal_assistant_action_worker"

class PersonalAssistantActionWorkerTest
  def self.run
    assert_lock_is_held_through_effect_and_receipt
    assert_expired_recovery_progresses_after_an_early_restart
    assert_duplicate_receipt_lookup_does_not_wait_for_effect
    puts "personal_assistant_action_worker_test: OK"
  end

  def self.assert_lock_is_held_through_effect_and_receipt
    Dir.mktmpdir do |dir|
      started = Queue.new
      release = Queue.new
      actions = HQ::PersonalAssistantActions.new(
        path: File.join(dir, "proposals.json"),
        auto_execute: false,
        executor: ->(*) { started << true; release.pop; { "ok" => true } },
        verifier: ->(*) { { "completed" => false, "no_effect" => true, "reason" => "not used" } }
      )
      proposal = actions.register_finalized!([
        { "type" => "start_agent", "description" => "Start", "arguments" => { "agent_key" => "agent-1" } }
      ], active_key: "daily-1", source_run_id: "run-1").first
      actions.enqueue!(proposal.fetch("id"), confirmed: true, digest: proposal.fetch("digest"))
      worker = HQ::PersonalAssistantActionWorker.new(actions:, worker_id: "worker-a", wait: 0.01)
      worker.start!
      started.pop
      assert(actions.proposal(proposal.fetch("id"))["state"] == "executing", "expected the worker to persist executing before effect")

      verification = Thread.new do
        begin
          actions.verify!(proposal.fetch("id"))
          :unexpected_success
        rescue ArgumentError => e
          e.message
        end
      end
      result = verification.value
      assert(result.include?("still executing"), "expected verification to fail promptly while effect lock is held")

      release << true
      wait_until { actions.proposal(proposal.fetch("id"))["state"] == "executed" }
      worker.shutdown
    end
  end

  def self.assert_expired_recovery_progresses_after_an_early_restart
    Dir.mktmpdir do |dir|
      now = Time.utc(2026, 9, 9, 12)
      clock = -> { now }
      path = File.join(dir, "proposals.json")
      actions = HQ::PersonalAssistantActions.new(
        path:, auto_execute: false, clock:, executor: ->(*) { raise "must not execute" }
      )
      proposal = actions.register_finalized!([
        { "type" => "start_agent", "description" => "Start", "arguments" => { "agent_key" => "agent-2" } }
      ], active_key: "daily-1", source_run_id: "run-2").first
      actions.enqueue!(proposal.fetch("id"), confirmed: true, digest: proposal.fetch("digest"))
      actions.process_next!(owner_id: "dead-worker", lease_seconds: 10)
      # Simulate a process that died after persisting its claim, before any
      # effect call. The lease is still active when the replacement starts.
      raw = HQ::FileStore.read_json(path, fallback: {})
      target = raw.fetch("proposals").find { |item| item["id"] == proposal["id"] }
      target["state"] = "executing"
      target["claim_owner"] = "dead-worker"
      target["lease_expires_at"] = (now + 10).iso8601(6)
      HQ::FileStore.write_json(path, raw)

      replacement_actions = HQ::PersonalAssistantActions.new(
        path:, auto_execute: false, clock:, executor: ->(*) { raise "must not execute" }
      )
      worker = HQ::PersonalAssistantActionWorker.new(actions: replacement_actions, worker_id: "replacement", wait: 0.01, lease_seconds: 10)
      worker.start!
      assert(replacement_actions.proposal(proposal["id"])["state"] == "executing", "expected an early restart to respect the active lease")
      now += 11
      worker.wake!
      wait_until { replacement_actions.proposal(proposal["id"])["state"] == "failed" }
      recovered = replacement_actions.proposal(proposal["id"])
      assert(recovered["code"] == "outcome_unknown" && recovered.dig("recovery", "action") == "verify",
             "expected periodic recovery to settle an expired interrupted action as unknown")
      worker.shutdown
    end
  end

  def self.assert_duplicate_receipt_lookup_does_not_wait_for_effect
    Dir.mktmpdir do |dir|
      started = Queue.new
      release = Queue.new
      actions = HQ::PersonalAssistantActions.new(
        path: File.join(dir, "proposals.json"), auto_execute: false,
        executor: ->(*) { started << true; release.pop; { "ok" => true } }
      )
      proposal = actions.register_finalized!([
        { "type" => "start_agent", "description" => "Start", "arguments" => { "agent_key" => "agent-3" } }
      ], active_key: "daily-1", source_run_id: "run-3").first
      actions.enqueue!(proposal["id"], confirmed: true, digest: proposal["digest"])
      worker = HQ::PersonalAssistantActionWorker.new(actions:, worker_id: "worker-c", wait: 0.01)
      worker.start!
      started.pop

      started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      replay = actions.enqueue!(proposal["id"], confirmed: true, digest: proposal["digest"])
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at
      assert(elapsed < 0.25, "expected duplicate acceptance to avoid waiting on the live effect lock")
      assert(replay["accepted"] == true && replay["replayed"] == true && replay.dig("proposal", "state") == "executing",
             "expected duplicate acceptance to return the existing executing receipt")

      release << true
      worker.shutdown
    end
  end

  def self.wait_until(timeout: 2)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    until yield
      raise "timed out waiting for worker state" if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

      sleep 0.01
    end
  end

  def self.assert(value, message)
    raise message unless value
  end
end

PersonalAssistantActionWorkerTest.run if $PROGRAM_NAME == __FILE__
