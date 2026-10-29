# frozen_string_literal: true

require "base64"
require "fileutils"
require "rbconfig"
require "tmpdir"

require_relative "../lib/hq/remote_server"

module PromptQueueTest
  module_function

  def run!
    assert_queue_persists_and_reconciles_across_clients
    assert_queued_launches_save_only_the_originating_parent_run
    assert_confirmed_starts_recover_before_parent_summary
    assert_delayed_remote_acceptance_is_durable
    assert_due_entries_bypass_future_entries_in_fifo_order
    assert_self_delayed_continuation_preserves_delegation_ownership
    assert_claim_race_drains_fifo_without_overlap
    assert_pending_queue_visibility_tracks_processing_state
    assert_result_statuses_apply_queue_release_policy
    assert_partial_release_matrix_preserves_fifo_and_later_work
    assert_terminal_partial_run_dispatches_pending_work_once
    assert_input_required_terminal_result_keeps_pending_work_gated
    assert_selected_processing_preserves_fifo_and_prevents_duplicate_dispatch
    assert_stale_selected_process_preserves_inquiry
    assert_bulk_removal_is_audited_and_stale_snapshots_do_nothing
    assert_queue_action_routes_report_stale_and_selected_results
    assert_automatic_dispatch_records_one_structured_read_block
    assert_native_automatic_dispatch_captures_after_accounting
    assert_direct_start_records_active_queue_work
    assert_spawn_failure_does_not_record_queue_delivery
    assert_native_spawn_failure_rolls_back_and_retries_safely
    assert_pre_staging_restart_aborts_orphaned_runner_and_retries_once
    assert_exact_boundary_restart_rolls_back_failed_native_spawn_and_retries_once
    assert_rollback_boundary_restart_removes_false_read_and_retries_once
    assert_exact_boundary_restart_accepts_successful_native_acknowledgement_once
    assert_exact_boundary_repair_failures_keep_native_gate_closed
    assert_persistent_queue_delivery_save_failure_stops_and_retries_safely
    assert_persistent_queue_delivery_append_failure_stops_and_retries_safely
    assert_missing_queue_event_repairs_without_new_delivery
    assert_queue_event_match_requires_read_semantics_and_batch
    assert_memory_rebuild_preserves_queue_read
    assert_concurrent_rebuild_and_queue_append_keep_read
    assert_queue_delivery_rollback_serializes_with_rebuild
    assert_explicit_read_consumes_one_mixed_batch_and_records_conversation
    assert_explicit_read_failure_retains_queue
    assert_explicit_read_keeps_concurrent_arrivals
    assert_concurrent_readers_share_one_open_batch
    assert_dispatch_failure_retains_one_prepared_batch_for_retry
    assert_resolved_failed_claim_reconciles_and_drains_newer_fifo_work
    assert_failed_claim_can_be_discarded_except_for_delegation_callbacks
    assert_loaded_resolved_claim_reconciles_after_later_successful_runs
    assert_entries_accepted_after_claim_form_a_consecutive_batch
    assert_authority_is_captured_per_fifo_entry
    assert_callback_can_start_a_never_run_parent
    assert_server_poll_preserves_nested_callback_authority
    assert_terminal_reports_survive_automatic_callback_dispatch
    assert_report_write_failure_prevents_callback_successor
    assert_normal_stop_dispatches_pending_work
    assert_idle_agent_without_live_pid_dispatches_pending_work
    assert_ineligible_agents_do_not_dispatch_pending_work
    assert_archive_stops_run_and_preserves_unperformed_queue_work
    assert_archive_marks_delivered_queue_work_uncertain
    assert_legacy_entries_load_without_authority
    assert_success_auto_completes_delivered_queue_work
    assert_success_finish_gate_resumes_once_in_same_session
    assert_late_status_write_cannot_finish_successor_run
    assert_active_and_restorable_inquiries_block_dispatch
    assert_manual_prompt_retires_inquiry_without_dropping_queue
    puts "prompt_queue_test: ok"
  end

  def assert_queued_launches_save_only_the_originating_parent_run
    %w[same-run later-run later-run-explicit].each do |mode|
      with_queue_store do |registry, workspace|
        parent_workspace = File.join(workspace, "parent")
        FileUtils.mkdir_p(parent_workspace)
        harness = File.join(workspace, "gated-codex")
        File.write(harness, <<~'RUBY')
          #!/usr/bin/env ruby
          require "json"
          gate = File.join(Dir.pwd, "#{ENV.fetch("TYCHO_RUN_ID")}.release")
          deadline = Time.now + 60
          sleep 0.01 until File.exist?(gate) || Time.now >= deadline
          payload = { "status" => "success", "summary" => "Processed the queued work", "inquiry" => nil,
                      "attachments" => nil, "summary_sections" => nil, "memory_handoff" => nil }
          output_index = ARGV.index("-o")
          File.write(ARGV[output_index + 1], JSON.generate(payload)) if output_index
          puts JSON.generate("type" => "item.completed", "item" => { "type" => "agent_message", "text" => JSON.generate(payload) })
          puts JSON.generate("type" => "turn.completed")
        RUBY
        File.chmod(0o755, harness)
        previous_codex_bin = ENV["TYCHO_CODEX_BIN"]
        ENV["TYCHO_CODEX_BIN"] = harness
        store = HQ::AgentStore.new(registry.projects)
        parent = HQ::ManagedAgent.new(
          key: "summary-parent", name: "Summary parent", project_key: "web", template_key: "custom",
          workspace: parent_workspace, prompt: "Coordinate", log_path: File.join(parent_workspace, "parent.raw.log")
        )
        child = HQ::ManagedAgent.new(
          key: "summary-child", name: "Summary child", project_key: "web", template_key: "custom",
          workspace:, prompt: "Initial work", log_path: File.join(workspace, "child.raw.log")
        )
        store.associate_delegation!(agents: [parent, child], child:, parent_key: parent.key)
        store.save([parent, child])
        pids = []
        parent = store.start_agent!(parent.key)
        pids << parent.pid
        child = store.start_agent!(child.key)
        pids << child.pid
        original_parent_run_id = parent.last_run.run_id
        initial_child_run_id = child.last_run.run_id
        actor = HQ::DelegationActor.parent_actor(parent.key)
        request = { prompt: "Queued private instruction", actor:, event_id: "queued-summary-send", start: true }
        queued = store.accept_or_abort_prompt!(child.key, **request)
        assert(queued[:status] == :queued, "#{mode}: expected a queued send behind a busy native child")
        expected_origin = { "parent_agent_key" => parent.key, "parent_run_id" => original_parent_run_id }
        assert(queued[:entry].dig("message_metadata", "delegated_action_origin") == expected_origin,
               "#{mode}: expected durable parent run attribution at acceptance")

        if mode != "same-run"
          store.stop_context_replacement!(parent.key)
          parent = store.start_agent!(parent.key)
          pids << parent.pid
          assert(parent.last_run.run_id != original_parent_run_id, "expected a distinct later parent run")
        end
        # A fresh store must recover acceptance metadata before it dispatches.
        store = HQ::AgentStore.new(registry.projects)
        File.write(File.join(workspace, "#{initial_child_run_id}.release"), "finish")
        deadline = Time.now + 10
        loop do
          agents, = store.load_with_poll_events(process_delegations: false, dispatch_prompt_queues: mode != "later-run-explicit")
          child = agents.find { |agent| agent.key == child.key }
          break if mode == "later-run-explicit" ? !child.running? : child.run_count == 2
          raise "#{mode}: queued native child did not advance" if Time.now >= deadline

          sleep 0.01
        end
        if mode == "later-run-explicit"
          child = store.start_agent!(child.key, prefer_queued: true, actor:)
        end
        pids << child.pid
        assert(child.run_count == 2 && child.last_run.metadata["native_start_acknowledged"],
               "#{mode}: expected a confirmed second native child launch")
        assert(child.last_run.metadata["delegated_action_origin"] == expected_origin,
               "#{mode}: expected the confirmed child run to keep its original acceptance stamp")
        confirmed_id = "agent-start:#{child.key}:#{child.last_run.run_id}"
        assert(store.accept_or_abort_prompt!(child.key, **request)[:replayed], "#{mode}: expected send replay")
        2.times { store.load_with_poll_events(process_delegations: false, dispatch_prompt_queues: false) }
        store.start_agent!(child.key, actor:)
        store.stop_context_replacement!(parent.key)
        restored = HQ::ManagedAgent.from_hash(HQ::FileStore.read_json(HQ::AGENTS_FILE, fallback: []).find { |item| item["key"] == parent.key })
        summaries = HQ::AgentMemory.new(restored).events.select { |event| event["type"] == "run_summary" }
        original = summaries.find { |event| event.dig("metadata", "run_id") == original_parent_run_id }
        actions = original.dig("metadata", "delegated_actions")
        assert(actions.count { |action| action["action"] == "agent_message_sent" && action["delivery_status"] == "queued" } == 1,
               "#{mode}: expected one persisted queued-send action")
        starts = actions.select { |action| action["action"] == "agent_started" }
        if mode == "same-run"
          assert(starts.map { |action| action["event_id"] } == [confirmed_id],
                 "expected one confirmed queued start in the saved and reloaded parent Summary")
          assert(actions.map { |action| action["action"] } == %w[agent_message_sent agent_started],
                 "expected the actual producers to record one send and one start, without replay duplicates")
        else
          assert(starts.empty?, "#{mode}: expected the completed original Summary to remain unchanged")
          later = summaries.find { |event| event.dig("metadata", "run_id") == restored.last_run.run_id }
          assert(later.dig("metadata", "delegated_actions").empty?, "#{mode}: stale queued work leaked into the later parent Summary")
        end
        assert(!JSON.generate(actions).include?("Queued private instruction"), "expected Summary actions to exclude prompt text")
      ensure
        pids&.each { |pid| stop_process(pid) }
        pids = nil
        previous_codex_bin ? ENV["TYCHO_CODEX_BIN"] = previous_codex_bin : ENV.delete("TYCHO_CODEX_BIN")
      end
    end
  end

  def assert_confirmed_starts_recover_before_parent_summary(modes: %w[confirmed-before-parent-exit stale-origin missing-exit-receipt])
    modes.each do |mode|
      with_queue_store do |registry, workspace|
        parent_workspace = File.join(workspace, "parent")
        FileUtils.mkdir_p(parent_workspace)
        harness = File.join(workspace, "recovery-codex")
        File.write(harness, <<~'RUBY')
          #!/usr/bin/env ruby
          require "json"
          gate = File.join(Dir.pwd, "#{ENV.fetch("TYCHO_RUN_ID")}.release")
          deadline = Time.now + 60
          sleep 0.01 until File.exist?(gate) || Time.now >= deadline
          payload = { "status" => "success", "summary" => "Finished gated work", "inquiry" => nil,
                      "attachments" => nil, "summary_sections" => nil, "memory_handoff" => nil }
          output_index = ARGV.index("-o")
          File.write(ARGV[output_index + 1], JSON.generate(payload)) if output_index
          puts JSON.generate("type" => "item.completed", "item" => { "type" => "agent_message", "text" => JSON.generate(payload) })
          puts JSON.generate("type" => "turn.completed")
        RUBY
        File.chmod(0o755, harness)
        previous_codex_bin = ENV["TYCHO_CODEX_BIN"]
        ENV["TYCHO_CODEX_BIN"] = harness
        store = HQ::AgentStore.new(registry.projects)
        parent = HQ::ManagedAgent.new(
          key: "recovery-parent", name: "Recovery parent", project_key: "web", template_key: "custom",
          workspace: parent_workspace, prompt: "Coordinate", log_path: File.join(parent_workspace, "parent.raw.log")
        )
        child = HQ::ManagedAgent.new(
          key: "recovery-child", name: "Recovery child", project_key: "web", template_key: "custom",
          workspace:, prompt: "Initial work", log_path: File.join(workspace, "child.raw.log")
        )
        store.associate_delegation!(agents: [parent, child], child:, parent_key: parent.key)
        store.save([parent, child])
        pids = []
        parent = store.start_agent!(parent.key)
        pids << parent.pid
        child = store.start_agent!(child.key)
        pids << child.pid
        initial_child_run_id = child.last_run.run_id
        parent_run_id = parent.last_run.run_id
        queued = store.accept_or_abort_prompt!(child.key, prompt: "Queued recovery work", start: true,
                                              actor: HQ::DelegationActor.parent_actor(parent.key), event_id: "recovery-send")
        assert(queued[:status] == :queued, "expected actual acceptance behind the gated busy child")
        parent_status_path = parent.send(:run_status_file_path, parent_run_id)
        exit_at = nil
        finish_parent = lambda do
          File.write(File.join(parent_workspace, "#{parent_run_id}.release"), "finish")
          deadline = Time.now + 10
          until File.file?(parent_status_path)
            raise "gated parent did not publish its exit status" if Time.now >= deadline

            sleep 0.01
          end
          exit_at = parent.run_exit_recorded_at
          assert(exit_at && exit_at <= File.mtime(parent_status_path), "expected an exit receipt written by the live native wrapper before status publication")
        end
        finish_parent.call if mode == "stale-origin"
        File.write(File.join(workspace, "#{initial_child_run_id}.release"), "finish")
        initial_status_path = child.send(:run_status_file_path, initial_child_run_id)
        deadline = Time.now + 10
        until File.file?(initial_status_path)
          raise "initial child did not publish its exit status" if Time.now >= deadline

          sleep 0.01
        end
        # Stop the Tycho owner after the real marker exists, before it can
        # acknowledge in memory, record the parent event, or save the ack.
        owner = Process.fork do
          original_ack = HQ::ManagedAgent.instance_method(:acknowledge_native_start!)
          HQ::ManagedAgent.define_method(:acknowledge_native_start!) do
            Process.exit!(86) if key == "recovery-child" && last_run.run_id != initial_child_run_id

            original_ack.bind_call(self)
          end
          store.load_with_poll_events(process_delegations: false)
          Process.exit!(87)
        end
        _waited, crashed = Process.wait2(owner)
        assert(crashed.exitstatus == 86, "expected interruption after the native marker and before ack persistence")
        records = HQ::FileStore.read_json(HQ::AGENTS_FILE, fallback: [])
        assert(records.map { |item| item["key"] } == [parent.key, child.key], "expected the parent-before-child recovery order")
        saved_child = HQ::ManagedAgent.from_hash(records.last)
        pids << saved_child.pid
        marker_path = saved_child.send(:run_native_started_file_path, saved_child.last_run.run_id)
        marker_at = File.mtime(marker_path)
        assert(File.read(marker_path).match?(/\A\d+\z/) && saved_child.staged_queue_delivery.is_a?(Hash) &&
               !saved_child.last_run.metadata["native_start_acknowledged"], "expected genuine durable marker evidence and an unacknowledged staged run")
        finish_parent.call unless mode == "stale-origin"
        FileUtils.rm_f(parent.send(:run_native_exit_file_path, parent_run_id)) if mode == "missing-exit-receipt"
        assert(mode == "stale-origin" ? exit_at < marker_at : marker_at < exit_at,
               "expected gated source marker ordering for #{mode}")
        assert(!HQ::ManagedAgent.from_hash(records.first).running?, "expected the original parent to finish before recovery")
        before = HQ::AgentMemory.new(parent).events.select { |event| event["type"] == "run_summary" }
        assert(before.length == (mode == "stale-origin" ? 1 : 0), "expected no prematurely finalized positive-control Summary")
        expected_id = "agent-start:#{child.key}:#{saved_child.last_run.run_id}"
        recovered_agents, = HQ::AgentStore.new(registry.projects).load_with_poll_events(process_delegations: false, dispatch_prompt_queues: false)
        recovered_child = recovered_agents.find { |agent| agent.key == child.key }
        assert(recovered_child.last_run.metadata["native_start_acknowledged"] == true &&
               recovered_child.staged_queue_delivery.nil? && recovered_child.run_count == 2 &&
               recovered_child.last_run.delegation_generation == saved_child.last_run.delegation_generation,
               "expected unchanged native acknowledgement, delivery, and generation recovery")
        first_summary = HQ::AgentMemory.new(parent).events.select { |event| event["type"] == "run_summary" }
        2.times { HQ::AgentStore.new(registry.projects).load_with_poll_events(process_delegations: false, dispatch_prompt_queues: false) }
        events = HQ::AgentMemory.new(parent).events
        assert(events.select { |event| event["type"] == "run_summary" } == first_summary,
               "expected repeated recovery to leave the first persisted Summary unchanged")
        summary = events.find { |event| event["type"] == "run_summary" && event.dig("metadata", "run_id") == parent_run_id }
        starts = summary.dig("metadata", "delegated_actions").select { |action| action["action"] == "agent_started" }
        puts "confirmed-start-recovery: #{JSON.generate(mode:, marker_at: marker_at.iso8601(9), parent_exit_at: exit_at.iso8601(9), starts: starts.length)}"
        if mode != "confirmed-before-parent-exit"
          assert(starts.empty? && events.none? { |event| event["event_id"] == expected_id }, "expected no guessed action for stale or missing exit evidence")
          if mode == "stale-origin"
            assert(events.select { |event| event["type"] == "run_summary" } == before, "expected the completed Summary to remain immutable")
          end
        else
          assert(starts.map { |action| action["event_id"] } == [expected_id], "expected one recovered start in the original immutable Summary")
          recovered_events = events.select { |event| event["event_id"] == expected_id }
          assert(recovered_events.length == 1 && recovered_events.first["created_at"] == marker_at.iso8601 &&
                 recovered_events.first.dig("metadata", "parent_run_id") == parent_run_id,
                 "expected one original-run event dated from the durable source marker after repeated recovery")
        end
      ensure
        Array(pids).compact.uniq.each do |pid|
          stop_process(pid)
          deadline = Time.now + 5
          loop do
            Process.kill(0, -pid)
            raise "recovery fixture process group did not exit" if Time.now >= deadline

            sleep 0.01
          rescue Errno::ESRCH, Errno::EPERM
            break
          end
        end
        [parent, child].compact.each do |agent|
          agent.instance_variable_get(:@process_monitors).to_h.each_value { |monitor| monitor.join(2) }
        end
        pids = nil
        previous_codex_bin ? ENV["TYCHO_CODEX_BIN"] = previous_codex_bin : ENV.delete("TYCHO_CODEX_BIN")
      end
    end
  end

  def assert_queue_persists_and_reconciles_across_clients
    with_queue_store do |registry, workspace|
      agent, pid = running_agent(workspace)
      HQ::AgentStore.new(registry.projects).save([agent])
      first = HQ::RemoteService.new(registry:)
      second = HQ::RemoteService.new(registry:)

      responses = 4.times.map do |index|
        Thread.new do
          service = index.even? ? first : second
          service.submit_prompt(
            agent.key,
            "prompt" => "queued #{index + 1}",
            "client_request_id" => "client-queue-test-#{index + 1}",
            "start" => true,
            "attachments" => index.zero? ? [{
              "filename" => "notes.txt",
              "mime_type" => "text/plain",
              "content_base64" => Base64.strict_encode64("queue attachment")
            }] : []
          )
        end
      end.map(&:value)

      assert(responses.all? { |response| response[:queued] }, "expected running submissions to enqueue")
      route_response = HQ::RemoteServer.allocate.send(
        :route, first, "POST", "/agents/#{agent.key}/messages",
        { "prompt" => "queued through HTTP", "start" => true }, nil
      )
      assert(route_response[:status] == 202 && route_response.dig(:body, :queued),
             "expected the running-agent API to acknowledge durable queue acceptance with HTTP 202")
      persisted = second.agent(agent.key).dig(:prompt_queue, "entries")
      assert(persisted.length == 5, "expected all clients to see five persisted queue entries")
      assert(persisted.map { |entry| entry["id"] }.grep(/\Aclient-queue-test-/).sort ==
             4.times.map { |index| "client-queue-test-#{index + 1}" },
             "expected client queue IDs to survive server acceptance for optimistic reconciliation")
      accepted = persisted.map { |entry| entry.fetch("accepted_at") }
      assert(accepted == accepted.sort, "expected server acceptance order to be stable")
      assert(persisted.flat_map { |entry| entry.fetch("attachments") }.any? { |item| item["title"] == "notes.txt" },
             "expected queued prompt attachments to persist")

      edited = first.edit_queued_prompt(agent.key, persisted[1].fetch("id"), "prompt" => "edited prompt")
      assert(edited.dig(:queue_entry, "prompt") == "edited prompt", "expected individual queue edits")
      first.delete_queued_prompt(agent.key, persisted[2].fetch("id"))
      reconciled = second.agent(agent.key).dig(:prompt_queue, "entries")
      assert(reconciled.length == 4 && reconciled.any? { |entry| entry["prompt"] == "edited prompt" },
             "expected edits and deletes to reconcile across clients")
    ensure
      stop_process(pid)
    end
  end

  def assert_delayed_remote_acceptance_is_durable
    with_queue_store do |registry, workspace|
      agent = terminal_agent(workspace)
      store = HQ::AgentStore.new(registry.projects)
      store.save([agent])

      result = HQ::RemoteService.new(registry:).submit_prompt(
        agent.key, "prompt" => "continue later", "delay" => 120, "start" => true
      )
      entry = result.fetch(:queue_entry)
      accepted = Time.parse(entry.fetch("accepted_at"))
      due = Time.parse(entry.fetch("not_before"))
      restarted = HQ::RemoteService.new(registry:).agent(agent.key)
      persisted = restarted.dig(:prompt_queue, "entries", 0)
      assert(result[:queued] && !result[:started] && due - accepted == 120 &&
             persisted["id"] == entry["id"] && persisted["not_before"] == entry["not_before"] &&
             restarted[:run_count] == 1,
             "expected remote delayed acceptance to persist exact timing without starting the stopped target")
    end
  end

  def assert_due_entries_bypass_future_entries_in_fifo_order
    with_queue_store do |registry, workspace|
      agent, pid = running_agent(workspace)
      now = Time.now
      agent.enqueue_prompt!(prompt: "future first", accepted_at: now, not_before: now + 600, id: "future")
      agent.enqueue_prompt!(prompt: "due second", accepted_at: now + 1, not_before: now - 1, id: "due-2")
      agent.enqueue_prompt!(prompt: "due third", accepted_at: now + 2, id: "due-3")
      store = HQ::AgentStore.new(registry.projects)
      store.save([agent])
      stop_process(pid)
      pid = nil

      with_stubbed_start { store.load }
      persisted = store.load_with_poll_events(process_delegations: false, dispatch_prompt_queues: false).first
                       .find { |candidate| candidate.key == agent.key }
      assert(persisted.active_queue_work["entries"].map { |entry| entry["id"] } == %w[due-2 due-3] &&
             persisted.prompt_queue.map { |entry| entry["id"] } == ["future"] && persisted.run_count == 2,
             "expected due entries to batch in acceptance order without future head-of-line blocking")
    ensure
      stop_process(pid)
    end
  end

  def assert_self_delayed_continuation_preserves_delegation_ownership
    with_queue_store do |registry, workspace|
      parent_workspace = File.join(workspace, "parent-self")
      FileUtils.mkdir_p(parent_workspace)
      parent = terminal_agent(parent_workspace)
      parent.instance_variable_set(:@key, "parent-self")
      child, pid = running_agent(workspace)
      store = HQ::AgentStore.new(registry.projects)
      store.save([parent, child])
      HQ::RemoteService.new(registry:).submit_prompt(
        child.key, "prompt" => "delegated setup", "parent_agent_key" => parent.key, "start" => true
      )
      before = store.delegation_coordinator.ownership_stamp(child.key)

      persisted, entry = store.enqueue_delayed_prompt_from!(
        child.key,
        prompt: "self continuation",
        actor: HQ::DelegationActor.internal_actor(child.key),
        delay: 60
      )
      after = store.delegation_coordinator.ownership_stamp(child.key)
      assert(before == after && entry["source"] == "internal_continuation" &&
             entry.dig("message_metadata", "message_author", "agent_key") == child.key &&
             persisted.queued_prompts.any? { |candidate| candidate["id"] == entry["id"] },
             "expected self continuation to preserve ownership generation and agent authorship")
    ensure
      stop_process(pid)
    end
  end

  def assert_claim_race_drains_fifo_without_overlap
    with_queue_store do |registry, workspace|
      agent, pid = running_agent(workspace)
      store = HQ::AgentStore.new(registry.projects)
      agent.enqueue_prompt!(prompt: "first accepted", source: "delegation_callback")
      agent.enqueue_prompt!(prompt: "second accepted", source: "user")
      store.save([agent])
      stop_process(pid)

      with_stubbed_start do
        services = [HQ::RemoteService.new(registry:), HQ::RemoteService.new(registry:)]
        2.times.map { |index| Thread.new { services[index].agent(agent.key) } }.each(&:value)
      end

      persisted = store.load.find { |candidate| candidate.key == agent.key }
      assert(persisted.run_count == 2,
             "expected all pending FIFO entries to start one consolidated follow-up run (runs=#{persisted.run_count})")
      assert(persisted.active_queue_work && persisted.active_queue_work["entries"].length == 2 &&
             persisted.queued_prompts.all? { |entry| entry["state"] == "in_progress" },
             "expected an accepted claim to remain as durable in-progress queue work")
      assert(persisted.last_run_from_prompt_queue?,
             "expected a queue-dispatched run to retain its queue provenance")
      queued_messages = HQ::AgentMemory.new(persisted).events.select do |event|
        event.dig("metadata", "prompt_queue_claim_id")
      end
      assert(queued_messages.length == 1 &&
             queued_messages.first.dig("metadata", "queue_read") == true &&
             queued_messages.first["content"].include?("TYCHO QUEUE WORK CONTRACT") &&
             queued_messages.first["content"].index("second accepted") <
               queued_messages.first["content"].index("first accepted") &&
             persisted.active_queue_work["entries"].map { |entry| entry["prompt"] } ==
               ["first accepted", "second accepted"],
             "expected instructions-first delivery with one FIFO-preserving canonical batch")
      assert(queued_messages.first.dig("metadata", "prompt_queue_sources") == {
               "delegation_callback" => 1, "user" => 1
             }, "expected automatic dispatch to preserve mixed queue source counts in one native input")
    end
  end

  def assert_pending_queue_visibility_tracks_processing_state
    with_queue_store do |registry, workspace|
      agent, pid = running_agent(workspace)
      agent.enqueue_prompt!(prompt: "pending before read", source: "user")
      store = HQ::AgentStore.new(registry.projects)
      store.save([agent])
      service = HQ::RemoteService.new(registry:)

      pending = service.agent(agent.key)
      assert(pending.dig(:prompt_queue, "entries").map { |entry| entry["prompt"] } == ["pending before read"] &&
             pending.dig(:prompt_queue, "pending_count") == 1,
             "expected unclaimed work to remain visible in the pending queue")

      claimed = store.load.find { |candidate| candidate.key == agent.key }
      batch = claimed.open_queue_work_batch!
      claimed.record_queue_read!(batch)
      store.save([claimed])
      processing = service.agent(agent.key)
      assert(processing.dig(:prompt_queue, "entries").empty? &&
             processing.dig(:prompt_queue, "pending_count").zero? &&
             processing.dig(:prompt_queue, "queue_work", "entry_ids") == [batch["entries"].first["id"]],
             "expected in-progress work to stay durable without duplicating the visible pending queue")

      stop_process(pid)
      pid = nil
      failed_agent = store.load.find { |candidate| candidate.key == agent.key }
      failed_at = Time.now
      failed_agent.instance_variable_set(:@pid, nil)
      failed_agent.instance_variable_set(:@finished_at, failed_at)
      failed_agent.instance_variable_set(:@last_exit_code, 1)
      failed_agent.instance_variable_set(:@structured_result, {
        "status" => "failed", "summary" => "Queue processing failed"
      })
      failed_agent.last_run.finished_at = failed_at
      failed_agent.last_run.exit_code = 1
      failed_agent.last_run.status = "failed"
      store.save([failed_agent])
      failed = service.agent(agent.key)
      assert(failed[:status] == "failed" &&
             failed.dig(:prompt_queue, "entries").map { |entry| entry["prompt"] } == ["pending before read"] &&
             failed.dig(:prompt_queue, "pending_count") == 1,
             "expected unresolved queue work to become visible as soon as processing fails")
    ensure
      stop_process(pid)
    end
  end

  def assert_result_statuses_apply_queue_release_policy
    %w[failed blocked input_required].each do |result_status|
      with_queue_store do |registry, workspace|
        agent = terminal_agent(workspace, status: result_status, structured_result: {
          "status" => result_status, "summary" => "Queue processing ended as #{result_status}"
        })
        agent.enqueue_prompt!(prompt: "first queued instruction", source: "user", id: "first-entry")
        agent.enqueue_prompt!(prompt: "second queued instruction", source: "user", id: "second-entry")
        batch = agent.open_queue_work_batch!
        agent.record_queue_read!(batch)
        agent.send(:gate_successful_queue_work!, agent.last_run)
        HQ::AgentStore.new(registry.projects).save([agent])

        payload = HQ::RemoteService.new(registry:).agent(agent.key).fetch(:prompt_queue)
        visible_entries = payload.fetch("entries")
        assert(payload["unprocessed_reason"] == "queue not processed since state is #{result_status}" &&
               visible_entries.map { |entry| entry["id"] } == %w[first-entry second-entry] &&
               visible_entries.all? { |entry| entry["state"] == result_status } &&
               payload.dig("queue_work", "state") == "in_progress" &&
               payload.dig("queue_work", "unresolved_entry_ids") == %w[first-entry second-entry],
               "expected #{result_status} to preserve FIFO queue work with an exact result explanation")
      end
    end

    %w[success no_action_needed partial].each do |result_status|
      with_queue_store do |registry, workspace|
        agent = terminal_agent(workspace, status: result_status, structured_result: {
          "status" => result_status, "summary" => "Queue processed"
        })
        agent.enqueue_prompt!(prompt: "completed instruction", source: "user", id: "completed-entry")
        batch = agent.open_queue_work_batch!
        agent.record_queue_read!(batch)
        agent.send(:gate_successful_queue_work!, agent.last_run)
        HQ::AgentStore.new(registry.projects).save([agent])

        payload = HQ::RemoteService.new(registry:).agent(agent.key).fetch(:prompt_queue)
        assert(payload.fetch("entries").empty? && payload["pending_count"].zero? &&
               payload["unprocessed_reason"].nil? && payload.dig("queue_work", "state") == "resolved" &&
               payload.dig("queue_work", "unresolved_entry_ids").empty?,
               "expected #{result_status} to auto-complete delivered queue work")
      end
    end
  end

  def assert_partial_release_matrix_preserves_fifo_and_later_work
    cases = {
      "ordinary" => [["ordinary-first", "user", nil], ["ordinary-second", "user", nil]],
      "delayed" => [["delayed-first", "user", Time.now - 2], ["delayed-second", "user", Time.now - 1]],
      "delegated" => [["delegated-first", "delegation_callback", nil],
                      ["delegated-second", "delegation_callback", nil]],
      "mixed" => [["mixed-user", "user", nil], ["mixed-report", "delegation_callback", nil],
                  ["mixed-later", "user", nil]]
    }

    cases.each do |name, entries|
      with_queue_store do |registry, workspace|
        agent = terminal_agent(workspace, status: "partial", structured_result: {
          "status" => "partial", "summary" => "Partial progress"
        })
        first_entries = name == "mixed" ? entries.first(2) : entries.first(1)
        later_entries = entries.drop(first_entries.length)
        first_entries.each do |id, source, not_before|
          agent.enqueue_prompt!(prompt: id, id:, source:, not_before:)
        end
        first_batch = agent.open_queue_work_batch!
        agent.record_queue_read!(first_batch)
        later_entries.each do |id, source, not_before|
          agent.enqueue_prompt!(prompt: id, id:, source:, not_before:)
        end

        agent.send(:gate_successful_queue_work!, agent.last_run)
        resolved_first = agent.queue_work_batch(first_batch["id"])
        assert(agent.effective_status == "partial" && resolved_first["state"] == "resolved" &&
               resolved_first["entries"].map { |entry| entry["id"] } == first_entries.map(&:first) &&
               resolved_first["dispositions"].values.map { |item| item["outcome"] } ==
                 first_entries.map { |_id, source, _due| source == "delegation_callback" ? "incorporated" : "completed" } &&
               agent.queued_prompts.map { |entry| entry["id"] } == later_entries.map(&:first) &&
               agent.prompt_queue_dispatchable?,
               "expected partial #{name} work to resolve with stable FIFO IDs and release later work")

        store = HQ::AgentStore.new(registry.projects)
        store.save([agent])
        with_stubbed_start { store.load }
        later_run = store.load_with_poll_events(process_delegations: false, dispatch_prompt_queues: false).first
                         .find { |candidate| candidate.key == agent.key }
        later_batch = later_run.active_queue_work
        assert(later_batch && later_batch["entries"].map { |entry| entry["id"] } == later_entries.map(&:first),
               "expected later #{name} work to dispatch in FIFO order after partial")

        later_run.structured_result = { "status" => "success", "summary" => "Later work completed" }
        later_run.send(:gate_successful_queue_work!, later_run.last_run)
        resolved_later = later_run.queue_work_batch(later_batch["id"])
        assert(resolved_later["state"] == "resolved" && later_run.active_queue_work.nil? &&
               resolved_later["entries"].map { |entry| entry["id"] } == later_entries.map(&:first),
               "expected later successful #{name} work to resolve without duplicate delivery")
      end
    end
  end

  def assert_terminal_partial_run_dispatches_pending_work_once
    cases = {
      "user" => [["user-first", "user"], ["user-second", "user"]],
      "delegated" => [["delegated-result", "delegation_callback"]],
      "mixed" => [["mixed-user-first", "user"], ["mixed-result", "delegation_callback"],
                  ["mixed-user-last", "user"]]
    }

    cases.each do |name, entries|
      with_queue_store do |registry, workspace|
        previous_codex_bin = ENV["TYCHO_CODEX_BIN"]
        gate = File.join(workspace, "release-first-run")
        capture = File.join(workspace, "native-inputs.jsonl")
        count = File.join(workspace, "run-count")
        harness = File.join(workspace, "partial-codex")
        File.write(harness, <<~RUBY)
          #!/usr/bin/env ruby
          require "json"
          count_path = #{count.to_json}
          run_number = (File.exist?(count_path) ? File.read(count_path).to_i : 0) + 1
          File.write(count_path, run_number.to_s)
          File.open(#{capture.to_json}, "a") { |file| file.puts JSON.generate(ARGV) }
          File.write(#{File.join(workspace, 'first-run-ready').to_json}, "ready") if run_number == 1
          deadline = Time.now + 20
          sleep 0.01 until run_number != 1 || File.exist?(#{gate.to_json}) || Time.now >= deadline
          raise "first-run gate timed out" if run_number == 1 && !File.exist?(#{gate.to_json})
          result = if run_number == 1
                     { "status" => "partial", "summary" => "Some requested work remains",
                       "summary_sections" => nil, "inquiry" => nil, "attachments" => nil,
                       "memory_handoff" => nil }
                   else
                     { "status" => "success", "summary" => "Processed queued work",
                       "summary_sections" => nil, "inquiry" => nil, "attachments" => nil,
                       "memory_handoff" => nil }
                   end
          output_index = ARGV.index("-o")
          File.write(ARGV[output_index + 1], JSON.generate(result)) if output_index
          puts JSON.generate("type" => "item.completed", "item" => {
            "type" => "agent_message", "text" => JSON.generate(result)
          })
          puts JSON.generate("type" => "turn.completed", "session_id" => "partial-queue-session")
        RUBY
        FileUtils.chmod(0o755, harness)
        ENV["TYCHO_CODEX_BIN"] = harness

        agent = terminal_agent(workspace, structured_result: {
          "status" => "success", "summary" => "Initial work completed"
        })
        agent.enqueue_prompt!(prompt: "first-batch-instruction", id: "first-batch-instruction", source: "user")
        store = HQ::AgentStore.new(registry.projects)
        store.save([agent])
        first = store.load_with_poll_events(process_delegations: false).first.first
        ready_deadline = Time.now + 5
        sleep 0.01 until File.exist?(File.join(workspace, "first-run-ready")) || Time.now >= ready_deadline
        assert(File.exist?(File.join(workspace, "first-run-ready")) && first.running?,
               "expected #{name} fixture's real queue-dispatched harness run to be active")
        first_batch_id = first.active_queue_work.fetch("id")

        entries.each do |id, source|
          store.enqueue_prompt!(agent.key, prompt: id, id:, source:)
        end
        store.enqueue_prompt_from!(agent.key, prompt: "future-entry", id: "future-entry", source: "user",
                                   actor: HQ::DelegationActor.user_actor, not_before: Time.now + 3600)
        File.write(gate, "continue")

        dispatched = nil
        deadline = Time.now + 10
        until Time.now >= deadline
          dispatched = store.load_with_poll_events(process_delegations: false).first
                           .find { |candidate| candidate.key == agent.key }
          break if dispatched.run_count == 3

          sleep 0.01
        end
        assert(dispatched&.run_count == 3 && dispatched.last_run.metadata["prompt_queue_claim_id"],
               "expected #{name} Partial queue run to dispatch a real successor run; " \
               "runs=#{dispatched&.run_count}, status=#{dispatched&.status}, " \
               "last=#{dispatched&.last_run&.status}, queued=#{dispatched&.prompt_queue&.map { |entry| entry['id'] }}, " \
               "summary=#{dispatched&.last_summary.inspect}, exit=#{dispatched&.last_exit_code}, " \
               "dispatch_error=#{dispatched&.prompt_queue_dispatch_error.inspect}")
        first_terminal = dispatched.runs[-2]
        batch = dispatched.active_queue_work
        settled_batch = dispatched.queue_work_batch(first_batch_id)
        partial_summary = HQ::AgentMemory.new(dispatched).events.find do |event|
          event["type"] == "run_summary" && event.dig("metadata", "run_id") == first_terminal.run_id
        end
        assert(first_terminal.status == "partial" &&
               first_terminal.metadata["queue_work_auto_completed"] == true &&
               partial_summary&.fetch("content", "").include?("Some requested work remains") &&
               settled_batch.fetch("state") == "resolved" && batch &&
               settled_batch.dig("dispositions", "first-batch-instruction", "outcome") == "completed" &&
               batch.fetch("entries").map { |entry| entry["id"] } == entries.map(&:first) &&
               batch.fetch("entries").map { |entry| entry["source"] } == entries.map(&:last) &&
               dispatched.prompt_queue.map { |entry| entry["id"] } == ["future-entry"],
               "expected #{name} dispatch to preserve Partial, FIFO source data, and future eligibility")

        wait_for_agent_process(dispatched)
        replay = HQ::AgentStore.new(registry.projects)
        finished = replay.load_with_poll_events(process_delegations: false).first.find { |candidate| candidate.key == agent.key }
        2.times { replay.load_with_poll_events(process_delegations: false) }
        finished = replay.load_with_poll_events(process_delegations: false).first.find { |candidate| candidate.key == agent.key }
        arguments = File.readlines(capture).map { |line| JSON.parse(line) }
        read_events = HQ::AgentMemory.new(finished).events.select { |event| event.dig("metadata", "queue_read") == true }
        resolved = finished.queue_work_batch(batch.fetch("id"))
        expected_dispositions = entries.to_h do |id, source|
          [id, source == "delegation_callback" ? "incorporated" : "completed"]
        end
        actual_dispositions = resolved.fetch("dispositions").transform_values { |item| item["outcome"] }
        assert(finished.run_count == 3 && finished.session_id == "partial-queue-session" &&
               arguments.length == 2 && arguments.last.join(" ").include?("TYCHO QUEUE WORK CONTRACT") &&
               arguments.last.include?("partial-queue-session") &&
               entries.all? { |id, _source| arguments.last.join(" ").include?(id) } &&
               !arguments.last.join(" ").include?("future-entry") && read_events.length == 2 &&
               resolved.fetch("state") == "resolved" && actual_dispositions == expected_dispositions &&
               finished.prompt_queue.map { |entry| entry["id"] } == ["future-entry"],
               "expected #{name} restart/replay to keep both batches resolved once and one future entry; " \
               "runs=#{finished.run_count}, session=#{finished.session_id.inspect}, captures=#{arguments.length}, " \
               "reads=#{read_events.length}, batch=#{resolved['state']}, " \
               "pending=#{finished.prompt_queue.map { |entry| entry['id'] }}")
      ensure
        previous_codex_bin ? ENV["TYCHO_CODEX_BIN"] = previous_codex_bin : ENV.delete("TYCHO_CODEX_BIN")
      end
    end
  end

  def assert_input_required_terminal_result_keeps_pending_work_gated
    %w[input_required].each do |status|
      with_queue_store do |registry, workspace|
        previous_codex_bin = ENV["TYCHO_CODEX_BIN"]
        gate = File.join(workspace, "release-first-run")
        harness = File.join(workspace, "terminal-codex")
        File.write(harness, <<~RUBY)
          #!/usr/bin/env ruby
          require "json"
          File.write(#{File.join(workspace, 'first-run-ready').to_json}, "ready")
          deadline = Time.now + 20
          sleep 0.01 until File.exist?(#{gate.to_json}) || Time.now >= deadline
          raise "first-run gate timed out" unless File.exist?(#{gate.to_json})
          inquiry = #{status.to_json} == "input_required" ? { "message" => "Need an operator answer", "fields" => [] } : nil
          result = { "status" => #{status.to_json}, "summary" => "The run needs operator attention",
                     "summary_sections" => nil, "inquiry" => inquiry, "attachments" => nil,
                     "memory_handoff" => nil }
          output_index = ARGV.index("-o")
          File.write(ARGV[output_index + 1], JSON.generate(result)) if output_index
          puts JSON.generate("type" => "item.completed", "item" => {
            "type" => "agent_message", "text" => JSON.generate(result)
          })
          puts JSON.generate("type" => "turn.completed")
        RUBY
        FileUtils.chmod(0o755, harness)
        ENV["TYCHO_CODEX_BIN"] = harness
        agent = HQ::ManagedAgent.new(
          key: "queue-agent", name: "Queue agent", project_key: "web", template_key: "custom",
          workspace:, prompt: "Initial work", agent: "codex", log_path: File.join(workspace, "raw.log")
        )
        store = HQ::AgentStore.new(registry.projects)
        store.save([agent])
        store.start_agent!(agent.key)
        ready_deadline = Time.now + 5
        sleep 0.01 until File.exist?(File.join(workspace, "first-run-ready")) || Time.now >= ready_deadline
        store.enqueue_prompt!(agent.key, prompt: "Pending user instruction", id: "pending-user", source: "user")
        File.write(gate, "continue")

        terminal = nil
        deadline = Time.now + 10
        until Time.now >= deadline
          terminal = store.load_with_poll_events(process_delegations: false).first.first
          break unless terminal.running?

          sleep 0.01
        end
        assert(terminal && !terminal.running? && terminal.run_count == 1 && terminal.effective_status == status &&
               terminal.prompt_queue.map { |entry| entry["id"] } == ["pending-user"] &&
               terminal.active_queue_work.nil?,
               "expected #{status} terminal result to retain pending work without automatic dispatch; " \
               "status=#{terminal&.status}, result=#{terminal&.structured_result.inspect}, " \
               "queue=#{terminal&.prompt_queue&.map { |entry| entry['id'] }}")
      ensure
        previous_codex_bin ? ENV["TYCHO_CODEX_BIN"] = previous_codex_bin : ENV.delete("TYCHO_CODEX_BIN")
      end
    end
  end

  def assert_selected_processing_preserves_fifo_and_prevents_duplicate_dispatch
    with_queue_store do |registry, workspace|
      agent = terminal_agent(workspace, status: "blocked", structured_result: {
        "status" => "blocked", "summary" => "Waiting for operator"
      })
      %w[first second third].each_with_index do |name, index|
        agent.enqueue_prompt!(prompt: name, source: "user", id: "entry-#{index + 1}", accepted_at: Time.now + index)
      end
      store = HQ::AgentStore.new(registry.projects)
      store.save([agent])
      prompts = []

      result = nil
      with_stubbed_start(prompts:) do
        result = store.process_prompt_queue_entries!(
          agent.key, entry_ids: %w[entry-3 entry-1], expected_entry_ids: %w[entry-1 entry-2 entry-3]
        )
      end
      persisted = store.load_with_poll_events(process_delegations: false, dispatch_prompt_queues: false).first.first
      batch = persisted.active_queue_work
      assert(result.fetch("status") == "accepted" && result.fetch("processed_entry_ids") == %w[entry-3 entry-1] &&
             prompts.length == 1 && prompts.first.index("[entry-1]") < prompts.first.index("[entry-3]") &&
             batch["entries"].map { |entry| entry["id"] } == %w[entry-1 entry-3] &&
             persisted.visible_prompt_queue_entries.map { |entry| entry["id"] } == %w[entry-1 entry-2 entry-3],
             "expected selected processing to dispatch once in canonical FIFO while preserving unselected order")

      stale = store.process_prompt_queue_entries!(
        agent.key, entry_ids: ["entry-1"], expected_entry_ids: %w[entry-1 entry-2 entry-3 missing]
      )
      assert(stale.fetch("status") == "stale" && stale.fetch("processed_entry_ids").empty? && prompts.length == 1,
             "expected a stale selected-process snapshot not to dispatch a duplicate run")
    end
  end

  def assert_bulk_removal_is_audited_and_stale_snapshots_do_nothing
    with_queue_store do |registry, workspace|
      agent = terminal_agent(workspace, status: "failed", structured_result: {
        "status" => "failed", "summary" => "Queue failed"
      })
      agent.enqueue_prompt!(prompt: "active user", source: "user", id: "active-user")
      agent.enqueue_prompt!(prompt: "active report", source: "delegation_callback", id: "active-report")
      batch = agent.open_queue_work_batch!
      agent.record_queue_read!(batch)
      agent.enqueue_prompt!(prompt: "newer user", source: "user", id: "newer-user")
      store = HQ::AgentStore.new(registry.projects)
      store.save([agent])

      stale = store.remove_prompt_queue_entries!(
        agent.key, entry_ids: ["active-user"], expected_entry_ids: %w[active-user active-report]
      )
      after_stale = store.load_with_poll_events(process_delegations: false, dispatch_prompt_queues: false).first.first
      assert(stale.fetch("status") == "stale" && after_stale.visible_prompt_queue_entries.map { |entry| entry["id"] } ==
             %w[active-user active-report newer-user],
             "expected stale destructive snapshots to leave every queue entry intact")

      removed = store.remove_prompt_queue_entries!(
        agent.key, entry_ids: %w[active-user active-report newer-user],
        expected_entry_ids: %w[active-user active-report newer-user], reason: "Operator confirmed removal of 3 entries"
      )
      persisted = store.load_with_poll_events(process_delegations: false, dispatch_prompt_queues: false).first.first
      dispositions = persisted.queue_work.fetch("batches").flat_map do |stored_batch|
        stored_batch.fetch("dispositions", {}).values
      end
      assert(removed.fetch("status") == "removed" && removed.fetch("removed_entry_ids").length == 3 &&
             persisted.visible_prompt_queue_entries.empty? && dispositions.map { |item| item["entry_id"] }.sort ==
             %w[active-report active-user newer-user] &&
             dispositions.find { |item| item["entry_id"] == "active-report" }.fetch("outcome") == "superseded_with_reason" &&
             dispositions.all? { |item| item["reason"] == "Operator confirmed removal of 3 entries" },
             "expected bulk removal to preserve source-appropriate durable audit dispositions")
    end
  end

  def assert_stale_selected_process_preserves_inquiry
    with_queue_store do |registry, workspace|
      inquiry = { "message" => "Choose a release target", "fields" => [] }
      agent = terminal_agent(workspace, status: "input_required", structured_result: {
        "status" => "input_required", "summary" => "Needs input", "inquiry" => inquiry
      })
      memory = HQ::AgentMemory.new(agent)
      memory.append_inquiry_request!(inquiry, inquiry_id: "atomic-stale-inquiry")
      agent.enqueue_prompt!(prompt: "keep queued", id: "inquiry-entry")
      store = HQ::AgentStore.new(registry.projects)
      store.save([agent])

      stale = store.process_prompt_queue_entries!(
        agent.key, entry_ids: ["inquiry-entry"], expected_entry_ids: %w[inquiry-entry missing]
      )
      selection_error = begin
        store.process_prompt_queue_entries!(
          agent.key, entry_ids: ["missing"], expected_entry_ids: ["inquiry-entry"]
        )
        nil
      rescue ArgumentError => e
        e
      end
      persisted = store.load_with_poll_events(process_delegations: false, dispatch_prompt_queues: false).first.first
      events = HQ::AgentMemory.new(persisted).events

      assert(stale.fetch("status") == "stale" && stale.fetch("processed_entry_ids").empty? &&
             selection_error&.message&.include?("missing: missing") &&
             persisted.latest_inquiry_id == "atomic-stale-inquiry" &&
             events.none? { |event| event["type"] == "inquiry_cancelled" } &&
             persisted.visible_prompt_queue_entries.map { |entry| entry["id"] } == ["inquiry-entry"],
             "expected stale snapshots and invalid selections to preserve the active inquiry and queue")
    end
  end

  def assert_queue_action_routes_report_stale_and_selected_results
    with_queue_store do |registry, workspace|
      agent = terminal_agent(workspace, status: "input_required", structured_result: {
        "status" => "input_required", "summary" => "Needs input"
      })
      agent.enqueue_prompt!(prompt: "remove me", id: "route-1")
      agent.enqueue_prompt!(prompt: "keep me", id: "route-2")
      store = HQ::AgentStore.new(registry.projects)
      store.save([agent])
      service = HQ::RemoteService.new(registry:)

      stale = HQ::RemoteServer.allocate.send(
        :route, service, "POST", "/agents/#{agent.key}/prompt-queue/remove",
        { "entry_ids" => ["route-1"], "expected_entry_ids" => ["route-1"] }, nil
      )
      removed = HQ::RemoteServer.allocate.send(
        :route, service, "POST", "/agents/#{agent.key}/prompt-queue/remove",
        { "entry_ids" => ["route-1"], "expected_entry_ids" => %w[route-1 route-2] }, nil
      )
      assert(stale.fetch(:status) == 200 && stale.dig(:body, "status") == "stale" &&
             removed.fetch(:status) == 200 && removed.dig(:body, "status") == "removed" &&
             removed.dig(:body, "removed_entry_ids") == ["route-1"] &&
             removed.dig(:body, :agent, :prompt_queue, "entries").map { |entry| entry["id"] } == ["route-2"],
             "expected queue action APIs to expose stale no-ops and stable-ID selected removal")
    end
  end

  def assert_automatic_dispatch_records_one_structured_read_block
    cases = {
      "user" => [["required user instruction", "user"]],
      "delegated" => [["delegated result", "delegation_callback"]],
      "mixed" => [["required mixed instruction", "user"], ["mixed delegated result", "delegation_callback"]]
    }
    cases.each do |name, entries|
      with_queue_store do |registry, workspace|
        attachment = {
          "type" => "link", "title" => "Queue context", "url" => "https://example.test/queue-context",
          "description" => "Canonical queue attachment", "source" => "user"
        }
        agent = terminal_agent(workspace)
        entries.each_with_index do |(prompt, source), index|
          agent.enqueue_prompt!(prompt:, source:, attachments: name == "mixed" && index.zero? ? [attachment] : [])
        end
        store = HQ::AgentStore.new(registry.projects)
        store.save([agent])
        service = HQ::RemoteService.new(registry:)

        with_stubbed_start { service.agent(agent.key) }
        persisted = store.load_with_poll_events(process_delegations: false, dispatch_prompt_queues: false).first
                         .find { |candidate| candidate.key == agent.key }
        claim_events = HQ::AgentMemory.new(persisted).events.select do |event|
          event.dig("metadata", "prompt_queue_claim_id")
        end
        read_events = claim_events.select { |event| event.dig("metadata", "queue_read") == true }
        conversation = service.conversation(agent.key)
        block = conversation.find { |candidate| candidate.dig(:metadata, "queue_read") == true }
        expected_prompts = entries.map(&:first)
        raw_duplicate = conversation.any? do |candidate|
          candidate.dig(:metadata, "prompt_queue_claim_id") && candidate.dig(:metadata, "queue_read") != true
        end
        assert(claim_events.length == 1 && read_events.length == 1 && block && !raw_duplicate &&
               read_events.first.dig("metadata", "prompt_queue_entries").map { |entry| entry["prompt"] } == expected_prompts &&
               read_events.first.dig("metadata", "queue_work_state") == "in_progress" &&
               block[:content].include?("TYCHO QUEUE WORK CONTRACT"),
               "expected #{name} automatic dispatch to persist one structured Read queue block without a raw duplicate")
        if name == "mixed"
          recorded_attachment = read_events.first.dig("metadata", "attachments", 0)
          assert(recorded_attachment &&
                 HQ::AttachmentNormalizer.attachment_target(recorded_attachment) == attachment["url"] &&
                 recorded_attachment["description"] == attachment["description"],
                 "expected automatic dispatch to reuse canonical queue attachment projection")
        end

        repeated = store.read_prompt_queue!(agent.key)
        after_read = HQ::AgentMemory.new(store.load.find { |candidate| candidate.key == agent.key }).events.count do |event|
          event.dig("metadata", "queue_read") == true
        end
        assert(repeated[:idempotent] && after_read == 1,
               "expected an explicit read after #{name} automatic dispatch to reuse the same block")

        dispositions = repeated[:entries].map do |entry|
          outcome = entry["source"] == "delegation_callback" ? "incorporated" : "completed"
          { "entry_id" => entry["id"], "outcome" => outcome }
        end
        store.complete_queue_work!(agent.key, batch_id: repeated.dig(:batch, "batch_id"), dispositions:)
        resolved = service.conversation(agent.key).find { |candidate| candidate.dig(:metadata, "queue_read") == true }
        assert(resolved.dig(:metadata, "queue_work_state") == "resolved" &&
               resolved.dig(:metadata, "queue_work_dispositions").length == entries.length,
               "expected the #{name} automatic Read queue block to project resolved completion metadata")
      end
    end
  end

  def assert_dispatch_failure_retains_one_prepared_batch_for_retry
    with_queue_store do |registry, workspace|
      agent, pid = running_agent(workspace)
      agent.enqueue_prompt!(prompt: "retain me")
      store = HQ::AgentStore.new(registry.projects)
      store.save([agent])
      stop_process(pid)
      service = HQ::RemoteService.new(registry:)

      with_stubbed_start(error: "temporary launch failure") { service.agent(agent.key) }
      failed = service.agent(agent.key)
      assert(failed.dig(:prompt_queue, "entries", 0, "state") == "failed",
             "expected failed dispatch entries to remain visible")
      assert(failed.dig(:prompt_queue, "dispatch_error", "message").include?("Retry queue"),
             "expected retry guidance after dispatch failure")
      failed_agent = store.load.find { |candidate| candidate.key == agent.key }
      assert(failed_agent.send(:prompt_for_execution).include?("retain me"),
             "expected retries to execute the retained claim instead of continuing past it")

      before = queued_memory_events(agent.key, store).length
      with_stubbed_start { service.retry_prompt_queue(agent.key) }
      persisted = store.load.find { |candidate| candidate.key == agent.key }
      after = queued_memory_events(agent.key, store).length
      assert(before.zero? && after == 1,
             "expected failed spawn to record no read and successful retry to record one ordinary prompt")
      assert(persisted.active_queue_work && persisted.run_count == 2,
             "expected a successful retry to accept one run while retaining the open batch")
    end
  end

  def assert_resolved_failed_claim_reconciles_and_drains_newer_fifo_work
    with_queue_store do |registry, workspace|
      agent = terminal_agent(workspace)
      agent.enqueue_prompt!(prompt: "failed first", id: "failed-first")
      store = HQ::AgentStore.new(registry.projects)
      store.save([agent])
      service = HQ::RemoteService.new(registry:)

      with_stubbed_start(error: "spawn failed after claim persistence") { service.agent(agent.key) }
      failed = store.load_with_poll_events(process_delegations: false, dispatch_prompt_queues: false).first.first
      failed.enqueue_prompt!(prompt: "newer second", id: "newer-second")
      store.save([failed])

      inspected = service.read_prompt_queue(agent.key)
      status = service.agent(agent.key)
      assert(!inspected[:idempotent] && inspected[:entries].map { |entry| entry["id"] } == ["failed-first"] &&
             status.dig(:prompt_queue, "entries").map { |entry| entry["id"] } == %w[failed-first newer-second],
             "expected a failed claim and newer FIFO entries to remain inspectable")

      completion = store.complete_queue_work!(
        agent.key,
        batch_id: inspected.dig(:batch, "batch_id"),
        dispositions: [{ "entry_id" => "failed-first", "outcome" => "completed" }]
      )
      reconciled = completion.fetch("agent")
      assert(reconciled.prompt_queue_claim.nil? && reconciled.prompt_queue_dispatch_error.nil?,
             "expected resolving queue work to retire its matching failed claim and dispatch error")

      before_runs = reconciled.run_count
      prompts = []
      with_stubbed_start(prompts:) { service.agent(agent.key) }
      drained = store.load_with_poll_events(process_delegations: false, dispatch_prompt_queues: false).first.first
      reads = HQ::AgentMemory.new(drained).events.select { |event| event.dig("metadata", "queue_read") == true }
      includes_newer = prompts.first&.include?("newer second")
      includes_older = prompts.first&.include?("failed first")
      assert(drained.run_count == before_runs + 1 && prompts.one? && prompts.first.include?("newer second") &&
             !prompts.first.include?("failed first") && reads.length == 2,
             "expected resolved failed work not to replay and the newer entry to dispatch exactly once: " \
             "runs=#{drained.run_count}/#{before_runs + 1}, prompts=#{prompts.length}, " \
             "newer=#{includes_newer}, older=#{includes_older}, reads=#{reads.length}")
    end
  end

  def assert_failed_claim_can_be_discarded_except_for_delegation_callbacks
    with_queue_store do |registry, workspace|
      agent = terminal_agent(workspace)
      agent.enqueue_prompt!(prompt: "discard me", id: "discard-me", source: "sleep_circuit_breaker_recovery")
      store = HQ::AgentStore.new(registry.projects)
      store.save([agent])
      service = HQ::RemoteService.new(registry:)
      with_stubbed_start(error: "temporary launch failure") { service.agent(agent.key) }

      response = HQ::RemoteServer.allocate.send(
        :route, service, "POST", "/agents/#{agent.key}/prompt-queue/discard",
        { "reason" => "obsolete recovery" }, nil
      )
      result = response.fetch(:body)
      batch = result.fetch(:batch)
      persisted = store.load_with_poll_events(process_delegations: false, dispatch_prompt_queues: false).first.first
      assert(response.fetch(:status) == 200 && result.fetch(:discarded) && batch.fetch("state") == "resolved" &&
             batch.dig("dispositions", "discard-me", "outcome") == "declined_with_reason" &&
             batch.dig("dispositions", "discard-me", "reason") == "obsolete recovery" &&
             persisted.prompt_queue_claim.nil?,
             "expected the Remote discard route to record an allowed failed-work disposition")
    end

    with_queue_store do |registry, workspace|
      agent = terminal_agent(workspace)
      agent.enqueue_prompt!(prompt: "protected callback", id: "protected", source: "delegation_callback")
      store = HQ::AgentStore.new(registry.projects)
      store.save([agent])
      service = HQ::RemoteService.new(registry:)
      with_stubbed_start(error: "temporary launch failure") { service.agent(agent.key) }

      error = begin
        store.discard_prompt_queue!(agent.key)
        nil
      rescue ArgumentError => e
        e
      end
      retained = store.load_with_poll_events(process_delegations: false, dispatch_prompt_queues: false).first.first
      assert(error&.message&.include?("Delegated replies cannot be discarded") && retained.prompt_queue_claim &&
             retained.prompt_queue_dispatch_error,
             "expected protected delegation callbacks to reject discard and remain retryable")
    end
  end

  def assert_loaded_resolved_claim_reconciles_after_later_successful_runs
    with_queue_store do |_registry, workspace|
      agent = terminal_agent(workspace)
      agent.enqueue_prompt!(prompt: "already handled", id: "handled")
      claim = agent.claim_pending_prompts!
      batch = agent.queue_work_batch(claim.fetch("id"))
      agent.prepare_prompt_queue_claim!
      agent.fail_prompt_queue_dispatch!("old dispatch failure")
      agent.complete_queue_work!(batch.fetch("id"), [
                                   { "entry_id" => "handled", "outcome" => "completed" }
                                 ])
      stale = agent.to_hash
      stale["prompt_queue_claim"] = {
        "id" => batch.fetch("id"), "entries" => batch.fetch("entries"),
        "claimed_at" => Time.now.utc.iso8601(6), "baseline_run_count" => 2, "message_appended" => true
      }
      stale["prompt_queue_dispatch_error"] = {
        "message" => "old dispatch failure", "failed_at" => Time.now.utc.iso8601(6), "retryable" => true
      }
      4.times do
        now = Time.now
        stale.fetch("runs") << HQ::ManagedAgent::AgentRun.new(
          started_at: now, finished_at: now, exit_code: 0, status: "success",
          log_path: File.join(workspace, "raw.log")
        ).to_h
      end

      reconciled = HQ::ManagedAgent.from_hash(stale)
      assert(reconciled.run_count >= 5 && reconciled.queue_work_batch(batch.fetch("id"))["state"] == "resolved" &&
             reconciled.prompt_queue_claim.nil? && reconciled.prompt_queue_dispatch_error.nil?,
             "expected persisted resolved claims to reconcile even after later successful runs")
    end
  end

  def assert_active_and_restorable_inquiries_block_dispatch
    with_queue_store do |registry, workspace|
      inquiry = {
        "message" => "Choose a path",
        "fields" => [{ "key" => "path", "label" => "Path", "input_type" => "text" }]
      }
      agent = terminal_agent(workspace, status: "input_required", structured_result: {
        "status" => "input_required", "summary" => "Need input", "inquiry" => inquiry
      })
      memory = HQ::AgentMemory.new(agent)
      memory.append_inquiry_request!(inquiry, inquiry_id: "inquiry-queue-test")
      agent.enqueue_prompt!(
        prompt: "delegated result while awaiting input",
        source: "delegation_callback",
        attachments: [{
          "type" => "link", "title" => "Delegated evidence",
          "url" => "https://example.test/delegated-evidence"
        }]
      )
      store = HQ::AgentStore.new(registry.projects)
      store.save([agent])

      service = HQ::RemoteService.new(registry:)
      with_stubbed_start { service.agent(agent.key) }
      restored = HQ::RemoteService.new(registry:).agent(agent.key)
      assert(restored.dig(:prompt_queue, "blocked_by_inquiry") == true &&
             restored.dig(:prompt_queue, "entries").length == 1,
             "expected active and client-dismissed restorable inquiries to retain and block the queue")

      execution_prompts = []
      with_stubbed_start(prompts: execution_prompts) do
        service.answer_inquiry(
          agent.key,
          "inquiry-queue-test",
          "answer" => '{"path":"safe"}',
          "start" => true
        )
        service.agent(agent.key)
      end
      persisted = store.load.find { |candidate| candidate.key == agent.key }
      events = HQ::AgentMemory.new(persisted).events
      direct_index = events.index { |event| event["type"] == "user_message" && event.dig("metadata", "inquiry_response") == true }
      queue_index = events.index { |event| event.dig("metadata", "queue_read") == true }
      assert(persisted.run_count == 2 && persisted.active_queue_work &&
             persisted.queued_prompts.none? { |entry| entry["state"] == "queued" } &&
             execution_prompts.one? && execution_prompts.first.include?('"path": "safe"') &&
             execution_prompts.first.include?("delegated result while awaiting input") &&
             execution_prompts.first.include?("[TYCHO QUEUE WORK CONTRACT — REQUIRED]") &&
             direct_index && queue_index && direct_index < queue_index &&
             events[queue_index].dig("metadata", "attachments", 0, "title") == "Delegated evidence",
             "expected the inquiry answer and pending delegated reply in one parsed, structured run " \
             "(runs=#{persisted.run_count}, prompts=#{execution_prompts.length}, direct=#{direct_index.inspect}, " \
             "queue=#{queue_index.inspect}, entries=#{persisted.queued_prompts.map { |entry| entry['state'] }.inspect})")
    end
  end

  def assert_entries_accepted_after_claim_form_a_consecutive_batch
    with_queue_store do |registry, workspace|
      agent = terminal_agent(workspace)
      agent.enqueue_prompt!(prompt: "first batch")
      store = HQ::AgentStore.new(registry.projects)
      store.save([agent])
      service = HQ::RemoteService.new(registry:)

      follow_up_pid = nil
      with_stubbed_running_start do |pids|
        dispatched = service.agent(agent.key)
        follow_up_pid = pids.last
        assert(dispatched[:running], "expected the first claimed batch to start a follow-up run")
        queued = service.submit_prompt(agent.key, "prompt" => "next batch", "start" => true)
        persisted_during_run = store.load_with_poll_events(process_delegations: false, dispatch_prompt_queues: false).first
                                    .find { |candidate| candidate.key == agent.key }
        assert(queued[:queued] && persisted_during_run.prompt_queue.map { |entry| entry["prompt"] } == ["next batch"],
               "expected work accepted after the claim to form the next batch")
      end
      stop_process(follow_up_pid)
      first_batch = store.load_with_poll_events(process_delegations: false, dispatch_prompt_queues: false).first
                         .find { |candidate| candidate.key == agent.key }.active_queue_work
      store.complete_queue_work!(agent.key, batch_id: first_batch.fetch("id"), dispositions: [
                                   { "entry_id" => first_batch.dig("entries", 0, "id"), "outcome" => "completed" }
                                 ])
      with_stubbed_start { service.agent(agent.key) }

      persisted = store.load.find { |candidate| candidate.key == agent.key }
      messages = queued_memory_events(agent.key, store)
      assert(persisted.run_count == 3 && messages.length == 2 &&
             messages.all? { |event| event.dig("metadata", "queue_read") == true } &&
             messages.map { |event| event["content"] }.zip(%w[first next]).all? { |content, word| content.include?(word) },
             "expected consecutive batches to start one follow-up run each")
    ensure
      stop_process(follow_up_pid)
    end
  end

  def assert_late_status_write_cannot_finish_successor_run
    with_queue_store do |registry, workspace|
      agent = terminal_agent(workspace)
      stale_status_path = agent.send(:status_file_path)
      agent.enqueue_prompt!(prompt: "first batch")
      store = HQ::AgentStore.new(registry.projects)
      store.save([agent])
      service = HQ::RemoteService.new(registry:)

      follow_up_pid = nil
      with_stubbed_running_start do |pids|
        service.agent(agent.key)
        follow_up_pid = pids.last
        service.submit_prompt(agent.key, "prompt" => "next batch", "start" => true)

        # A still-running older Tycho process can rewrite the agent record
        # without fields introduced by the newer server.
        rewritten = store.load.find { |candidate| candidate.key == agent.key }
        rewritten.last_run.run_scoped_status = false
        store.save([rewritten])

        # The previous run's monitor can finish after its finalizer starts the
        # successor. Its late status write must not apply to that successor.
        File.write(stale_status_path, "0")
        current = service.agent(agent.key)
        assert(current[:running], "expected a late status write not to finish the successor run")
        assert(current.dig(:prompt_queue, "entries").any? { |entry| entry["prompt"] == "next batch" && entry["state"] == "queued" },
               "expected the next batch to remain queued behind the successor run")
        persisted = store.load.find { |candidate| candidate.key == agent.key }
        assert(persisted.run_count == 2,
               "expected a stale status file not to launch an overlapping third run")
      end
    ensure
      stop_process(follow_up_pid)
    end
  end

  def assert_manual_prompt_retires_inquiry_without_dropping_queue
    with_queue_store do |registry, workspace|
      inquiry = { "message" => "Need approval", "fields" => [] }
      agent = terminal_agent(workspace, status: "input_required", structured_result: {
        "status" => "input_required", "inquiry" => inquiry
      })
      memory = HQ::AgentMemory.new(agent)
      memory.append_inquiry_request!(inquiry, inquiry_id: "manual-retire-inquiry")
      agent.enqueue_prompt!(prompt: "queued delegated context", source: "delegation_callback")
      store = HQ::AgentStore.new(registry.projects)
      store.save([agent])
      service = HQ::RemoteService.new(registry:)

      execution_prompts = []
      with_stubbed_start(prompts: execution_prompts) do
        manual = service.submit_prompt(agent.key, "prompt" => "Proceed manually", "start" => true)
        assert(manual.dig(:agent, :prompt_queue, "entries").length == 1 &&
               manual.dig(:agent, :prompt_queue, "entries", 0, "state") == "in_progress",
               "expected a manual ordinary prompt to claim the suspended queue into the same run")
        service.agent(agent.key)
      end

      persisted = store.load.find { |candidate| candidate.key == agent.key }
      events = HQ::AgentMemory.new(persisted).events
      assert(events.any? { |event| event["type"] == "inquiry_cancelled" } &&
             persisted.run_count == 2 && persisted.active_queue_work &&
             execution_prompts.one? && execution_prompts.first.include?("Proceed manually") &&
             execution_prompts.first.include?("queued delegated context") &&
             events.count { |event| event.dig("metadata", "queue_read") == true } == 1,
             "expected manual retirement and queued work to share one run and one Read queue block")
    end
  end

  def assert_authority_is_captured_per_fifo_entry
    with_queue_store do |registry, workspace|
      parent_workspace = File.join(workspace, "parent")
      FileUtils.mkdir_p(parent_workspace)
      parent = terminal_agent(parent_workspace)
      parent.instance_variable_set(:@key, "parent-agent")
      child, pid = running_agent(workspace)
      store = HQ::AgentStore.new(registry.projects)
      store.save([parent, child])
      service = HQ::RemoteService.new(registry:)

      parent_response = service.submit_prompt(
        child.key, "prompt" => "parent first", "parent_agent_key" => parent.key, "start" => true
      )
      user_response = service.submit_prompt(child.key, "prompt" => "user takeover", "start" => true)
      reclaimed_response = service.submit_prompt(
        child.key, "prompt" => "parent reclaimed", "parent_agent_key" => parent.key, "start" => true
      )
      entries = reclaimed_response.dig(:agent, :prompt_queue, "entries")
      assert(parent_response.dig(:queue_entry, "authority", "owner") == "parent" &&
             user_response.dig(:queue_entry, "authority", "owner") == "user" &&
             entries.map { |entry| entry.dig("authority", "generation") } == [1, 2, 3],
             "expected parent, Takeover, and reclaim authority generations to be captured at acceptance")

      stop_process(pid)
      with_stubbed_start { service.agent(child.key) }
      persisted = store.load.find { |agent| agent.key == child.key }
      stamp = persisted.runs.last.then { |run| [run.delegation_owner, run.delegation_generation] }
      assert(stamp == ["parent", 3],
             "expected the newest entry ownership stamp to describe the consolidated receiver-owned batch")
      message = queued_memory_events(child.key, store).last
      assert(message["content"].include?("parent first") && message["content"].include?("user takeover") &&
             message["content"].include?("parent reclaimed") &&
             persisted.active_queue_work["entries"].map { |entry| entry["prompt"] } ==
               ["parent first", "user takeover", "parent reclaimed"] &&
             message.dig("metadata", "message_author", "agent_key") == parent.key &&
             message.dig("metadata", "prompt_queue_entry_count") == 3,
             "expected takeover and reclaim entries to become one ordered native input owned by the receiver")
    ensure
      stop_process(pid)
    end
  end

  def assert_normal_stop_dispatches_pending_work
    with_queue_store do |registry, workspace|
      agent, pid = running_agent(workspace)
      store = HQ::AgentStore.new(registry.projects)
      agent.enqueue_prompt!(prompt: "keep after stop")
      store.save([agent])

      stopped = nil
      with_stubbed_start { stopped = store.stop_agent!(agent.key) }
      pid = nil
      persisted = store.load_with_poll_events(process_delegations: false, dispatch_prompt_queues: false).first
                       .find { |candidate| candidate.key == agent.key }
      assert(stopped.run_count == 2 && persisted.active_queue_work &&
             persisted.prompt_queue_dispatch_error.nil? &&
             persisted.active_queue_work.dig("entries", 0, "prompt") == "keep after stop",
             "expected Stop to launch one canonical queued-work run after the prior process exits")
    ensure
      stop_process(pid)
    end
  end

  def assert_idle_agent_without_live_pid_dispatches_pending_work
    with_queue_store do |registry, workspace|
      agent, pid = running_agent(workspace)
      agent.enqueue_prompt!(prompt: "dispatch after idle")
      store = HQ::AgentStore.new(registry.projects)
      store.save([agent])
      stop_process(pid)
      pid = nil

      with_stubbed_start { store.load }
      persisted = store.load_with_poll_events(process_delegations: false, dispatch_prompt_queues: false).first
                       .find { |candidate| candidate.key == agent.key }
      assert(persisted.run_count == 2 && persisted.active_queue_work &&
             persisted.active_queue_work.dig("entries", 0, "prompt") == "dispatch after idle",
             "expected polling an idle agent with no live PID to dispatch its pending queue")
    ensure
      stop_process(pid)
    end
  end

  def assert_ineligible_agents_do_not_dispatch_pending_work
    with_queue_store do |registry, workspace|
      blocked = terminal_agent(workspace, status: "blocked", structured_result: {
        "status" => "blocked", "summary" => "Blocked"
      })
      blocked.enqueue_prompt!(prompt: "blocked queue")

      archived = terminal_agent(workspace)
      archived.instance_variable_set(:@key, "archived-queue-agent")
      archived.instance_variable_set(:@archived, true)
      archived.enqueue_prompt!(prompt: "archived queue")

      paused = terminal_agent(workspace)
      paused.instance_variable_set(:@key, "paused-queue-agent")
      paused.associate_schedule!("paused-schedule")
      paused.enqueue_prompt!(prompt: "paused schedule queue")

      store = HQ::AgentStore.new(registry.projects)
      store.save([blocked, archived, paused])
      schedule_store = HQ::ScheduleStore.new
      state = schedule_store.state_for({}, "paused-schedule")
      state.last_target_key = paused.key
      state.mark_paused!
      schedule_store.save(state.key => state)

      starts = 0
      original = HQ::ManagedAgent.instance_method(:start!)
      HQ::ManagedAgent.define_method(:start!) do |**_options|
        starts += 1
        true
      end
      store.load

      persisted = store.load_with_poll_events(process_delegations: false, dispatch_prompt_queues: false).first
      assert(starts.zero? && persisted.all? { |candidate| candidate.prompt_queue.length == 1 },
             "expected archived, blocked, and paused-schedule agents to retain queues without dispatch")
    ensure
      HQ::ManagedAgent.define_method(:start!, original) if defined?(original) && original
    end
  end

  def assert_archive_stops_run_and_preserves_unperformed_queue_work
    with_queue_store do |registry, workspace|
      agent, pid = running_agent(workspace)
      agent.enqueue_prompt!(prompt: "Do not run this user work", id: "archive-user")
      agent.enqueue_prompt!(prompt: "Do not run this delegated report", id: "archive-report", source: "delegation_callback")
      HQ::AgentMemory.new(agent).append_inquiry_request!(
        { "message" => "Choose a target", "fields" => [] }, inquiry_id: "archive-inquiry"
      )
      store = HQ::AgentStore.new(registry.projects)
      store.save([agent])

      original = HQ::ManagedAgent.instance_method(:start!)
      starts = 0
      HQ::ManagedAgent.define_method(:start!) do |**_options|
        starts += 1
        raise "Archived queue work must not start"
      end
      destination = store.archive_agent!(agent.key)
      pid = nil

      manifest = JSON.parse(File.read(File.join(destination, "agent_manifest.json")))
      batches = manifest.dig("queue_work", "batches")
      dispositions = batches.flat_map { |batch| batch.fetch("dispositions").values }
      memory_events = File.readlines(File.join(destination, "raw.memory.jsonl"), chomp: true).map { |line| JSON.parse(line) }
      assert(starts.zero?, "expected archive to never launch queued harness work")
      assert(batches.length == 1 && batches.first["state"] == "resolved" &&
             dispositions.map { |item| item["reason"] }.uniq == [HQ::ManagedAgent::ARCHIVE_ABORT_MESSAGE] &&
             dispositions.map { |item| item["outcome"] }.sort == %w[declined_with_reason superseded_with_reason],
             "expected each archived queue entry to retain a truthful terminal outcome")
      assert(memory_events.any? { |event| event["type"] == "inquiry_cancelled" } &&
             memory_events.any? { |event| event["content"] == HQ::ManagedAgent::ARCHIVE_ABORT_MESSAGE },
             "expected archive history to preserve inquiry cancellation and the visible abort message")
      never_delivered = memory_events.find { |event| event["content"] == "Do not run this user work" }
      assert(never_delivered.dig("metadata", "archived_without_run") == true &&
             never_delivered.dig("metadata", "queue_work_delivery_state") == "not_delivered",
             "expected never-delivered evidence to state that no execution occurred")
      assert(!agent.running?, "expected archive to stop the active process group")
    ensure
      HQ::ManagedAgent.define_method(:start!, original) if defined?(original) && original
      stop_process(pid)
    end
  end

  def assert_archive_marks_delivered_queue_work_uncertain
    with_queue_store do |registry, workspace|
      agent = terminal_agent(workspace)
      agent.enqueue_prompt!(prompt: "Already delivered", id: "delivered-entry")
      batch = agent.open_queue_work_batch!
      agent.record_queue_read!(batch)
      store = HQ::AgentStore.new(registry.projects)
      store.save([agent])

      destination = store.archive_agent!(agent.key)
      manifest = JSON.parse(File.read(File.join(destination, "agent_manifest.json")))
      disposition = manifest.dig("queue_work", "batches", 0, "dispositions", "delivered-entry")
      event = File.readlines(File.join(destination, "raw.memory.jsonl"), chomp: true).map { |line| JSON.parse(line) }
                  .find { |item| item.dig("metadata", "queue_work_batch_id") == manifest.dig("queue_work", "batches", 0, "id") }
      assert(disposition["outcome"] == "aborted_with_uncertainty" &&
             disposition["reason"] == HQ::ManagedAgent::ARCHIVE_ABORT_MESSAGE,
             "expected delivered queue work to preserve side-effect uncertainty")
      assert(event.dig("metadata", "archived_without_run") == false &&
             event.dig("metadata", "queue_work_delivery_state") == "delivered_or_in_flight" &&
             event.dig("metadata", "queue_work_abort_message") == HQ::ManagedAgent::ARCHIVE_ABORT_MESSAGE,
             "expected delivered evidence to preserve uncertainty without claiming no execution")
    end
  end

  def assert_explicit_read_consumes_one_mixed_batch_and_records_conversation
    with_queue_store do |registry, workspace|
      agent, pid = running_agent(workspace)
      attachment_path = File.join(workspace, "queue-note.txt")
      File.write(attachment_path, "queued attachment")
      link_attachment = {
        "type" => "link", "title" => "Review", "url" => "https://example.test/review",
        "description" => "Delegated review target", "source" => "delegate"
      }
      file_attachment = {
        "type" => "file", "title" => "Queue note", "path" => attachment_path,
        "mime_type" => "text/plain", "description" => "Delegated file context", "source" => "delegate"
      }
      user_link_attachment = link_attachment.merge(
        "description" => "User review target", "source" => "user"
      )
      user_file_attachment = file_attachment.merge(
        "description" => "User-supplied context", "source" => "user"
      )
      agent.enqueue_prompt!(prompt: "delegated result", source: "delegation_callback",
                            attachments: [link_attachment, link_attachment.dup,
                                          file_attachment, file_attachment.dup])
      agent.enqueue_prompt!(prompt: "user follow-up", source: "user",
                            attachments: [user_link_attachment, user_link_attachment.dup,
                                          user_file_attachment, user_file_attachment.dup])
      store = HQ::AgentStore.new(registry.projects)
      store.save([agent])

      result = store.read_prompt_queue!(agent.key, read_at: Time.utc(2026, 9, 19, 1, 2, 3))
      repeated = store.read_prompt_queue!(agent.key, read_at: Time.utc(2026, 9, 19, 1, 2, 4))
      persisted = store.load_with_poll_events(process_delegations: false, dispatch_prompt_queues: false).first
                       .find { |candidate| candidate.key == agent.key }
      events = HQ::AgentMemory.new(persisted).events.select { |event| event.dig("metadata", "queue_read") }
      assert(result[:entries].length == 2 && result[:content].include?("TYCHO QUEUE WORK CONTRACT") &&
             result[:batch]["entries"].map { |entry| entry["prompt"] } == ["delegated result", "user follow-up"],
             "expected explicit reads to return one canonical mixed queue-work batch")
      assert(repeated[:idempotent] && repeated[:read_id] == result[:read_id] &&
             repeated[:batch]["batch_id"] == result[:batch]["batch_id"],
             "expected repeated reads to return the same open batch without another read event")
      assert(result[:read_entries].map { |entry| [entry["prompt"], entry["source"], entry["state"]] } == [
               ["delegated result", "delegation_callback", "in_progress"],
               ["user follow-up", "user", "in_progress"]
             ], "expected queue reads to retain structured FIFO entries for Conversation rendering")
      assert(result[:attachments].map { |attachment| HQ::AttachmentNormalizer.attachment_target(attachment) } ==
             ["https://example.test/review", attachment_path,
              "https://example.test/review", attachment_path] &&
             result[:attachments].map { |attachment| attachment["description"] } ==
             ["Delegated review target", "Delegated file context",
              "User review target", "User-supplied context"],
             "expected explicit reads to retain target-sharing metadata and remove only exact duplicates")
      assert(persisted.active_queue_work && persisted.prompt_queue.empty? && events.length == 1,
             "expected a successful explicit read to open durable work and record one conversation event")
      assert(events.first.dig("metadata", "read_label") == "Read queue" &&
             events.first.dig("metadata", "prompt_queue_sources") == {
               "delegation_callback" => 1, "user" => 1
             }, "expected the queue read event to retain its label and mixed source counts")
      assert(events.first.dig("metadata", "attachments") == result[:attachments],
             "expected the single queue read event to preserve the returned attachments")
      assert(events.first.dig("metadata", "prompt_queue_entries") == result[:read_entries],
             "expected the single queue read event to preserve the returned structured entries")
      conversation = HQ::RemoteService.new(registry:).conversation(agent.key)
      read_block = conversation.find { |block| block.dig(:metadata, "queue_read") == true }
      assert(read_block && read_block[:content] == result[:content] &&
             read_block.dig(:metadata, "read_label") == "Read queue",
             "expected Remote Conversation to expose one labeled queue read block")
    ensure
      stop_process(pid)
    end
  end

  def assert_direct_start_records_active_queue_work
    with_queue_store do |registry, workspace|
      agent = terminal_agent(workspace)
      agent.enqueue_prompt!(prompt: "Process this active batch", source: "user", id: "direct-start-entry")
      batch = agent.open_queue_work_batch!
      store = HQ::AgentStore.new(registry.projects)
      store.save([agent])

      previous_codex_bin = ENV["TYCHO_CODEX_BIN"]
      ENV["TYCHO_CODEX_BIN"] = File.join(workspace, "missing-codex")
      store.start_agent!(agent.key)
      failed = store.load_with_poll_events(process_delegations: false, dispatch_prompt_queues: false).first
                    .find { |candidate| candidate.key == agent.key }
      failed_batch = failed.queue_work_batch(batch.fetch("id"))
      failed_reads = HQ::AgentMemory.new(failed).events.count do |event|
        event.dig("metadata", "queue_work_batch_id") == batch.fetch("id") &&
          event.dig("metadata", "queue_read") == true
      end
      assert(failed_batch.fetch("delivery_count") == 0 && failed_batch["read_id"].to_s.empty? && failed_reads.zero?,
             "expected executable validation to fail before Tycho records queue delivery")

      capture_path = File.join(workspace, "captured-prompt.txt")
      harness_path = queue_capture_harness(workspace)
      ENV["TYCHO_TEST_QUEUE_CAPTURE"] = capture_path
      ENV["TYCHO_CODEX_BIN"] = harness_path
      started = store.start_agent!(agent.key)
      wait_for_agent_process(started)
      persisted = store.load_with_poll_events(process_delegations: false, dispatch_prompt_queues: false).first
                       .find { |candidate| candidate.key == agent.key }
      persisted_batch = persisted.queue_work_batch(batch.fetch("id"))
      reads = HQ::AgentMemory.new(persisted).events.select do |event|
        event.dig("metadata", "queue_work_batch_id") == batch.fetch("id") &&
          event.dig("metadata", "queue_read") == true
      end

      assert(File.read(capture_path).include?("TYCHO QUEUE WORK CONTRACT") &&
             persisted_batch.fetch("delivery_count") == 1 && !persisted_batch["read_id"].to_s.empty? &&
             reads.length == 1 && reads.first["event_id"] == persisted_batch["read_id"] &&
             persisted.last_run.metadata["native_start_acknowledged"] == true,
             "expected the native harness to receive the active queue contract with one durable read")
    ensure
      ENV.delete("TYCHO_TEST_QUEUE_CAPTURE")
      if previous_codex_bin
        ENV["TYCHO_CODEX_BIN"] = previous_codex_bin
      else
        ENV.delete("TYCHO_CODEX_BIN")
      end
    end
  end

  def assert_native_automatic_dispatch_captures_after_accounting
    with_queue_store do |registry, workspace|
      agent = terminal_agent(workspace)
      agent.enqueue_prompt!(prompt: "Dispatch this native batch", source: "user", id: "native-dispatch-entry")
      store = HQ::AgentStore.new(registry.projects)
      store.save([agent])
      previous_codex_bin = ENV["TYCHO_CODEX_BIN"]
      capture_path = File.join(workspace, "automatic-captured-prompt.txt")
      ENV["TYCHO_CODEX_BIN"] = queue_capture_harness(workspace)
      ENV["TYCHO_TEST_QUEUE_CAPTURE"] = capture_path

      started = store.load.find { |candidate| candidate.key == agent.key }
      wait_for_agent_process(started)
      persisted = store.load_with_poll_events(process_delegations: false, dispatch_prompt_queues: false).first.first
      batch = persisted.active_queue_work
      reads = queue_read_events(persisted, batch.fetch("id"))
      assert(File.read(capture_path).include?("TYCHO QUEUE WORK CONTRACT") &&
             batch.fetch("delivery_count") == 1 && reads.length == 1 &&
             reads.first["event_id"] == batch.fetch("read_id") &&
             persisted.last_run.metadata["native_start_acknowledged"] == true,
             "expected automatic native dispatch to run only with matching durable accounting")
    ensure
      previous_codex_bin ? ENV["TYCHO_CODEX_BIN"] = previous_codex_bin : ENV.delete("TYCHO_CODEX_BIN")
      ENV.delete("TYCHO_TEST_QUEUE_CAPTURE")
    end
  end

  def assert_spawn_failure_does_not_record_queue_delivery
    with_queue_store do |registry, workspace|
      agent = terminal_agent(workspace)
      agent.enqueue_prompt!(prompt: "Retry after spawn failure", source: "user", id: "spawn-retry-entry")
      batch = agent.open_queue_work_batch!
      store = HQ::AgentStore.new(registry.projects)
      store.save([agent])
      harness_path = queue_capture_harness(workspace)
      capture_path = File.join(workspace, "spawn-retry-capture.txt")
      previous_codex_bin = ENV["TYCHO_CODEX_BIN"]
      ENV["TYCHO_CODEX_BIN"] = harness_path
      ENV["TYCHO_TEST_QUEUE_CAPTURE"] = capture_path

      original_spawn = HQ::ManagedAgent.instance_method(:spawn)
      HQ::ManagedAgent.define_method(:spawn) { |*| raise Errno::EAGAIN, "simulated spawn failure" }
      begin
        store.start_agent!(agent.key)
        raise "expected spawn failure"
      rescue Errno::EAGAIN
        nil
      ensure
        HQ::ManagedAgent.define_method(:spawn, original_spawn)
      end

      failed = store.load_with_poll_events(process_delegations: false, dispatch_prompt_queues: false).first.first
      failed_batch = failed.queue_work_batch(batch.fetch("id"))
      failed_reads = queue_read_events(failed, batch.fetch("id"))
      assert(failed_batch.fetch("delivery_count") == 0 && failed_batch["read_id"].to_s.empty? && failed_reads.empty?,
             "expected a post-preflight spawn failure to leave no delivery evidence")

      started = store.start_agent!(agent.key)
      wait_for_agent_process(started)
      persisted = store.load_with_poll_events(process_delegations: false, dispatch_prompt_queues: false).first.first
      persisted_batch = persisted.queue_work_batch(batch.fetch("id"))
      reads = queue_read_events(persisted, batch.fetch("id"))
      assert(File.read(capture_path).include?("TYCHO QUEUE WORK CONTRACT") &&
             persisted_batch.fetch("delivery_count") == 1 && reads.length == 1 &&
             reads.first["event_id"] == "queue-read:#{batch.fetch('id')}",
             "expected spawn retry to use one canonical read identity after native delivery")
    ensure
      HQ::ManagedAgent.define_method(:spawn, original_spawn) if defined?(original_spawn) && original_spawn
      previous_codex_bin ? ENV["TYCHO_CODEX_BIN"] = previous_codex_bin : ENV.delete("TYCHO_CODEX_BIN")
      ENV.delete("TYCHO_TEST_QUEUE_CAPTURE")
    end
  end

  def assert_native_spawn_failure_rolls_back_and_retries_safely
    with_queue_store do |registry, workspace|
      agent = terminal_agent(workspace)
      agent.enqueue_prompt!(prompt: "Retry after native spawn failure", source: "user", id: "native-retry-entry")
      batch = agent.open_queue_work_batch!
      store = HQ::AgentStore.new(registry.projects)
      store.save([agent])
      previous_codex_bin = ENV["TYCHO_CODEX_BIN"]
      invalid_harness = File.join(workspace, "missing-interpreter-codex")
      File.write(invalid_harness, "#!/missing/tycho-test-interpreter\n")
      File.chmod(0o755, invalid_harness)
      ENV["TYCHO_CODEX_BIN"] = invalid_harness

      error = capture_error { store.start_agent!(agent.key) }
      failed = store.load_with_poll_events(process_delegations: false, dispatch_prompt_queues: false).first.first
      failed_batch = failed.queue_work_batch(batch.fetch("id"))
      assert(error.is_a?(HQ::ManagedAgent::NativeStartError) &&
             failed_batch.fetch("delivery_count") == 0 && failed_batch["read_id"].to_s.empty? &&
             queue_read_events(failed, batch.fetch("id")).empty? && failed.pid.nil? &&
             failed.last_run.status == "failed" && failed.last_run.metadata["start_failure"] == true &&
             failed.last_run.metadata["native_start_acknowledged"] == false,
             "expected actual native spawn failure to roll back delivery and persist one failed run")

      capture_path = File.join(workspace, "native-retry-capture.txt")
      ENV["TYCHO_CODEX_BIN"] = queue_capture_harness(workspace)
      ENV["TYCHO_TEST_QUEUE_CAPTURE"] = capture_path
      started = store.start_agent!(agent.key)
      wait_for_agent_process(started)
      persisted = store.load_with_poll_events(process_delegations: false, dispatch_prompt_queues: false).first.first
      persisted_batch = persisted.queue_work_batch(batch.fetch("id"))
      assert(File.read(capture_path).include?("TYCHO QUEUE WORK CONTRACT") &&
             persisted_batch.fetch("delivery_count") == 1 &&
             queue_read_events(persisted, batch.fetch("id")).length == 1,
             "expected retry after native spawn failure to deliver once with durable evidence")
    ensure
      previous_codex_bin ? ENV["TYCHO_CODEX_BIN"] = previous_codex_bin : ENV.delete("TYCHO_CODEX_BIN")
      ENV.delete("TYCHO_TEST_QUEUE_CAPTURE")
    end
  end

  def assert_exact_boundary_restart_rolls_back_failed_native_spawn_and_retries_once
    with_queue_store do |registry, workspace|
      agent = terminal_agent(workspace)
      agent.enqueue_prompt!(prompt: "Recover this failed staged launch", source: "user", id: "restart-failure-entry")
      store = HQ::AgentStore.new(registry.projects)
      store.save([agent])
      previous_codex_bin = ENV["TYCHO_CODEX_BIN"]
      invalid_harness = File.join(workspace, "restart-missing-interpreter")
      File.write(invalid_harness, "#!/missing/restart-test-interpreter\n")
      FileUtils.chmod(0o755, invalid_harness)
      ENV["TYCHO_CODEX_BIN"] = invalid_harness

      crash_dispatch_after_store_before_journal(store)
      staged_record = Array(HQ::FileStore.read_json(HQ::AGENTS_FILE, fallback: [])).fetch(0)
      staged = HQ::ManagedAgent.from_hash(staged_record)
      batch_id = staged.active_queue_work.fetch("id")
      outer_pid = staged.pid
      assert(staged.staged_queue_delivery.is_a?(Hash) &&
             staged.active_queue_work.fetch("delivery_count") == 1 && staged.prompt_queue_claim &&
             queue_read_events(staged, batch_id).empty? && process_alive?(outer_pid),
             "expected durable staging to retain a live recovery-owned runner before journal rewrite")

      failed = store.load_with_poll_events(process_delegations: false, dispatch_prompt_queues: false).first.first
      failed_batch = failed.queue_work_batch(batch_id)
      assert(failed_batch.fetch("delivery_count") == 0 && failed_batch["read_id"].to_s.empty? &&
             queue_read_events(failed, batch_id).empty? && failed.pid.nil? &&
             failed.last_run.status == "failed" && failed.last_run.metadata["start_failure"] == true &&
             failed.staged_queue_delivery.nil? && failed.prompt_queue_claim &&
             failed.prompt_queue_dispatch_error&.fetch("retryable", false) == true &&
             process_gone_and_reaped?(outer_pid),
             "expected restart recovery to roll back false evidence, settle failure, and retain a retryable claim")

      capture_path = File.join(workspace, "restart-retry-capture.txt")
      ENV["TYCHO_CODEX_BIN"] = queue_capture_harness(workspace)
      ENV["TYCHO_TEST_QUEUE_CAPTURE"] = capture_path
      retried = store.retry_prompt_queue!(agent.key)
      wait_for_agent_process(retried)
      persisted = store.load_with_poll_events(process_delegations: false, dispatch_prompt_queues: false).first.first
      persisted_batch = persisted.queue_work_batch(batch_id)
      assert(File.read(capture_path).include?("TYCHO QUEUE WORK CONTRACT") &&
             persisted_batch.fetch("delivery_count") == 1 &&
             queue_read_events(persisted, batch_id).length == 1 &&
             persisted.prompt_queue_claim.nil? && persisted.prompt_queue_dispatch_error.nil?,
             "expected one safe retry after restart recovery to create exactly one durable delivery")
    ensure
      previous_codex_bin ? ENV["TYCHO_CODEX_BIN"] = previous_codex_bin : ENV.delete("TYCHO_CODEX_BIN")
      ENV.delete("TYCHO_TEST_QUEUE_CAPTURE")
    end
  end

  def assert_pre_staging_restart_aborts_orphaned_runner_and_retries_once
    with_queue_store do |registry, workspace|
      agent = terminal_agent(workspace)
      agent.enqueue_prompt!(prompt: "Recover this prepared launch", source: "user", id: "prepared-restart-entry")
      store = HQ::AgentStore.new(registry.projects)
      store.save([agent])
      previous_codex_bin = ENV["TYCHO_CODEX_BIN"]
      capture_path = File.join(workspace, "prepared-restart-capture.txt")
      ENV["TYCHO_CODEX_BIN"] = queue_capture_harness(workspace)
      ENV["TYCHO_TEST_QUEUE_CAPTURE"] = capture_path
      crash_dispatch_before_ownership_transfer(store)

      prepared = HQ::ManagedAgent.from_hash(
        Array(HQ::FileStore.read_json(HQ::AGENTS_FILE, fallback: [])).fetch(0)
      )
      batch_id = prepared.active_queue_work.fetch("id")
      outer_pid = prepared.pid
      assert(prepared.prepared_native_launch.is_a?(Hash) && outer_pid &&
             prepared.staged_queue_delivery.nil? && prepared.prompt_queue_claim &&
             prepared.active_queue_work.fetch("delivery_count") == 0 &&
             queue_read_events(prepared, batch_id).empty? && !File.exist?(capture_path),
             "expected a stop before ownership transfer to retain the prepared PID without delivery evidence")

      failed = store.load_with_poll_events(process_delegations: false, dispatch_prompt_queues: false).first.first
      failed_batch = failed.queue_work_batch(batch_id)
      assert(failed_batch.fetch("delivery_count") == 0 && failed_batch["read_id"].to_s.empty? &&
             queue_read_events(failed, batch_id).empty? && failed.pid.nil? &&
             failed.last_run.status == "failed" && failed.prepared_native_launch.nil? &&
             failed.prompt_queue_claim && failed.prompt_queue_dispatch_error&.fetch("retryable", false) == true &&
             process_gone_and_reaped?(outer_pid) && !File.exist?(capture_path),
             "expected restart recovery to stop the unowned gate and retain one retryable claim")

      retried = store.retry_prompt_queue!(agent.key)
      wait_for_agent_process(retried)
      persisted = store.load_with_poll_events(process_delegations: false, dispatch_prompt_queues: false).first.first
      assert(File.read(capture_path).include?("TYCHO QUEUE WORK CONTRACT") &&
             persisted.queue_work_batch(batch_id).fetch("delivery_count") == 1 &&
             queue_read_events(persisted, batch_id).length == 1 && persisted.prompt_queue_claim.nil?,
             "expected one safe retry after prepared-launch recovery")
    ensure
      previous_codex_bin ? ENV["TYCHO_CODEX_BIN"] = previous_codex_bin : ENV.delete("TYCHO_CODEX_BIN")
      ENV.delete("TYCHO_TEST_QUEUE_CAPTURE")
    end
  end

  def assert_rollback_boundary_restart_removes_false_read_and_retries_once
    with_queue_store do |registry, workspace|
      agent = terminal_agent(workspace)
      agent.enqueue_prompt!(prompt: "Recover this interrupted rollback", source: "user", id: "rollback-restart-entry")
      store = HQ::AgentStore.new(registry.projects)
      store.save([agent])
      previous_codex_bin = ENV["TYCHO_CODEX_BIN"]
      invalid_harness = File.join(workspace, "rollback-missing-interpreter")
      File.write(invalid_harness, "#!/missing/rollback-test-interpreter\n")
      FileUtils.chmod(0o755, invalid_harness)
      ENV["TYCHO_CODEX_BIN"] = invalid_harness

      crash_dispatch_during_rollback_before_journal(store)
      interrupted = HQ::ManagedAgent.from_hash(
        Array(HQ::FileStore.read_json(HQ::AGENTS_FILE, fallback: [])).fetch(0)
      )
      batch_id = interrupted.active_queue_work.fetch("id")
      assert(interrupted.queue_delivery_rollback.is_a?(Hash) &&
             interrupted.active_queue_work.fetch("delivery_count") == 0 &&
             interrupted.active_queue_work["read_id"].to_s.empty? &&
             queue_read_events(interrupted, batch_id).length == 1 && interrupted.pid.nil? &&
             interrupted.last_run.status == "failed" && interrupted.prompt_queue_claim,
             "expected interrupted rollback to keep a durable recovery phase beside the old read event")

      failed = store.load_with_poll_events(process_delegations: false, dispatch_prompt_queues: false).first.first
      failed_batch = failed.queue_work_batch(batch_id)
      assert(failed.queue_delivery_rollback.nil? && failed.staged_queue_delivery.nil? &&
             failed_batch.fetch("delivery_count") == 0 && failed_batch["read_id"].to_s.empty? &&
             queue_read_events(failed, batch_id).empty? && failed.pid.nil? &&
             failed.last_run.status == "failed" && failed.prompt_queue_claim &&
             failed.prompt_queue_dispatch_error&.fetch("retryable", false) == true,
             "expected restart recovery to remove false read evidence and retain a retryable failed claim")

      capture_path = File.join(workspace, "rollback-retry-capture.txt")
      ENV["TYCHO_CODEX_BIN"] = queue_capture_harness(workspace)
      ENV["TYCHO_TEST_QUEUE_CAPTURE"] = capture_path
      retried = store.retry_prompt_queue!(agent.key)
      wait_for_agent_process(retried)
      persisted = store.load_with_poll_events(process_delegations: false, dispatch_prompt_queues: false).first.first
      assert(File.read(capture_path).include?("TYCHO QUEUE WORK CONTRACT") &&
             persisted.queue_work_batch(batch_id).fetch("delivery_count") == 1 &&
             queue_read_events(persisted, batch_id).length == 1 && persisted.prompt_queue_claim.nil?,
             "expected one safe retry after interrupted rollback recovery")
    ensure
      previous_codex_bin ? ENV["TYCHO_CODEX_BIN"] = previous_codex_bin : ENV.delete("TYCHO_CODEX_BIN")
      ENV.delete("TYCHO_TEST_QUEUE_CAPTURE")
    end
  end

  def assert_exact_boundary_restart_accepts_successful_native_acknowledgement_once
    with_queue_store do |registry, workspace|
      agent = terminal_agent(workspace)
      agent.enqueue_prompt!(prompt: "Recover this successful staged launch", source: "user", id: "restart-success-entry")
      store = HQ::AgentStore.new(registry.projects)
      store.save([agent])
      previous_codex_bin = ENV["TYCHO_CODEX_BIN"]
      capture_path = File.join(workspace, "restart-success-capture.txt")
      ENV["TYCHO_CODEX_BIN"] = queue_capture_harness(workspace)
      ENV["TYCHO_TEST_QUEUE_CAPTURE"] = capture_path

      crash_dispatch_after_store_before_journal(store)
      staged_record = Array(HQ::FileStore.read_json(HQ::AGENTS_FILE, fallback: [])).fetch(0)
      staged = HQ::ManagedAgent.from_hash(staged_record)
      batch_id = staged.active_queue_work.fetch("id")
      assert(staged.staged_queue_delivery.is_a?(Hash) && !File.exist?(capture_path) &&
             queue_read_events(staged, batch_id).empty? && process_alive?(staged.pid),
             "expected recovery ownership to keep staged native work gated at the exact crash boundary")

      recovered = store.load_with_poll_events(process_delegations: false, dispatch_prompt_queues: false).first.first
      deadline = Time.now + 5
      until File.file?(capture_path) && !recovered.running?
        raise "recovered native harness did not finish" if Time.now >= deadline

        sleep 0.01
        recovered = store.load_with_poll_events(process_delegations: false, dispatch_prompt_queues: false).first.first
      end
      recovered = store.load_with_poll_events(process_delegations: false, dispatch_prompt_queues: false).first.first
      recovered_batch = recovered.queue_work_batch(batch_id)
      assert(File.read(capture_path).include?("TYCHO QUEUE WORK CONTRACT") &&
             recovered.last_run.metadata["native_start_acknowledged"] == true &&
             recovered.staged_queue_delivery.nil? && recovered_batch.fetch("delivery_count") == 1 &&
             queue_read_events(recovered, batch_id).length == 1 && recovered.prompt_queue_claim.nil? &&
             recovered.prompt_queue_dispatch_error.nil?,
             "expected restart recovery to durably accept one native acknowledgement without duplicate delivery")
    ensure
      previous_codex_bin ? ENV["TYCHO_CODEX_BIN"] = previous_codex_bin : ENV.delete("TYCHO_CODEX_BIN")
      ENV.delete("TYCHO_TEST_QUEUE_CAPTURE")
    end
  end

  def assert_exact_boundary_repair_failures_keep_native_gate_closed
    with_queue_store do |registry, workspace|
      agent = terminal_agent(workspace)
      agent.enqueue_prompt!(prompt: "Recover after repair failures", source: "user", id: "repair-failure-entry")
      store = HQ::AgentStore.new(registry.projects)
      store.save([agent])
      previous_codex_bin = ENV["TYCHO_CODEX_BIN"]
      capture_path = File.join(workspace, "repair-failure-capture.txt")
      ENV["TYCHO_CODEX_BIN"] = queue_capture_harness(workspace)
      ENV["TYCHO_TEST_QUEUE_CAPTURE"] = capture_path

      crash_dispatch_after_store_before_journal(store)
      staged_record = Array(HQ::FileStore.read_json(HQ::AGENTS_FILE, fallback: [])).fetch(0)
      staged = HQ::ManagedAgent.from_hash(staged_record)
      batch_id = staged.active_queue_work.fetch("id")
      assert(process_alive?(staged.pid),
             "expected the recovery-owned runner to remain live after the staging owner stops")

      original_update = HQ::AgentEventJournal.instance_method(:update)
      failed_update = false
      HQ::AgentEventJournal.define_method(:update) do |&operation|
        unless failed_update
          failed_update = true
          raise IOError, "simulated recovery journal failure"
        end

        original_update.bind_call(self, &operation)
      end
      journal_error = capture_error do
        store.load_with_poll_events(process_delegations: false, dispatch_prompt_queues: false)
      end
      HQ::AgentEventJournal.define_method(:update, original_update)
      after_journal_failure = HQ::ManagedAgent.from_hash(
        Array(HQ::FileStore.read_json(HQ::AGENTS_FILE, fallback: [])).fetch(0)
      )
      assert(journal_error.is_a?(IOError) && !File.exist?(capture_path) &&
             after_journal_failure.staged_queue_delivery.is_a?(Hash) &&
             queue_read_events(after_journal_failure, batch_id).empty? && process_alive?(after_journal_failure.pid),
             "expected journal repair failure to keep native work gated and staging recoverable")

      original_save = store.method(:save_unlocked)
      failed_save = false
      store.define_singleton_method(:save_unlocked) do |agents, **options|
        if !failed_save && agents.first.staged_queue_delivery.is_a?(Hash)
          failed_save = true
          raise IOError, "simulated recovery agent save failure"
        end

        original_save.call(agents, **options)
      end
      save_error = capture_error do
        store.load_with_poll_events(process_delegations: false, dispatch_prompt_queues: false)
      end
      after_save_failure = HQ::ManagedAgent.from_hash(
        Array(HQ::FileStore.read_json(HQ::AGENTS_FILE, fallback: [])).fetch(0)
      )
      assert(save_error.is_a?(IOError) && !File.exist?(capture_path) &&
             after_save_failure.staged_queue_delivery.is_a?(Hash) &&
             queue_read_events(after_save_failure, batch_id).length == 1 && process_alive?(after_save_failure.pid),
             "expected agent save failure after journal repair to keep the gate closed with durable evidence")

      store.define_singleton_method(:save_unlocked) { |agents, **options| original_save.call(agents, **options) }
      recovered = store.load_with_poll_events(process_delegations: false, dispatch_prompt_queues: false).first.first
      deadline = Time.now + 5
      until File.file?(capture_path) && !recovered.running?
        raise "recovered native harness did not finish after repair retry" if Time.now >= deadline

        sleep 0.01
        recovered = store.load_with_poll_events(process_delegations: false, dispatch_prompt_queues: false).first.first
      end
      recovered = store.load_with_poll_events(process_delegations: false, dispatch_prompt_queues: false).first.first
      assert(File.read(capture_path).include?("TYCHO QUEUE WORK CONTRACT") &&
             recovered.queue_work_batch(batch_id).fetch("delivery_count") == 1 &&
             queue_read_events(recovered, batch_id).length == 1 && recovered.prompt_queue_claim.nil?,
             "expected recovery retry to deliver once after durable repair failures")
    ensure
      HQ::AgentEventJournal.define_method(:update, original_update) if defined?(original_update) && original_update
      if defined?(original_save) && original_save
        store.define_singleton_method(:save_unlocked) { |agents, **options| original_save.call(agents, **options) }
      end
      previous_codex_bin ? ENV["TYCHO_CODEX_BIN"] = previous_codex_bin : ENV.delete("TYCHO_CODEX_BIN")
      ENV.delete("TYCHO_TEST_QUEUE_CAPTURE")
    end
  end

  def assert_persistent_queue_delivery_save_failure_stops_and_retries_safely
    with_queue_store do |registry, workspace|
      agent = terminal_agent(workspace)
      agent.enqueue_prompt!(prompt: "Persist this delivery", source: "user", id: "save-failure-entry")
      batch = agent.open_queue_work_batch!
      store = HQ::AgentStore.new(registry.projects)
      store.save([agent])
      previous_codex_bin = ENV["TYCHO_CODEX_BIN"]
      capture_path = File.join(workspace, "save-failure-capture.txt")
      ENV["TYCHO_CODEX_BIN"] = queue_capture_harness(workspace)
      ENV["TYCHO_TEST_QUEUE_CAPTURE"] = capture_path
      original_save = store.method(:save_unlocked)
      store.define_singleton_method(:save_unlocked) do |agents, **options|
        delivered = agents.first.queue_work_batch(batch.fetch("id")).fetch("delivery_count", 0).to_i.positive?
        raise IOError, "persistent queue delivery save failure" if delivered

        original_save.call(agents, **options)
      end

      spawned = []
      error = with_captured_outer_spawns(spawned) { capture_error { store.start_agent!(agent.key) } }
      failed = store.load_with_poll_events(process_delegations: false, dispatch_prompt_queues: false).first.first
      failed_batch = failed.queue_work_batch(batch.fetch("id"))
      assert(error.is_a?(IOError) && !File.exist?(capture_path) &&
             failed_batch.fetch("delivery_count") == 0 && failed_batch["read_id"].to_s.empty? &&
             queue_read_events(failed, batch.fetch("id")).empty? && failed.pid.nil? &&
             failed.last_run.status == "failed" && process_gone_and_reaped?(spawned.fetch(0)),
             "expected persistent save failure to keep native work gated, reap the runner, and persist failure")

      store.define_singleton_method(:save_unlocked) { |agents, **options| original_save.call(agents, **options) }
      started = store.start_agent!(agent.key)
      wait_for_agent_process(started)
      retried = store.load_with_poll_events(process_delegations: false, dispatch_prompt_queues: false).first.first
      assert(File.read(capture_path).include?("TYCHO QUEUE WORK CONTRACT") &&
             retried.queue_work_batch(batch.fetch("id")).fetch("delivery_count") == 1 &&
             queue_read_events(retried, batch.fetch("id")).length == 1,
             "expected safe retry after persistent save failure to deliver exactly once")
    ensure
      previous_codex_bin ? ENV["TYCHO_CODEX_BIN"] = previous_codex_bin : ENV.delete("TYCHO_CODEX_BIN")
      ENV.delete("TYCHO_TEST_QUEUE_CAPTURE")
    end
  end

  def assert_persistent_queue_delivery_append_failure_stops_and_retries_safely
    with_queue_store do |registry, workspace|
      agent = terminal_agent(workspace)
      agent.enqueue_prompt!(prompt: "Append this delivery", source: "user", id: "append-failure-entry")
      batch = agent.open_queue_work_batch!
      store = HQ::AgentStore.new(registry.projects)
      store.save([agent])
      previous_codex_bin = ENV["TYCHO_CODEX_BIN"]
      capture_path = File.join(workspace, "append-failure-capture.txt")
      ENV["TYCHO_CODEX_BIN"] = queue_capture_harness(workspace)
      ENV["TYCHO_TEST_QUEUE_CAPTURE"] = capture_path
      original_ensure = HQ::AgentMemory.instance_method(:ensure_queue_read_in!)
      HQ::AgentMemory.define_method(:ensure_queue_read_in!) do |*|
        raise IOError, "persistent queue delivery append failure"
      end

      spawned = []
      error = with_captured_outer_spawns(spawned) { capture_error { store.start_agent!(agent.key) } }
      failed = store.load_with_poll_events(process_delegations: false, dispatch_prompt_queues: false).first.first
      failed_batch = failed.queue_work_batch(batch.fetch("id"))
      assert(error.is_a?(IOError) && !File.exist?(capture_path) &&
             failed_batch.fetch("delivery_count") == 0 && failed_batch["read_id"].to_s.empty? &&
             queue_read_events(failed, batch.fetch("id")).empty? && failed.pid.nil? &&
             failed.last_run.status == "failed" && process_gone_and_reaped?(spawned.fetch(0)),
             "expected persistent append failure to keep native work gated, reap the runner, and persist failure")

      HQ::AgentMemory.define_method(:ensure_queue_read_in!, original_ensure)
      started = store.start_agent!(agent.key)
      wait_for_agent_process(started)
      retried = store.load_with_poll_events(process_delegations: false, dispatch_prompt_queues: false).first.first
      assert(File.read(capture_path).include?("TYCHO QUEUE WORK CONTRACT") &&
             retried.queue_work_batch(batch.fetch("id")).fetch("delivery_count") == 1 &&
             queue_read_events(retried, batch.fetch("id")).length == 1,
             "expected safe retry after persistent append failure to deliver exactly once")
    ensure
      HQ::AgentMemory.define_method(:ensure_queue_read_in!, original_ensure) if defined?(original_ensure) && original_ensure
      previous_codex_bin ? ENV["TYCHO_CODEX_BIN"] = previous_codex_bin : ENV.delete("TYCHO_CODEX_BIN")
      ENV.delete("TYCHO_TEST_QUEUE_CAPTURE")
    end
  end

  def assert_missing_queue_event_repairs_without_new_delivery
    with_queue_store do |_registry, workspace|
      agent = terminal_agent(workspace)
      agent.enqueue_prompt!(prompt: "Repair this read", source: "user", id: "repair-entry")
      batch = agent.open_queue_work_batch!
      first = agent.record_queue_read!(batch)
      memory = HQ::AgentMemory.new(agent)
      memory.write_events!(memory.events.reject { |event| event["event_id"] == first.fetch(:read_id) })

      repaired = agent.ensure_active_queue_work_read!
      reads = queue_read_events(agent, batch.fetch("id"))
      assert(repaired && batch.fetch("read_id") == first.fetch(:read_id) &&
             batch.fetch("delivery_count") == 1 && reads.length == 1 &&
             reads.first["event_id"] == first.fetch(:read_id),
             "expected missing-event repair to preserve the canonical ID and delivery count")
    end
  end

  def assert_queue_event_match_requires_read_semantics_and_batch
    [
      ["assistant_message", true, nil],
      ["user_message", true, "wrong-batch"],
      ["user_message", false, nil]
    ].each do |type, queue_read, stored_batch_id|
      with_queue_store do |_registry, workspace|
        agent = terminal_agent(workspace)
        agent.enqueue_prompt!(prompt: "Validate the read event", source: "user", id: "semantic-entry")
        batch = agent.open_queue_work_batch!
        batch["read_id"] = "queue-read:#{batch.fetch('id')}"
        batch["delivery_count"] = 1
        metadata = {
          "queue_read" => queue_read,
          "queue_work_batch_id" => stored_batch_id || batch.fetch("id")
        }
        HQ::AgentMemory.new(agent).send(
          :append_unique_event!, batch.fetch("read_id"),
          "type" => type, "content" => "unrelated", "created_at" => Time.now.iso8601,
          "metadata" => metadata
        )

        agent.ensure_active_queue_work_read!
        matching = HQ::AgentMemory.new(agent).events.select do |event|
          event["event_id"] == batch.fetch("read_id") && event.dig("metadata", "queue_read") == true &&
            event.dig("metadata", "queue_work_batch_id") == batch.fetch("id")
        end
        assert(batch.fetch("delivery_count") == 1 && matching.length == 1 && matching.first["type"] == "user_message",
               "expected repair to reject an unrelated same-ID event and keep one semantic queue read")
      end
    end


    with_queue_store do |_registry, workspace|
      agent = terminal_agent(workspace)
      agent.enqueue_prompt!(prompt: "Deduplicate the read event", source: "user", id: "duplicate-entry")
      batch = agent.open_queue_work_batch!
      first = agent.record_queue_read!(batch)
      memory = HQ::AgentMemory.new(agent)
      event = memory.events.find { |candidate| candidate["event_id"] == first.fetch(:read_id) }
      duplicate = event.merge("type" => "assistant_message", "content" => "duplicate")
      memory.write_events!([event, duplicate])

      agent.ensure_active_queue_work_read!
      matching = memory.events.select { |candidate| candidate["event_id"] == first.fetch(:read_id) }
      assert(batch.fetch("delivery_count") == 1 && matching.length == 1 &&
             matching.first["type"] == "user_message" &&
             matching.first.dig("metadata", "queue_read") == true &&
             matching.first.dig("metadata", "queue_work_batch_id") == batch.fetch("id"),
             "expected repair to keep one semantic event for a duplicated canonical ID")
    end
  end

  def assert_memory_rebuild_preserves_queue_read
    with_queue_store do |_registry, workspace|
      agent = terminal_agent(workspace)
      agent.enqueue_prompt!(prompt: "Keep this queue read visible", source: "user", id: "rebuild-entry")
      batch = agent.open_queue_work_batch!
      read = agent.record_queue_read!(batch, created_at: Time.utc(2026, 10, 11, 1, 2, 3))
      File.write(agent.raw_log_path, [
        "=== [2026-10-11 01:02:00] start ===",
        "workspace=#{workspace}",
        "prompt=Continue the fixture.",
        HQ::ManagedAgent::PROCESS_OUTPUT_MARKER,
        JSON.generate("type" => "item.completed", "item" => {
          "type" => "agent_message", "text" => "Fixture complete."
        })
      ].join("\n") + "\n")

      2.times { HQ::AgentChatLog.new(agent).rebuild_memory_from_raw_log! }
      reads = HQ::AgentMemory.new(agent).events.select { |event| event.dig("metadata", "queue_read") == true }
      assert(reads.length == 1 && reads.first["event_id"] == read.fetch(:read_id) &&
             reads.first.dig("metadata", "queue_work_batch_id") == batch.fetch("id"),
             "expected repeated memory rebuilds to preserve one durable Read queue event")
    end
  end

  def assert_explicit_read_failure_retains_queue
    with_queue_store do |registry, workspace|
      agent, pid = running_agent(workspace)
      agent.enqueue_prompt!(prompt: "retain after read failure", source: "user")
      store = HQ::AgentStore.new(registry.projects)
      store.save([agent])

      original = HQ::AgentMemory.instance_method(:ensure_queue_read!)
      HQ::AgentMemory.define_method(:ensure_queue_read!) { |*| raise IOError, "simulated queue read failure" }
      begin
        store.read_prompt_queue!(agent.key)
        raise "expected queue read failure"
      rescue IOError => e
        assert(e.message.include?("simulated queue read failure"), "expected the injected durable read failure")
      ensure
        HQ::AgentMemory.define_method(:ensure_queue_read!, original)
      end

      persisted = store.load_with_poll_events(process_delegations: false, dispatch_prompt_queues: false).first
                       .find { |candidate| candidate.key == agent.key }
      assert(persisted.queued_prompts.map { |entry| entry["prompt"] } == ["retain after read failure"],
             "expected a failed explicit read to leave every queue entry durable")
    ensure
      HQ::AgentMemory.define_method(:ensure_queue_read!, original) if defined?(original) && original
      stop_process(pid)
    end
  end

  def assert_concurrent_rebuild_and_queue_append_keep_read
    with_queue_store do |_registry, workspace|
      agent = terminal_agent(workspace)
      agent.enqueue_prompt!(prompt: "Keep the concurrent read", source: "user", id: "concurrent-rebuild-entry")
      batch = agent.open_queue_work_batch!
      File.write(agent.raw_log_path, [
        "=== [2026-10-11 01:02:00] start ===",
        "workspace=#{workspace}",
        "prompt=Continue the fixture.",
        HQ::ManagedAgent::PROCESS_OUTPUT_MARKER,
        JSON.generate("type" => "item.completed", "item" => {
          "type" => "agent_message", "text" => "Fixture complete."
        })
      ].join("\n") + "\n")
      entered = Queue.new
      release = Queue.new
      original = HQ::AgentEventJournal.instance_method(:replace_preserving)
      HQ::AgentEventJournal.define_method(:replace_preserving) do |events, &merger|
        original.bind_call(self, events) do |rebuilt, current|
          entered << true
          release.pop
          merger.call(rebuilt, current)
        end
      end

      rebuild = Thread.new { HQ::AgentChatLog.new(agent).rebuild_memory_from_raw_log! }
      entered.pop
      append = Thread.new { agent.record_queue_read!(batch) }
      release << true
      rebuild.value
      append.value
      reads = queue_read_events(agent, batch.fetch("id"))
      assert(reads.length == 1 && reads.first["event_id"] == batch.fetch("read_id"),
             "expected synchronized rebuild and append to retain one queue-read event")
    ensure
      HQ::AgentEventJournal.define_method(:replace_preserving, original) if defined?(original) && original
    end
  end

  def assert_queue_delivery_rollback_serializes_with_rebuild
    with_queue_store do |registry, workspace|
      agent = terminal_agent(workspace)
      agent.enqueue_prompt!(prompt: "Rollback this staged read", source: "user", id: "rollback-race-entry")
      batch = agent.open_queue_work_batch!
      File.write(agent.raw_log_path, [
        "=== [2026-10-11 01:02:00] start ===",
        "workspace=#{workspace}",
        "prompt=Prior fixture.",
        HQ::ManagedAgent::PROCESS_OUTPUT_MARKER,
        JSON.generate("type" => "item.completed", "item" => {
          "type" => "agent_message", "text" => "Prior rebuild marker."
        })
      ].join("\n") + "\n")
      store = HQ::AgentStore.new(registry.projects)
      store.save([agent])
      previous_codex_bin = ENV["TYCHO_CODEX_BIN"]
      invalid_harness = File.join(workspace, "rollback-missing-interpreter")
      File.write(invalid_harness, "#!/missing/rollback-test-interpreter\n")
      File.chmod(0o755, invalid_harness)
      ENV["TYCHO_CODEX_BIN"] = invalid_harness

      entered = Queue.new
      release = Queue.new
      rebuild_started = Queue.new
      rebuild_done = Queue.new
      calls = 0
      mutex = Mutex.new
      original = HQ::AgentEventJournal.instance_method(:update)
      HQ::AgentEventJournal.define_method(:update) do |&operation|
        call = mutex.synchronize { calls += 1 }
        if call == 2
          original.bind_call(self) do |events|
            entered << true
            release.pop
            operation.call(events)
          end
        else
          original.bind_call(self, &operation)
        end
      end

      start_thread = Thread.new { capture_error { store.start_agent!(agent.key) } }
      entered.pop
      rebuild = Thread.new do
        rebuild_started << true
        result = HQ::AgentChatLog.new(agent).rebuild_memory_from_raw_log!
        rebuild_done << true
        result
      end
      rebuild_started.pop
      blocked = begin
        rebuild_done.pop(true)
        false
      rescue ThreadError
        true
      end
      release << true
      error = start_thread.value
      rebuilt = rebuild.value
      persisted = store.load_with_poll_events(process_delegations: false, dispatch_prompt_queues: false).first.first
      events = HQ::AgentMemory.new(persisted).events
      persisted_batch = persisted.queue_work_batch(batch.fetch("id"))
      assert(blocked && error.is_a?(HQ::ManagedAgent::NativeStartError) && rebuilt.to_i.positive? &&
             persisted_batch.fetch("delivery_count") == 0 && persisted_batch["read_id"].to_s.empty? &&
             queue_read_events(persisted, batch.fetch("id")).empty? &&
             events.any? { |event| event["content"].to_s.include?("Prior rebuild marker") },
             "expected rollback and rebuild to serialize without losing the rebuilt journal")
    ensure
      HQ::AgentEventJournal.define_method(:update, original) if defined?(original) && original
      previous_codex_bin ? ENV["TYCHO_CODEX_BIN"] = previous_codex_bin : ENV.delete("TYCHO_CODEX_BIN")
    end
  end

  def assert_explicit_read_keeps_concurrent_arrivals
    with_queue_store do |registry, workspace|
      agent, pid = running_agent(workspace)
      agent.enqueue_prompt!(prompt: "read this batch", source: "user")
      store = HQ::AgentStore.new(registry.projects)
      store.save([agent])
      entered = Queue.new
      release = Queue.new
      original = HQ::AgentMemory.instance_method(:ensure_queue_read!)
      HQ::AgentMemory.define_method(:ensure_queue_read!) do |*args, **kwargs|
        entered << true
        release.pop
        original.bind_call(self, *args, **kwargs)
      end

      read_thread = Thread.new { store.read_prompt_queue!(agent.key) }
      entered.pop
      arrival_thread = Thread.new do
        HQ::AgentStore.new(registry.projects).enqueue_prompt!(agent.key, prompt: "arrived during read", source: "user")
      end
      release << true
      read_result = read_thread.value
      arrival_thread.value

      persisted = store.load_with_poll_events(process_delegations: false, dispatch_prompt_queues: false).first
                       .find { |candidate| candidate.key == agent.key }
      assert(read_result[:entries].map { |entry| entry["prompt"] } == ["read this batch"] &&
             persisted.active_queue_work["entries"].map { |entry| entry["prompt"] } == ["read this batch"] &&
             persisted.prompt_queue.map { |entry| entry["prompt"] } == ["arrived during read"],
             "expected arrivals after the read snapshot to remain queued for the next batch")
    ensure
      HQ::AgentMemory.define_method(:ensure_queue_read!, original) if defined?(original) && original
      stop_process(pid)
    end
  end

  def assert_concurrent_readers_share_one_open_batch
    with_queue_store do |registry, workspace|
      agent, pid = running_agent(workspace)
      agent.enqueue_prompt!(prompt: "required first", source: "user")
      agent.enqueue_prompt!(prompt: "delegated context", source: "delegation_callback")
      store = HQ::AgentStore.new(registry.projects)
      store.save([agent])

      results = 2.times.map do
        Thread.new { HQ::AgentStore.new(registry.projects).read_prompt_queue!(agent.key) }
      end.map(&:value)
      persisted = store.load_with_poll_events(process_delegations: false, dispatch_prompt_queues: false).first
                       .find { |candidate| candidate.key == agent.key }
      read_events = HQ::AgentMemory.new(persisted).events.select { |event| event.dig("metadata", "queue_read") }
      assert(results.map { |result| result.dig(:batch, "batch_id") }.uniq.length == 1 &&
             results.map { |result| result[:read_id] }.uniq.length == 1 &&
             results.count { |result| result[:idempotent] } == 1 && read_events.length == 1,
             "expected concurrent readers to share one durable open batch and Conversation event")
    ensure
      stop_process(pid)
    end
  end

  def assert_terminal_reports_survive_automatic_callback_dispatch
    %w[stop exit].each do |trigger|
      %w[parent user reclaimed disconnected archived].each do |ownership|
        with_nested_callback_boundary(trigger:, ownership:) do |store, coordinator, middle_key, original_id, agents|
          original = agents.find { |agent| agent.key == middle_key }.runs.find { |run| run.run_id == original_id }
          reports = coordinator.delegation_store.reports.select { |report| report["child_run_id"] == original_id }
          expected = %w[parent archived].include?(ownership) ? 1 : 0
          assert(reports.length == expected,
                 "expected #{expected} prior terminal report before #{trigger} callback dispatch (#{ownership}), got #{reports.length}")
          assert(original.status == "stopped", "expected Stop to retain the original stopped outcome") if trigger == "stop"
          middle = agents.find { |agent| agent.key == middle_key }
          assert(middle.last_run.run_id != original_id, "expected the queued callback to start a distinct successor")
          if expected.positive?
            assert(reports.first["status"] == original.status && reports.first["ownership_generation"] == 1,
                   "expected the report to retain the previous run status and generation")
          end
          if ownership == "disconnected"
            store.set_delegation_connected!(middle_key, connected: true)
          end
          # Repeated polls must deliver the durable report once, never reconstruct
          # an old user-owned, stale-generation, or disconnected run.
          2.times { store.load }
          reports = coordinator.delegation_store.reports.select { |report| report["child_run_id"] == original_id }
          assert(reports.length == expected, "expected terminal report deduplication and suppression to survive replay")
          if ownership == "archived"
            assert(reports.first["resume_state"] == "parent_archived", "expected an archived root to receive history without resuming")
          end
          relation = coordinator.delegation_store.relation_for_child(middle_key)
          expected_stamp = case ownership
                           when "user" then ["user", 2]
                           when "reclaimed" then ["parent", 3]
                           else ["parent", 1]
                           end
          assert(relation.values_at("owner", "ownership_generation") == expected_stamp,
                 "expected report preservation to leave ownership unchanged")
        end
      end
    end
  end

  def assert_report_write_failure_prevents_callback_successor
    with_nested_callback_boundary(trigger: "stop", ownership: "parent", fail_report: true) do |store, coordinator, middle_key, original_id, agents|
      middle = agents.find { |agent| agent.key == middle_key }
      assert(middle.last_run.run_id == original_id && middle.prompt_queue_dispatch_error,
             "expected failed report persistence to keep the old run and retain queued work")
      retried = store.retry_prompt_queue!(middle_key)
      assert(retried.last_run.run_id != original_id, "expected a successful durable retry to start the callback successor")
      2.times { store.load }
      reports = coordinator.delegation_store.reports.select { |report| report["child_run_id"] == original_id }
      assert(reports.length == 1, "expected one prior-run report after retry")
    end
  end

  def with_nested_callback_boundary(trigger:, ownership:, fail_report: false)
    with_stubbed_start do
      fake_start = HQ::ManagedAgent.instance_method(:start!)
      HQ::ManagedAgent.define_method(:start!) do |**options|
        # Keep the real start boundary; replace only native process creation.
        finalize_previous_run!
        fake_start.bind_call(self, **options)
      end
      with_queue_store do |registry, workspace|
        FileUtils.mkdir_p([File.join(workspace, "root"), File.join(workspace, "leaf")])
        root = terminal_agent(File.join(workspace, "root"))
        root.instance_variable_set(:@key, "boundary-root")
        middle, pid = running_agent(workspace)
        original_id = "boundary-original-run"
        middle.last_run.run_id = original_id
        leaf = terminal_agent(File.join(workspace, "leaf"))
        leaf.instance_variable_set(:@key, "boundary-leaf")
        [middle, leaf].each do |agent|
          agent.last_run.delegation_owner = "parent"
          agent.last_run.delegation_generation = 1
        end
        agents = [root, middle, leaf]
        store = HQ::AgentStore.new(registry.projects)
        coordinator = store.delegation_coordinator
        coordinator.attach!(agents:, child: middle, parent_key: root.key)
        coordinator.attach!(agents:, child: leaf, parent_key: middle.key)
        store.save(agents)
        # The real coordinator discovers C and queues the callback while B runs.
        store.load
        service = HQ::RemoteService.new(registry:)
        if %w[user reclaimed].include?(ownership)
          service.submit_prompt(middle.key, "prompt" => "User takes control", "start" => true)
          if ownership == "reclaimed"
            service.submit_prompt(middle.key, "prompt" => "Parent reclaims", "parent_agent_key" => root.key, "start" => true)
          end
        elsif ownership == "disconnected"
          store.set_delegation_connected!(middle.key, connected: false)
        elsif ownership == "archived"
          store.archive_agent!(root.key)
        end
        if fail_report
          ledger = coordinator.delegation_store
          original_record = ledger.method(:record_report!)
          failed = false
          ledger.define_singleton_method(:record_report!) do |child:, **options|
            if !failed && child.last_run&.run_id == original_id && child.effective_status == "stopped"
              failed = true
              raise IOError, "simulated prior terminal report write failure"
            end
            original_record.call(child:, **options)
          end
        end
        if trigger == "exit"
          injected = false
          coordinator.define_singleton_method(:process!) do |loaded, **options|
            result = super(loaded, **options)
            unless injected
              injected = true
              target = loaded.find { |agent| agent.key == middle.key }
              PromptQueueTest.stop_process(pid)
              File.write(target.send(:status_file_path), "0")
              File.write(target.send(:last_message_file_path), JSON.generate("status" => "success", "summary" => "Completed before callback dispatch"))
            end
            result
          end
          loaded = store.load
        else
          store.stop_agent!(middle.key)
          loaded = store.load_with_poll_events(process_delegations: false, dispatch_prompt_queues: false).first
        end
        yield store, coordinator, middle.key, original_id, loaded
      ensure
        stop_process(pid)
      end
    end
  end

  def assert_server_poll_preserves_nested_callback_authority
    [false, true].each do |takeover|
      with_stubbed_start do
        with_queue_store do |registry, workspace|
          root_workspace = File.join(workspace, "root")
          leaf_workspace = File.join(workspace, "leaf")
          FileUtils.mkdir_p([root_workspace, leaf_workspace])
          root = terminal_agent(root_workspace)
          root.instance_variable_set(:@key, "nested-root")
          middle, pid = running_agent(workspace)
          leaf = terminal_agent(leaf_workspace)
          leaf.instance_variable_set(:@key, "nested-leaf")
          [middle, leaf].each do |agent|
            agent.last_run.delegation_owner = "parent"
            agent.last_run.delegation_generation = 1
          end
          agents = [root, middle, leaf]
          store = HQ::AgentStore.new(registry.projects)
          coordinator = store.delegation_coordinator
          coordinator.attach!(agents:, child: middle, parent_key: root.key)
          coordinator.attach!(agents:, child: leaf, parent_key: middle.key)
          store.save(agents)
          service = HQ::RemoteService.new(registry:)

          # Polling discovers C's terminal run and queues its report behind B.
          service.agent(middle.key)
          queued = store.load.find { |agent| agent.key == middle.key }.queued_prompts
          assert(queued.length == 1 && queued.first["source"] == "delegation_callback" &&
                   queued.first["authority"].values_at("owner", "generation") == ["parent", 1],
                 "expected server polling to enqueue a nested callback with B's upstream authority")
          service.submit_prompt(middle.key, "prompt" => "Real user control", "start" => true) if takeover
          stop_process(pid)
          service.agent(middle.key)
          persisted = store.load.find { |agent| agent.key == middle.key }
          expected = takeover ? ["user", 2] : ["parent", 1]
          relation = coordinator.delegation_store.relation_for_child(middle.key)
          assert(relation.values_at("owner", "ownership_generation") == expected &&
                   persisted.last_run.then { |run| [run.delegation_owner, run.delegation_generation] } == expected,
                 "expected automatic server dispatch to preserve nested authority and genuine user takeover")
          entries = persisted.active_queue_work.fetch("entries")
          sources = takeover ? %w[delegation_callback user] : ["delegation_callback"]
          assert(entries.map { |entry| entry["source"] } == sources,
                 "expected server dispatch to keep callback provenance in the complete FIFO batch")
          upstream = coordinator.delegation_store.reports.select { |report| report["parent_agent_key"] == root.key }
          assert(takeover ? upstream.empty? : upstream.any? { |report| report["child_run_id"] == persisted.last_run.run_id },
                 "expected only current parent-owned automatic runs to propagate reports to A")
        ensure
          stop_process(pid)
        end
      end
    end
  end

  def assert_callback_can_start_a_never_run_parent
    with_queue_store do |registry, workspace|
      agent = HQ::ManagedAgent.new(
        key: "queue-agent", name: "Queue agent", project_key: "web", template_key: "custom",
        workspace:, prompt: "Work", agent: "codex", log_path: File.join(workspace, "raw.log")
      )
      agent.enqueue_prompt!(prompt: "first delegated result", source: "delegation_callback")
      store = HQ::AgentStore.new(registry.projects)
      store.save([agent])

      with_stubbed_start { store.load }
      persisted = store.load.find { |candidate| candidate.key == agent.key }
      assert(persisted.run_count == 1 && persisted.active_queue_work &&
             persisted.active_queue_work.dig("entries", 0, "prompt") == "first delegated result",
             "expected a first delegated callback to start a parent with durable open work")
    end
  end

  def assert_legacy_entries_load_without_authority
    with_queue_store do |_registry, workspace|
      agent = terminal_agent(workspace)
      legacy = agent.to_hash.merge("prompt_queue" => [{
        "id" => "legacy-entry", "prompt" => "legacy work", "attachments" => [],
        "accepted_at" => Time.now.utc.iso8601(6)
      }])
      restored = HQ::ManagedAgent.from_hash(legacy)
      entry = restored.queued_prompts.first
      assert(entry["source"].nil? && entry["authority"].nil?,
             "expected legacy queue state to remain readable without invented authority")
    end
  end

  def assert_success_finish_gate_resumes_once_in_same_session
    with_queue_store do |registry, workspace|
      agent = terminal_agent(workspace, status: "success", structured_result: {
        "status" => "success", "summary" => "Finished too early"
      })
      agent.instance_variable_set(:@session_id, "native-session-queue-work")
      agent.instance_variable_set(:@session_bootstrapped, true)
      agent.enqueue_prompt!(prompt: "Do not overlook this instruction", source: "user", id: "required-entry")
      first_run = agent.last_run
      agent.send(:gate_successful_queue_work!, first_run)
      batch = agent.active_queue_work
      assert(first_run.status == "partial" && batch["resume_pending"] == true &&
             first_run.metadata["queue_work_unresolved_entry_ids"] == ["required-entry"],
             "expected a false success to become a gated partial attempt")

      store = HQ::AgentStore.new(registry.projects)
      store.save([agent])
      with_stubbed_start { store.load }
      resumed = store.load_with_poll_events(process_delegations: false, dispatch_prompt_queues: false).first
                     .find { |candidate| candidate.key == agent.key }
      assert(resumed.run_count == 2 && resumed.session_id == "native-session-queue-work" &&
             resumed.active_queue_work["automatic_continuation_count"] == 1,
             "expected one same-session continuation for unresolved work")

      resumed.record_queue_read!(resumed.active_queue_work)
      resumed.structured_result = { "status" => "success", "summary" => "Still incomplete" }
      resumed.send(:gate_successful_queue_work!, resumed.last_run)
      completed = resumed.queue_work_batch(batch["id"])
      assert(resumed.last_run.status != "partial" && resumed.active_queue_work.nil? &&
             completed["state"] == "resolved" &&
             completed.dig("dispositions", "required-entry", "outcome") == "completed" &&
             resumed.last_run.metadata["queue_work_auto_completed"] == true,
             "expected the successful processing run to auto-complete delivered queue work")
    end
  end

  def assert_success_auto_completes_delivered_queue_work
    with_queue_store do |_registry, workspace|
      agent = terminal_agent(workspace, status: "success", structured_result: {
        "status" => "success", "summary" => "Processed the queue"
      })
      agent.enqueue_prompt!(prompt: "Do the requested work", source: "user", id: "user-entry")
      agent.enqueue_prompt!(prompt: "Review report", source: "delegation_callback", id: "report-entry")
      batch = agent.open_queue_work_batch!
      agent.record_queue_read!(batch)

      agent.send(:gate_successful_queue_work!, agent.last_run)
      completed = agent.queue_work_batch(batch["id"])
      assert(agent.last_run.status == "success" && agent.active_queue_work.nil? &&
             completed["state"] == "resolved" &&
             completed.dig("dispositions", "user-entry", "outcome") == "completed" &&
             completed.dig("dispositions", "report-entry", "outcome") == "incorporated",
             "expected a successful delivered batch to receive source-appropriate default outcomes")
    end
  end

  def queued_memory_events(key, store)
    agent = store.load.find { |candidate| candidate.key == key }
    HQ::AgentMemory.new(agent).events.select { |event| event.dig("metadata", "prompt_queue_claim_id") }
  end

  def queue_read_events(agent, batch_id)
    HQ::AgentMemory.new(agent).events.select do |event|
      event.dig("metadata", "queue_read") == true &&
        event.dig("metadata", "queue_work_batch_id").to_s == batch_id.to_s
    end
  end

  def queue_capture_harness(workspace)
    path = File.join(workspace, "capture-codex")
    File.write(path, <<~RUBY)
      #!/usr/bin/env ruby
      File.write(ENV.fetch("TYCHO_TEST_QUEUE_CAPTURE"), ARGV.join("\n"))
    RUBY
    File.chmod(0o755, path)
    path
  end

  def with_captured_outer_spawns(pids)
    original = HQ::ManagedAgent.instance_method(:spawn)
    HQ::ManagedAgent.define_method(:spawn) do |*args, **options|
      pid = original.bind_call(self, *args, **options)
      pids << pid
      pid
    end
    yield
  ensure
    HQ::ManagedAgent.define_method(:spawn, original) if original
  end

  def crash_dispatch_after_store_before_journal(store)
    child_pid = Process.fork do
      original_update = HQ::AgentEventJournal.instance_method(:update)
      HQ::AgentEventJournal.define_method(:update) do |&operation|
        original_update.bind_call(self) do |events|
          operation.call(events)
          Process.exit!(86)
        end
      end
      store.load
      Process.exit!(87)
    rescue StandardError
      Process.exit!(88)
    end
    _waited_pid, status = Process.wait2(child_pid)
    assert(status.exitstatus == 86,
           "expected the first Tycho process to stop after the agent save and before the journal rewrite")
  end

  def crash_dispatch_before_ownership_transfer(store)
    child_pid = Process.fork do
      original_write = File.method(:write)
      File.define_singleton_method(:write) do |path, *args, **options|
        Process.exit!(89) if path.to_s.end_with?(".native-owned")

        original_write.call(path, *args, **options)
      end
      store.load
      Process.exit!(87)
    rescue StandardError
      Process.exit!(88)
    end
    _waited_pid, status = Process.wait2(child_pid)
    assert(status.exitstatus == 89,
           "expected the first Tycho process to stop after durable PID save and before ownership transfer")
  end

  def crash_dispatch_during_rollback_before_journal(store)
    child_pid = Process.fork do
      original_update = HQ::AgentEventJournal.instance_method(:update)
      update_count = 0
      HQ::AgentEventJournal.define_method(:update) do |&operation|
        update_count += 1
        original_update.bind_call(self) do |events|
          result = operation.call(events)
          Process.exit!(90) if update_count == 2

          result
        end
      end
      store.load
      Process.exit!(87)
    rescue StandardError
      Process.exit!(88)
    end
    _waited_pid, status = Process.wait2(child_pid)
    assert(status.exitstatus == 90,
           "expected the first Tycho process to stop after rollback save and before journal removal")
  end

  def process_gone_and_reaped?(pid)
    alive = begin
      Process.kill(0, pid)
      true
    rescue Errno::ESRCH
      false
    end
    reaped = begin
      Process.waitpid(pid, Process::WNOHANG)
      false
    rescue Errno::ECHILD
      true
    end
    !alive && reaped
  end

  def process_alive?(pid)
    Process.kill(0, pid)
    true
  rescue Errno::ESRCH
    false
  end

  def capture_error
    yield
    nil
  rescue StandardError => e
    e
  end

  def wait_for_agent_process(agent)
    pid = agent.pid
    monitor = agent.instance_variable_get(:@process_monitors)&.fetch(pid, nil)
    monitor&.join
    agent.poll!
  end

  def running_agent(workspace)
    pid = Process.spawn(RbConfig.ruby, "-e", "sleep 60", pgroup: true, out: File::NULL, err: File::NULL)
    now = Time.now
    agent = HQ::ManagedAgent.new(
      key: "queue-agent", name: "Queue agent", project_key: "web", template_key: "custom",
      workspace:, prompt: "Work", agent: "codex", pid:, started_at: now,
      runs: [HQ::ManagedAgent::AgentRun.new(started_at: now, status: "running", log_path: File.join(workspace, "raw.log"))],
      log_path: File.join(workspace, "raw.log")
    )
    [agent, pid]
  end

  def terminal_agent(workspace, status: "succeeded", structured_result: nil)
    now = Time.now - 1
    HQ::ManagedAgent.new(
      key: "queue-agent", name: "Queue agent", project_key: "web", template_key: "custom",
      workspace:, prompt: "Work", agent: "codex", started_at: now, finished_at: now,
      last_exit_code: 0, structured_result:,
      runs: [HQ::ManagedAgent::AgentRun.new(started_at: now, finished_at: now, exit_code: 0,
                                            status:, log_path: File.join(workspace, "raw.log"))],
      log_path: File.join(workspace, "raw.log")
    )
  end

  def with_stubbed_start(error: nil, prompts: nil)
    original = HQ::ManagedAgent.instance_method(:start!)
    HQ::ManagedAgent.define_method(:start!) do |delegation_stamp: nil, run_metadata: nil,
                                                   before_spawn: nil, after_spawn: nil,
                                                   before_native_spawn: nil, native_spawn_failed: nil|
      raise error if error

      prompts << send(:prompt_for_execution) if prompts

      now = Time.now
      @started_at = now
      @finished_at = now
      @last_exit_code = 0
      @pid = nil
      @runs << HQ::ManagedAgent::AgentRun.new(
        run_id: SecureRandom.uuid, started_at: now, finished_at: now, exit_code: 0,
        status: "succeeded", log_path: raw_log_path, command: "stubbed",
        delegation_owner: delegation_stamp&.fetch("owner", nil),
        delegation_generation: delegation_stamp&.fetch("generation", nil),
        metadata: run_metadata.is_a?(Hash) ? run_metadata : {}
      )
      before_spawn&.call(@runs.last)
      (before_native_spawn || after_spawn)&.call(@runs.last)
      acknowledge_native_start! if before_native_spawn
      true
    end
    yield
  ensure
    HQ::ManagedAgent.define_method(:start!, original) if original
  end

  def with_stubbed_running_start
    original = HQ::ManagedAgent.instance_method(:start!)
    pids = []
    HQ::ManagedAgent.define_method(:start!) do |delegation_stamp: nil, run_metadata: nil,
                                                   before_spawn: nil, after_spawn: nil,
                                                   before_native_spawn: nil, native_spawn_failed: nil|
      now = Time.now
      pid = Process.spawn(RbConfig.ruby, "-e", "sleep 60", pgroup: true, out: File::NULL, err: File::NULL)
      pids << pid
      run_id = SecureRandom.uuid
      @started_at = now
      @finished_at = nil
      @last_exit_code = nil
      @pid = pid
      @runs << HQ::ManagedAgent::AgentRun.new(
        run_id: run_id, run_scoped_status: true, started_at: now,
        status: "running", log_path: raw_log_path,
        command: "stubbed-running", delegation_owner: delegation_stamp&.fetch("owner", nil),
        delegation_generation: delegation_stamp&.fetch("generation", nil),
        metadata: run_metadata.is_a?(Hash) ? run_metadata : {}
      )
      before_spawn&.call(@runs.last)
      (before_native_spawn || after_spawn)&.call(@runs.last)
      acknowledge_native_start! if before_native_spawn
      true
    end
    yield pids
  ensure
    HQ::ManagedAgent.define_method(:start!, original) if original
    pids&.each { |pid| stop_process(pid) }
  end

  def stop_process(pid)
    return unless pid

    Process.kill("TERM", -pid)
    Process.wait(pid)
  rescue Errno::ESRCH, Errno::EPERM, Errno::ECHILD
    nil
  end

  def with_queue_store
    Dir.mktmpdir("tycho-prompt-queue-test") do |dir|
      old_agents = replace_constant(HQ, :AGENTS_FILE, File.join(dir, "managed_agents.json"))
      old_delegations = replace_constant(HQ, :DELEGATIONS_FILE, File.join(dir, "agent_delegations.json"))
      old_logs = replace_constant(HQ, :AGENT_LOGS_DIR, File.join(dir, "agents"))
      old_archive = replace_constant(HQ, :AGENT_ARCHIVE_DIR, File.join(dir, "agents", "archive"))
      old_usage = replace_constant(HQ, :USAGE_METRICS_FILE, File.join(dir, "usage_metrics.json"))
      old_schedules = replace_constant(HQ, :SCHEDULES_STATE_FILE, File.join(dir, "schedules.json"))
      old_push_subscriptions = replace_constant(HQ, :PUSH_SUBSCRIPTIONS_FILE,
                                                File.join(dir, "push_subscriptions.json"))
      old_push_notifications = replace_constant(HQ, :PUSH_NOTIFICATIONS_FILE,
                                                File.join(dir, "push_notifications.json"))
      old_vapid = replace_constant(HQ, :WEB_PUSH_VAPID_FILE, File.join(dir, "web_push_vapid.json"))
      workspace = File.join(dir, "workspace")
      FileUtils.mkdir_p(workspace)
      FileUtils.mkdir_p(HQ::AGENT_LOGS_DIR)
      FileUtils.mkdir_p(HQ::AGENT_ARCHIVE_DIR)
      registry = queue_registry(dir, workspace)
      yield registry, workspace
    ensure
      replace_constant(HQ, :AGENTS_FILE, old_agents) if old_agents
      replace_constant(HQ, :DELEGATIONS_FILE, old_delegations) if old_delegations
      replace_constant(HQ, :AGENT_LOGS_DIR, old_logs) if old_logs
      replace_constant(HQ, :AGENT_ARCHIVE_DIR, old_archive) if old_archive
      replace_constant(HQ, :USAGE_METRICS_FILE, old_usage) if old_usage
      replace_constant(HQ, :SCHEDULES_STATE_FILE, old_schedules) if old_schedules
      replace_constant(HQ, :PUSH_SUBSCRIPTIONS_FILE, old_push_subscriptions) if old_push_subscriptions
      replace_constant(HQ, :PUSH_NOTIFICATIONS_FILE, old_push_notifications) if old_push_notifications
      replace_constant(HQ, :WEB_PUSH_VAPID_FILE, old_vapid) if old_vapid
    end
  end

  def queue_registry(dir, workspace)
    config = File.join(dir, "hq.yml")
    prompts = File.join(dir, "system_prompts.yml")
    File.write(config, "projects:\n  - key: web\n    name: Web\n    path: #{workspace}\n")
    File.write(prompts, "custom: Work on the queue.\n")
    HQ::Registry.new(path: config, system_prompts_path: prompts)
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

PromptQueueTest.run! if $PROGRAM_NAME == __FILE__
