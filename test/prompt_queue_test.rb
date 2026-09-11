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
    assert_claim_race_drains_fifo_without_overlap
    assert_dispatch_failure_retains_one_prepared_batch_for_retry
    assert_entries_accepted_after_claim_form_a_consecutive_batch
    assert_authority_is_captured_per_fifo_entry
    assert_callback_can_start_a_never_run_parent
    assert_stop_pauses_and_archive_refuses_pending_work
    assert_legacy_entries_load_without_authority
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

  def assert_claim_race_drains_fifo_without_overlap
    with_queue_store do |registry, workspace|
      agent, pid = running_agent(workspace)
      store = HQ::AgentStore.new(registry.projects)
      agent.enqueue_prompt!(prompt: "first accepted")
      agent.enqueue_prompt!(prompt: "second accepted")
      store.save([agent])
      stop_process(pid)

      with_stubbed_start do
        services = [HQ::RemoteService.new(registry:), HQ::RemoteService.new(registry:)]
        2.times.map { |index| Thread.new { services[index].agent(agent.key) } }.each(&:value)
      end

      persisted = store.load.find { |candidate| candidate.key == agent.key }
      assert(persisted.run_count == 3, "expected two FIFO entries to start one serial follow-up run each")
      assert(persisted.queued_prompts.empty?, "expected an accepted claim to be removed")
      assert(persisted.last_run_from_prompt_queue?,
             "expected a queue-dispatched run to retain its queue provenance")
      queued_messages = HQ::AgentMemory.new(persisted).events.select do |event|
        event.dig("metadata", "prompt_queue_claim_id")
      end
      assert(queued_messages.map { |event| event["content"] } == ["first accepted", "second accepted"],
             "expected claims to preserve FIFO order without combining authority-bearing work")
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
      assert(persisted.queued_prompts.empty? && persisted.run_count == 2,
             "expected a successful retry to accept one run and remove the batch")
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
      assert(persisted.run_count == 3 && persisted.queued_prompts.empty?,
             "expected the inquiry answer run to finish before one queued follow-up run starts")
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
        assert(queued[:queued] && queued.dig(:agent, :prompt_queue, "entries").length == 1,
               "expected work accepted after the claim to form the next batch")
      end
      stop_process(follow_up_pid)
      with_stubbed_start { service.agent(agent.key) }

      persisted = store.load.find { |candidate| candidate.key == agent.key }
      messages = queued_memory_events(agent.key, store)
      assert(persisted.run_count == 3 && messages.map { |event| event["content"] } == ["first batch", "next batch"],
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
        assert(current.dig(:prompt_queue, "entries").length == 1,
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
             persisted.run_count == 3 && persisted.queued_prompts.empty?,
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
      with_stubbed_start do
        3.times { service.agent(child.key) }
      end
      persisted = store.load.find { |agent| agent.key == child.key }
      stamps = persisted.runs.last(3).map { |run| [run.delegation_owner, run.delegation_generation] }
      assert(stamps == [["parent", 1], ["user", 2], ["parent", 3]],
             "expected delayed FIFO entries to run under their captured authority, including stale generations")
      authors = queued_memory_events(child.key, store).map { |event| event.dig("metadata", "message_author", "agent_key") }
      assert(authors == [parent.key, nil, parent.key], "expected queued message authorship to survive dispatch")
    ensure
      stop_process(pid)
    end
  end

  def assert_stop_pauses_and_archive_refuses_pending_work
    with_queue_store do |registry, workspace|
      agent, pid = running_agent(workspace)
      store = HQ::AgentStore.new(registry.projects)
      agent.enqueue_prompt!(prompt: "keep after stop")
      store.save([agent])

      stopped = store.stop_agent!(agent.key)
      Process.wait(pid)
      pid = nil
      persisted = store.load.find { |candidate| candidate.key == agent.key }
      assert(stopped.prompt_queue_dispatch_error && persisted.pending_prompts? && persisted.run_count == 1,
             "expected Stop to pause rather than dispatch or discard queued work")
      begin
        store.archive_agent!(agent.key)
        raise "expected archive to refuse queued work"
      rescue ArgumentError => e
        assert(e.message.include?("queued prompts"), "expected an explicit queued-work archive refusal")
      end
      with_stubbed_start { store.retry_prompt_queue!(agent.key) }
      assert(!store.load.find { |candidate| candidate.key == agent.key }.pending_prompts?,
             "expected explicit Retry queue to resume paused work")
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
      assert(persisted.run_count == 1 && !persisted.pending_prompts?,
             "expected a first delegated callback to start a parent that has never run")
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
