# frozen_string_literal: true

require "fileutils"
require "json"
require "tmpdir"

require_relative "../lib/hq/remote_server"

module SleepCircuitBreakerRecoveryTest
  module_function

  def run!
    assert_incident_finalizes_with_dedicated_reason_and_delayed_recovery
    assert_delegated_callback_exposes_scheduled_recovery
    assert_manual_intent_cancels_recovery_atomically
    assert_stale_ownership_generation_cancels_recovery
    assert_recovery_run_cannot_create_a_recovery_loop
    puts "sleep_circuit_breaker_recovery_test: ok"
  end

  def assert_delegated_callback_exposes_scheduled_recovery
    with_store do |store, child|
      now = Time.now
      parent_log = File.join(HQ::AGENT_LOGS_DIR, "parent.raw.log")
      File.write(parent_log, "")
      parent = HQ::ManagedAgent.new(
        key: "parent-agent", name: "Parent", project_key: "web", template_key: "custom",
        workspace: child.workspace, prompt: "Coordinate", agent: "codex", started_at: now, finished_at: now,
        last_exit_code: 0, log_path: parent_log,
        runs: [HQ::ManagedAgent::AgentRun.new(
          run_id: "parent-run", started_at: now, finished_at: now, exit_code: 0,
          status: "succeeded", log_path: parent_log, metadata: {}
        )]
      )
      store.delegation_coordinator.attach!(agents: [parent, child], child:, parent_key: parent.key)
      child.last_run.delegation_owner = "parent"
      child.last_run.delegation_generation = 1
      finalize_incident!(child, "incident-delegated")
      store.save([parent, child])

      agents, = store.load_with_poll_events(process_delegations: true, dispatch_prompt_queues: false)
      persisted_parent = agents.find { |agent| agent.key == parent.key }
      callback = persisted_parent.queued_prompts.find { |entry| entry["source"] == "delegation_callback" }
      report = store.delegation_coordinator.delegation_store.reports.find do |item|
        item["child_run_id"] == "run-incident-delegated"
      end
      payload = JSON.parse(callback.fetch("prompt").split("\n", 2).last)
      payload_recovery = payload.dig("reports", 0, "recovery")
      stored_recovery = report&.fetch("recovery", nil)
      assert(callback && report && payload.dig("reports", 0, "summary") ==
             "Stopped due to overusing sleep-like commands" &&
             stored_recovery == payload_recovery &&
             payload_recovery["type"] == "sleep_circuit_breaker" &&
             payload_recovery["incident_id"] == "incident-delegated" &&
             payload_recovery["expected_safety_behavior"] == true &&
             payload_recovery["state"] == "scheduled" &&
             payload_recovery["parent_action"] == "none" &&
             payload_recovery["delay_seconds"] == 60 &&
             !payload_recovery["not_before"].to_s.empty? &&
             payload_recovery["cancels_on"] == %w[manual_prompt ownership_change],
             "expected the immediate delegated callback to carry Tycho-owned recovery context")
    end
  end

  def assert_incident_finalizes_with_dedicated_reason_and_delayed_recovery
    with_store do |store, agent, registry|
      finalize_incident!(agent, "incident-one")
      store.save([agent])
      persisted = store.load_with_poll_events(process_delegations: false, dispatch_prompt_queues: false).first.first
      run = persisted.last_run
      recovery = persisted.prompt_queue.first
      assert(run.status == "stopped" && run.metadata["stop_reason"] == "sleep_circuit_breaker" &&
             persisted.last_summary == "Stopped due to overusing sleep-like commands" &&
             recovery["source"] == "sleep_circuit_breaker_recovery" &&
             Time.parse(recovery["not_before"]) > Time.parse(recovery["accepted_at"]) &&
             recovery["prompt"].include?("tycho agent send") && recovery["prompt"].include?("--delay 60"),
             "expected a dedicated stopped result and incident-scoped delayed recovery")

      due_at = Time.parse(recovery.fetch("not_before"))
      persisted.claim_pending_prompts!(claimed_at: due_at + 2)
      persisted.prepare_prompt_queue_claim!
      recovery_event = HQ::AgentMemory.new(persisted).events.reverse.find do |event|
        event["type"] == "user_message" && event.dig("metadata", "circuit_breaker_recovery")
      end
      recovery_metadata = recovery_event&.dig("metadata", "circuit_breaker_recovery")
      assert(recovery_metadata&.fetch("incident_id") == "incident-one" &&
             recovery_metadata["entry_id"] == "sleep-recovery:incident-one" &&
             recovery_metadata["instruction"] == recovery["prompt"] &&
             recovery_metadata["accepted_at"] == recovery["accepted_at"] &&
             recovery_metadata["not_before"] == recovery["not_before"] &&
             recovery_metadata["delay_seconds"] == 60 &&
             recovery_metadata["blocking_call_count"] == 3 &&
             recovery_metadata["threshold"] == 3,
             "expected dispatched recovery messages to retain structured Conversation metadata")

      batch = persisted.queue_work_batch(recovery_metadata.fetch("queue_work_batch_id"))
      legacy_entry = batch.fetch("entries").find { |entry| entry["id"] == recovery["id"] }
      legacy_entry.fetch("message_metadata").delete("sleep_recovery_observed_at")
      legacy_entry.fetch("message_metadata").delete("sleep_recovery_threshold")
      legacy_entry.fetch("message_metadata").delete("sleep_recovery_blocking_call_count")
      memory = HQ::AgentMemory.new(persisted)
      legacy_events = memory.events
      legacy_event = legacy_events.reverse.find do |event|
        event["type"] == "user_message" &&
          event.dig("metadata", "sleep_recovery_for_incident_id") == "incident-one"
      end
      legacy_event.fetch("metadata").delete("circuit_breaker_recovery")
      memory.write_events!(legacy_events)
      store.save([persisted])

      reloaded_recovery = HQ::RemoteService.new(registry:).conversation(persisted.key).find do |block|
        block.dig(:metadata, "sleep_recovery_for_incident_id") == "incident-one"
      end
      legacy_metadata = reloaded_recovery&.dig(:metadata, "circuit_breaker_recovery")
      assert(legacy_metadata&.fetch("instruction") == recovery["prompt"] &&
             legacy_metadata["delay_seconds"] == 60 &&
             legacy_metadata["blocking_call_count"] == 3 &&
             legacy_metadata["threshold"] == 3 &&
             legacy_metadata["queue_work_batch_id"] == batch["id"] &&
             reloaded_recovery[:content].start_with?("[TYCHO QUEUE WORK CONTRACT"),
             "expected a pre-amendment recovery message to be enriched after service reload")

      blocks = HQ::AgentChatLog.new(persisted).chat_blocks
      summary = blocks.find { |block| block.kind == :run_summary }
      assert(summary&.content&.include?("Stopped due to overusing sleep-like commands"),
             "expected the stop reason in a clear conversation run-summary block")
    end
  end

  def assert_manual_intent_cancels_recovery_atomically
    with_store do |store, agent|
      finalize_incident!(agent, "incident-two")
      store.save([agent])
      store.load_with_poll_events(process_delegations: false, dispatch_prompt_queues: false)
      updated = store.accept_ordinary_prompt!(
        agent.key,
        text: "Proceed manually",
        attachments: [],
        actor: HQ::DelegationActor.user_actor
      )
      assert(updated.prompt_queue.none? { |entry| entry["source"] == "sleep_circuit_breaker_recovery" } &&
             updated.last_run.metadata["sleep_recovery_cancelled"] == "manual_intent" &&
             updated.delegation_recovery_context["state"] == "cancelled" &&
             updated.delegation_recovery_context["parent_action"] == "required" &&
             updated.delegation_recovery_context["reason"] == "manual_intent",
             "expected manual prompt acceptance to cancel recovery under the store lock")
    end
  end

  def assert_recovery_run_cannot_create_a_recovery_loop
    with_store do |store, agent|
      agent.last_run.metadata = { "sleep_recovery_for_incident_id" => "prior-incident" }
      finalize_incident!(agent, "incident-three")
      store.save([agent])
      persisted = store.load_with_poll_events(process_delegations: false, dispatch_prompt_queues: false).first.first
      assert(persisted.prompt_queue.empty? &&
             persisted.last_run.metadata["sleep_recovery_suppressed"] == "recovery_loop" &&
             persisted.delegation_recovery_context["state"] == "suppressed" &&
             persisted.delegation_recovery_context["parent_action"] == "required" &&
             persisted.delegation_recovery_context["reason"] == "recovery_loop",
             "expected a recovery-triggered incident not to schedule another recovery")
    end
  end

  def assert_stale_ownership_generation_cancels_recovery
    with_store do |store, agent|
      finalize_incident!(agent, "incident-stale")
      incident = agent.last_run.metadata.fetch("sleep_circuit_breaker_incident")
      incident["ownership_generation"] = 7
      store.save([agent])

      persisted = store.load_with_poll_events(process_delegations: false, dispatch_prompt_queues: false).first.first
      assert(persisted.prompt_queue.empty? &&
             persisted.last_run.metadata["sleep_recovery_pending"] == false &&
             persisted.last_run.metadata["sleep_recovery_cancelled"] == "ownership_generation_changed" &&
             persisted.delegation_recovery_context["state"] == "cancelled" &&
             persisted.delegation_recovery_context["parent_action"] == "required" &&
             persisted.delegation_recovery_context["reason"] == "ownership_generation_changed",
             "expected recovery from a stale ownership generation to be cancelled before enqueue")
    end
  end

  def finalize_incident!(agent, incident_id)
    run = agent.last_run
    run.status = "running"
    run.run_id = "run-#{incident_id}"
    agent.instance_variable_set(:@last_exit_code, 143)
    agent.instance_variable_set(:@stop_requested_at, Time.now)
    path = agent.send(:sleep_incident_file_path, run.run_id)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, JSON.generate(
      "id" => incident_id,
      "reason" => "sleep_circuit_breaker",
      "observed_at" => Time.now.utc.iso8601(6),
      "threshold" => 3,
      "blocking_call_count" => 3
    ))
    agent.send(:finalize_latest_run!)
  end

  def with_store
    Dir.mktmpdir("tycho-sleep-recovery") do |dir|
      old_agents = replace_constant(HQ, :AGENTS_FILE, File.join(dir, "managed_agents.json"))
      old_delegations = replace_constant(HQ, :DELEGATIONS_FILE, File.join(dir, "agent_delegations.json"))
      old_logs = replace_constant(HQ, :AGENT_LOGS_DIR, File.join(dir, "agents"))
      old_usage = replace_constant(HQ, :USAGE_METRICS_FILE, File.join(dir, "usage_metrics.json"))
      workspace = File.join(dir, "workspace")
      FileUtils.mkdir_p([workspace, HQ::AGENT_LOGS_DIR])
      config = File.join(dir, "hq.yml")
      prompts = File.join(dir, "prompts.yml")
      File.write(config, "projects:\n  - key: web\n    name: Web\n    path: #{workspace}\n")
      File.write(prompts, "custom: Work.\n")
      registry = HQ::Registry.new(path: config, system_prompts_path: prompts)
      now = Time.now
      raw = File.join(HQ::AGENT_LOGS_DIR, "breaker.raw.log")
      File.write(raw, "")
      agent = HQ::ManagedAgent.new(
        key: "breaker-agent", name: "Breaker", project_key: "web", template_key: "custom",
        workspace:, prompt: "Work", agent: "codex", started_at: now, finished_at: now,
        last_exit_code: 0, log_path: raw,
        runs: [HQ::ManagedAgent::AgentRun.new(
          run_id: "initial", started_at: now, finished_at: now, exit_code: 0,
          status: "succeeded", log_path: raw, metadata: {}
        )]
      )
      yield HQ::AgentStore.new(registry.projects), agent, registry
    ensure
      replace_constant(HQ, :AGENTS_FILE, old_agents) if old_agents
      replace_constant(HQ, :DELEGATIONS_FILE, old_delegations) if old_delegations
      replace_constant(HQ, :AGENT_LOGS_DIR, old_logs) if old_logs
      replace_constant(HQ, :USAGE_METRICS_FILE, old_usage) if old_usage
    end
  end

  def replace_constant(owner, name, value)
    previous = owner.const_get(name)
    owner.send(:remove_const, name)
    owner.const_set(name, value)
    previous
  end

  def assert(condition, message)
    raise message unless condition
  end
end

SleepCircuitBreakerRecoveryTest.run! if $PROGRAM_NAME == __FILE__
