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
    assert_delayed_remote_acceptance_is_durable
    assert_due_entries_bypass_future_entries_in_fifo_order
    assert_self_delayed_continuation_preserves_delegation_ownership
    assert_claim_race_drains_fifo_without_overlap
    assert_explicit_read_consumes_one_mixed_batch_and_records_conversation
    assert_explicit_read_failure_retains_queue
    assert_explicit_read_keeps_concurrent_arrivals
    assert_concurrent_readers_share_one_open_batch
    assert_dispatch_failure_retains_one_prepared_batch_for_retry
    assert_entries_accepted_after_claim_form_a_consecutive_batch
    assert_authority_is_captured_per_fifo_entry
    assert_callback_can_start_a_never_run_parent
    assert_normal_stop_dispatches_pending_work
    assert_idle_agent_without_live_pid_dispatches_pending_work
    assert_ineligible_agents_do_not_dispatch_pending_work
    assert_legacy_entries_load_without_authority
    assert_success_finish_gate_resumes_once_in_same_session
    assert_late_status_write_cannot_finish_successor_run
    assert_active_and_restorable_inquiries_block_dispatch
    assert_manual_prompt_retires_inquiry_without_dropping_queue
    puts "prompt_queue_test: ok"
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
      assert(before == 1 && after == 1, "expected retry not to duplicate the prepared ordinary prompt")
      assert(persisted.active_queue_work && persisted.run_count == 2,
             "expected a successful retry to accept one run while retaining the open batch")
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
      agent.enqueue_prompt!(prompt: "wait behind inquiry")
      store = HQ::AgentStore.new(registry.projects)
      store.save([agent])

      service = HQ::RemoteService.new(registry:)
      with_stubbed_start { service.agent(agent.key) }
      restored = HQ::RemoteService.new(registry:).agent(agent.key)
      assert(restored.dig(:prompt_queue, "blocked_by_inquiry") == true &&
             restored.dig(:prompt_queue, "entries").length == 1,
             "expected active and client-dismissed restorable inquiries to retain and block the queue")

      with_stubbed_start do
        service.answer_inquiry(
          agent.key,
          "inquiry-queue-test",
          "answer" => "Use the safe path",
          "start" => true
        )
        service.agent(agent.key)
      end
      persisted = store.load.find { |candidate| candidate.key == agent.key }
      assert(persisted.run_count == 3 && persisted.active_queue_work,
             "expected the inquiry answer run to finish before one durable queued-work run starts")
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
      agent.enqueue_prompt!(prompt: "preserved queued work")
      store = HQ::AgentStore.new(registry.projects)
      store.save([agent])
      service = HQ::RemoteService.new(registry:)

      with_stubbed_start do
        manual = service.submit_prompt(agent.key, "prompt" => "Proceed manually", "start" => true)
        assert(manual.dig(:agent, :prompt_queue, "entries").length == 1,
               "expected a manual ordinary prompt to preserve the suspended queue")
        service.agent(agent.key)
      end

      persisted = store.load.find { |candidate| candidate.key == agent.key }
      events = HQ::AgentMemory.new(persisted).events
      assert(events.any? { |event| event["type"] == "inquiry_cancelled" } &&
             persisted.run_count == 3 && persisted.active_queue_work,
             "expected manual retirement to run first and queued work to dispatch afterward")
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

  def assert_explicit_read_failure_retains_queue
    with_queue_store do |registry, workspace|
      agent, pid = running_agent(workspace)
      agent.enqueue_prompt!(prompt: "retain after read failure", source: "user")
      store = HQ::AgentStore.new(registry.projects)
      store.save([agent])

      original = HQ::AgentMemory.instance_method(:append_queue_read!)
      HQ::AgentMemory.define_method(:append_queue_read!) { |*| raise IOError, "simulated queue read failure" }
      begin
        store.read_prompt_queue!(agent.key)
        raise "expected queue read failure"
      rescue IOError => e
        assert(e.message.include?("simulated queue read failure"), "expected the injected durable read failure")
      ensure
        HQ::AgentMemory.define_method(:append_queue_read!, original)
      end

      persisted = store.load_with_poll_events(process_delegations: false, dispatch_prompt_queues: false).first
                       .find { |candidate| candidate.key == agent.key }
      assert(persisted.queued_prompts.map { |entry| entry["prompt"] } == ["retain after read failure"],
             "expected a failed explicit read to leave every queue entry durable")
    ensure
      HQ::AgentMemory.define_method(:append_queue_read!, original) if defined?(original) && original
      stop_process(pid)
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
      original = HQ::AgentMemory.instance_method(:append_queue_read!)
      HQ::AgentMemory.define_method(:append_queue_read!) do |*args, **kwargs|
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
      HQ::AgentMemory.define_method(:append_queue_read!, original) if defined?(original) && original
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

      resumed.structured_result = { "status" => "success", "summary" => "Still incomplete" }
      resumed.send(:gate_successful_queue_work!, resumed.last_run)
      assert(resumed.last_run.status == "partial" && resumed.active_queue_work["resume_pending"] == false,
             "expected a second unresolved finish to stay visible without an uncontrolled loop")
    end
  end

  def queued_memory_events(key, store)
    agent = store.load.find { |candidate| candidate.key == key }
    HQ::AgentMemory.new(agent).events.select { |event| event.dig("metadata", "prompt_queue_claim_id") }
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

  def with_stubbed_start(error: nil)
    original = HQ::ManagedAgent.instance_method(:start!)
    HQ::ManagedAgent.define_method(:start!) do |delegation_stamp: nil, run_metadata: nil|
      raise error if error

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
      true
    end
    yield
  ensure
    HQ::ManagedAgent.define_method(:start!, original) if original
  end

  def with_stubbed_running_start
    original = HQ::ManagedAgent.instance_method(:start!)
    pids = []
    HQ::ManagedAgent.define_method(:start!) do |delegation_stamp: nil, run_metadata: nil|
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
      old_usage = replace_constant(HQ, :USAGE_METRICS_FILE, File.join(dir, "usage_metrics.json"))
      old_schedules = replace_constant(HQ, :SCHEDULES_STATE_FILE, File.join(dir, "schedules.json"))
      workspace = File.join(dir, "workspace")
      FileUtils.mkdir_p(workspace)
      FileUtils.mkdir_p(HQ::AGENT_LOGS_DIR)
      registry = queue_registry(dir, workspace)
      yield registry, workspace
    ensure
      replace_constant(HQ, :AGENTS_FILE, old_agents) if old_agents
      replace_constant(HQ, :DELEGATIONS_FILE, old_delegations) if old_delegations
      replace_constant(HQ, :AGENT_LOGS_DIR, old_logs) if old_logs
      replace_constant(HQ, :USAGE_METRICS_FILE, old_usage) if old_usage
      replace_constant(HQ, :SCHEDULES_STATE_FILE, old_schedules) if old_schedules
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
