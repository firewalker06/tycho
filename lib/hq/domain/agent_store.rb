# frozen_string_literal: true

require_relative "constants"
require_relative "file_transaction"
require_relative "file_store"
require_relative "agent_store_recovery"
require_relative "agent_archive_store"
require_relative "agent_attachment_store"
require_relative "managed_agent"
require_relative "delegation_coordinator"
require_relative "schedule_store"
require_relative "visibility"
require_relative "../ui/rendering/styles"
require "securerandom"
require "shellwords"

module HQ
  class AgentStore
    StaleScheduleTarget = Class.new(StandardError)
    PALETTE_SIZE = HQ::UI::Rendering::Styles::CHAT_BORDER_PALETTE.length
    SCHEDULE_SYSTEM_PROMPT_TEMPLATE = [
      "This managed agent is owned by the Tycho schedule %{title}.",
      "Treat each scheduled user message as one recurring run in the same long-lived session.",
      "Use prior session context when it helps, but make each run's outcome clear and operator-facing.",
      "When a run reviews or changes a pull request, attach its canonical GitHub pull request URL and state the outcome briefly.",
      ManagedAgent::NO_ACTION_STATUS_GUIDANCE,
      "If you need human input, ask a precise structured inquiry and stop instead of guessing."
    ].join("\n")
    PollEvent = Struct.new(:agent_key, :from_status, :to_status, :run_count, keyword_init: true)

    def self.scheduled_system_prompt_template
      SCHEDULE_SYSTEM_PROMPT_TEMPLATE
    end

    def self.schedule_system_prompt(schedule_key:, name:, system_message: nil)
      custom = system_message.to_s.strip
      return custom unless custom.empty?

      label = name.to_s.strip
      title = label.empty? ? schedule_key.to_s : "#{label} (#{schedule_key})"
      format(scheduled_system_prompt_template, title:)
    end

    attr_reader :delegation_coordinator

    def initialize(projects, usage_metrics_store: nil, delegation_coordinator: nil, recovery: nil)
      @projects = projects
      @usage_metrics_store = usage_metrics_store || UsageMetrics.store(
        path: File.join(File.dirname(AGENTS_FILE), "usage_metrics.json")
      )
      @delegation_coordinator = delegation_coordinator || DelegationCoordinator.new
      @recovery = recovery || AgentStoreRecovery.new(store_path: AGENTS_FILE)
    end

    def load
      agents, = load_with_poll_events
      agents
    end

    def load_with_poll_events(process_delegations: true, dispatch_prompt_queues: true)
      with_exclusive_lock do
        load_with_poll_events_unlocked(process_delegations:, dispatch_prompt_queues:)
      end
    end

    def mutate(dispatch_prompt_queues: true)
      with_exclusive_lock do
        agents, events = load_with_poll_events_unlocked(dispatch_prompt_queues:)
        result = yield agents, events
        save_unlocked(agents)
        result
      end
    end

    def load_with_poll_events_unlocked(process_delegations: true, dispatch_prompt_queues: true)
      return [[], []] unless File.exist?(AGENTS_FILE)

      changed = false
      events = []
      schedule_states = ScheduleStore.new.load
      schedule_keys = schedule_keys_by_agent(schedule_states)
      raw_records = Array(FileStore.read_json(AGENTS_FILE, fallback: []))
      raw_records, recovered = @recovery.reconcile_loaded(raw_records)
      changed = recovered
      agents = raw_records.map do |hash|
        agent = ManagedAgent.from_hash(hash)
        agent.usage_metrics_store = @usage_metrics_store
        if agent.missing_native_session_identity?
          HQ.logger.warn("AgentStore") do
            "#{agent.key} has prior #{agent.agent} runs without a recoverable native session ID; " \
              "its next run will start fresh"
          end
        end
        changed = true if hash != agent.to_hash
        if agent.schedule_key.nil? && schedule_keys.key?(agent.key)
          agent.associate_schedule!(schedule_keys.fetch(agent.key))
          changed = true
        end
        project = project_for(agent.project_key)
        changed = agent.reconcile_project_group!(project.group) || changed if project
        before_hash = agent.to_hash
        was_running = running_for_poll_event?(agent)
        agent.poll!
        changed = true if before_hash != agent.to_hash
        if (completed_claim = agent.dispatched_prompt_queue_claim)
          mark_claim_reports_resumed!(completed_claim)
          agent.complete_prompt_queue_claim!
          changed = true
        end
        if was_running && !running_for_poll_event?(agent) && !agent.active_queue_work&.fetch("resume_pending", false)
          delegation_stamp = @delegation_coordinator.ownership_stamp(agent.key)
          unless agent.no_action_needed? || agent.suppresses_operator_attention?(delegation_stamp:)
            agent.mark_unread!
            changed = true
            events << PollEvent.new(
              agent_key: agent.key,
              from_status: "running",
              to_status: agent.status,
              run_count: agent.run_count
            )
          end
        end
        changed = backfill_project_context_prompt!(agent) || changed
        changed = backfill_agent_system_context_prompt!(agent) || changed
        agent
      end
      changed = backfill_color_indexes!(agents) || changed
      changed = backfill_delegation_parents!(agents) || changed
      agents.each { |agent| changed = materialize_sleep_recovery!(agent) || changed }
      changed = @delegation_coordinator.process!(agents) || changed if process_delegations
      changed = dispatch_prompt_queues!(agents, schedule_states:) || changed if dispatch_prompt_queues
      save_unlocked(agents) if changed
      [agents, events]
    rescue StandardError => e
      HQ.logger.warn("AgentStore") { "Failed to load agents from #{AGENTS_FILE}: #{e.class} - #{e.message}" }
      raise if e.is_a?(IOError) || e.is_a?(DelegationStore::Error)

      [[], []]
    end

    def save(agents)
      with_exclusive_lock { save_unlocked(agents) }
    end

    def save_unlocked(agents, allow_retired_keys: false, allow_large_reduction: false)
      current = File.exist?(AGENTS_FILE) ? Array(FileStore.read_json(AGENTS_FILE, fallback: [])) : []
      records = @recovery.prepare(
        agents.map(&:to_hash),
        current_records: current,
        allow_retired_keys:,
        allow_large_reduction:
      )
      FileStore.write_json(AGENTS_FILE, records)
      @recovery.after_save(records, allow_retired_keys:)
    end

    def create_for_project(project)
      create_from_template(project, project.agent_templates.first.key)
    end

    def create_from_template(project, template_key, existing_agents: nil)
      existing = existing_agents || load
      suffix = next_suffix(project.key, existing)
      now = Time.now
      key = next_agent_key(project.key, existing, now:)
      template = template_for(project, template_key)
      agent = ManagedAgent.new(
        key: key,
        name: "#{project.name} #{template.name.downcase} #{suffix}",
        project_key: project.key,
        project_group: project.group,
        template_key: template.key,
        workspace: project.path,
        prompt: template.prompt,
        created_at: now,
        sandbox_mode: template.sandbox_mode,
        agent: template.agent,
        model: template.model,
        reasoning_effort: template.reasoning_effort,
        response_style: template.response_style,
        messages: system_messages_for(project, template.prompt),
        color_index: next_color_index(existing)
      )
      seed_memory_system_prompts!(agent, project, template.prompt)
      attach_usage_metrics_store(agent)
    end

    # Keep the read, construction, and commit of a new agent in one store
    # transaction so a concurrent foreground write cannot be overwritten by a
    # worker's stale agent list.
    def create_from_template_and_persist!(project, template_key, delegation: nil)
      mutate(dispatch_prompt_queues: false) do |agents, _events|
        target = create_from_template(project, template_key, existing_agents: agents)
        yield target, agents if block_given?
        if delegation
          delegation[:validate]&.call(agents)
          persist_created_delegation!(agents, target, delegation)
        else
          agents.unshift(target)
        end
        target
      end
    end

    def update_agent!(key)
      mutate(dispatch_prompt_queues: false) do |agents, _events|
        target = find_agent_in!(agents, key)
        yield target, agents if block_given?
        target
      end
    end

    def create_scheduled(project, schedule_key:, name:, system_message: nil, execution_overrides: {}, existing_agents: load)
      now = Time.now
      key = next_agent_key(project.key, existing_agents, now:)
      prompt = scheduled_system_prompt(schedule_key:, name:, system_message:)
      system_messages = system_messages_for(project, prompt)
      agent = ManagedAgent.new(
        key: key,
        name: scheduled_agent_name(project, schedule_key:, name:),
        project_key: project.key,
        project_group: project.group,
        template_key: "scheduled",
        workspace: project.path,
        prompt: prompt,
        sandbox_mode: "danger-full-access",
        agent: execution_overrides[:agent] || (project.respond_to?(:agent) ? project.agent : project.config.agent),
        model: execution_overrides[:model] || (project.respond_to?(:model) ? project.model : project.config.model),
        reasoning_effort: execution_overrides[:reasoning_effort] || (project.respond_to?(:reasoning_effort) ? project.reasoning_effort : project.config.reasoning_effort),
        response_style: project.respond_to?(:response_style) ? project.response_style : project.config.response_style,
        messages: system_messages,
        created_at: now,
        color_index: next_color_index(existing_agents),
        schedule_key: schedule_key
      )
      seed_memory_system_prompts!(agent, project, prompt)
      attach_usage_metrics_store(agent)
    end

    def add_scheduled_message!(agent, schedule_key:, message:, due_at: nil)
      agent.associate_schedule!(schedule_key)
      metadata = {
        "schedule_key" => schedule_key,
        "scheduled_prompt" => true,
        "scheduled_due_at" => due_at&.iso8601
      }.compact
      agent.add_user_message!(
        message,
        metadata: metadata
      )
    end

    def associate_delegation!(agents:, child:, parent_key:, parent_server_id: nil, now: Time.now)
      @delegation_coordinator.attach!(
        agents:,
        child:,
        parent_key:,
        parent_server_id:,
        now:
      )
    end

    def persist_with_delegation!(agents:, child:, parent_key: nil, parent_server_id: nil, creating: false, actor: nil)
      key = parent_key.to_s.strip
      with_exclusive_lock do
        current, = load_with_poll_events_unlocked(process_delegations: false)
        index = current.index { |agent| agent.key == child.key }
        if !index && creating
          current.unshift(child)
        elsif !index
          raise ArgumentError, "Unknown agent: #{child.key}"
        else
          child = current[index]
        end
        if key.empty?
          save_unlocked(current) if creating
          agents.replace(current)
          return child
        end

        if actor&.parent? && actor.agent_key != key
          raise DelegationStore::Error, "An agent can delegate only as itself"
        end

        parent = current.find { |agent| agent.key == key }
        paths = [AGENTS_FILE, DELEGATIONS_FILE, child.memory_path, parent&.memory_path].compact
        FileTransaction.run(paths) do
          _relation, created = associate_delegation!(agents: current, child:, parent_key: key, parent_server_id:)
          @delegation_coordinator.accept_prompt!(child:, owner: "user") if created && actor&.user?
          save_unlocked(current)
        end
        agents.replace(current)
        child
      end
    end

    def restore_archived_agents!(archived_agents)
      with_exclusive_lock do
        current, = load_with_poll_events_unlocked(process_delegations: false)
        existing = current.to_h { |agent| [agent.key, true] }
        additions = Array(archived_agents).reject { |agent| existing[agent.key] }
        save_unlocked(current + additions, allow_retired_keys: true) unless additions.empty?
      end
    end

    def backups
      with_exclusive_lock { @recovery.backups }
    end

    def restore_backup!(path)
      with_exclusive_lock { @recovery.restore!(path) }
    end

    def start_agent!(key, run_metadata: nil, prefer_queued: false)
      mutate(dispatch_prompt_queues: false) do |agents, _events|
        target = agents.find { |agent| agent.key == key.to_s }
        raise ArgumentError, "Unknown agent: #{key}" unless target

        target.cancel_pending_sleep_recovery!
        unless target.running?
          if prefer_queued && target.pending_prompts?
            target.clear_prompt_queue_dispatch_error!
            dispatch_prompt_queue!(target, agents)
          else
            start_target!(target, agents, run_metadata:)
          end
        end
        target
      end
    end

    # Run schedule acceptance and process start under one AgentStore lock.
    # Archive removes the target under this same lock, so an archived target
    # cannot receive a stale schedule message or start a harness.
    def dispatch_scheduled_message!(key, schedule_key:, message:, due_at: nil)
      mutate(dispatch_prompt_queues: false) do |agents, _events|
        target = find_agent_in!(agents, key)
        state = ScheduleStore.new.load[schedule_key.to_s]
        current_target = state&.last_target_key.to_s
        if !current_target.empty? && current_target != target.key
          raise StaleScheduleTarget,
                "Schedule #{schedule_key.inspect} now targets agent #{current_target.inspect}"
        end
        add_scheduled_message!(target, schedule_key:, message:, due_at:)
        start_target!(target, agents, run_metadata: nil) unless target.running?
        target
      end
    end

    # Create, record, and start a new scheduled session from the current store
    # state. A scheduler tick must never save its old agent snapshot here.
    def create_and_dispatch_scheduled!(project, schedule_key:, name:, message:, due_at: nil,
                                       system_message: nil, execution_overrides: {})
      start_error = nil
      target = mutate(dispatch_prompt_queues: false) do |agents, _events|
        target = create_scheduled(
          project, schedule_key:, name:, system_message:, execution_overrides:, existing_agents: agents
        )
        agents.unshift(target)
        add_scheduled_message!(target, schedule_key:, message:, due_at:)
        yield target if block_given?
        begin
          start_target!(target, agents, run_metadata: nil)
        rescue StandardError => e
          start_error = e
        end
        target
      end
      raise start_error if start_error

      target
    end

    # Accept active work or record its terminal archive result while holding the
    # same lock used by archive. Every active mutation stays inside this method
    # so callers cannot keep and later save a stale agent snapshot.
    def accept_or_abort_prompt!(key, prompt:, actor:, event_id:, archive_metadata: {}, message_metadata: {},
                                attachments: nil, delayed: false, delay: nil, client_request_id: nil,
                                source: nil, retire_inquiry_id: nil, start: false, parent_server_id: nil,
                                attachment_importer: nil)
      with_exclusive_lock do
        agents, = load_with_poll_events_unlocked(process_delegations: false, dispatch_prompt_queues: false)
        target = agents.find { |agent| agent.key == key.to_s }
        unless target
          return record_archived_prompt_unlocked!(
            key, prompt:, attachments:, actor:, event_id:, metadata: archive_metadata, active_agents: agents
          )
        end

        paths = [AGENTS_FILE, DELEGATIONS_FILE, target.memory_path, target.attachments_path]
        parent = active_prompt_parent_unlocked!(target, agents, actor:)
        paths << parent.memory_path if parent
        FileTransaction.run(paths.compact) do |transaction|
          replay = prompt_replay_unlocked(target, event_id)
          result = replay || accept_active_prompt_unlocked!(
            target, agents, prompt:, actor:, event_id:, message_metadata:, attachments:,
            delayed:, delay:, client_request_id:, source:, retire_inquiry_id:, start:, parent_server_id:,
            attachment_importer:, transaction:
          )
          record_accepted_agent_send!(
            parent:, target:, prompt:, event_id:, result:
          ) if actor&.parent? && !result.fetch(:replayed)
          save_unlocked(agents)
          result
        end
      end
    end

    def record_archived_prompt_attempt!(key, prompt:, actor:, event_id:, metadata: {})
      with_exclusive_lock do
        agents, = load_with_poll_events_unlocked(process_delegations: false, dispatch_prompt_queues: false)
        return :active if agents.any? { |agent| agent.key == key.to_s }

        record_archived_prompt_unlocked!(
          key, prompt:, attachments: nil, actor:, event_id:, metadata:, active_agents: agents
        )
        :archived
      end
    end

    def start_target!(target, agents, run_metadata:)
      options = {}
      stamp = @delegation_coordinator.ownership_stamp(target.key)
      options[:delegation_stamp] = stamp if stamp
      options[:run_metadata] = run_metadata if run_metadata
      if target.method(:start!).parameters.any? { |_kind, name| name == :before_spawn }
        options[:before_spawn] = ->(_run) { save_unlocked(agents) }
      end
      target.start!(**options)
    end

    def accept_delegation_prompt!(child, owner:, parent_key: nil, now: Time.now)
      @delegation_coordinator.accept_prompt!(child:, owner:, parent_key:, now:)
    end

    def accept_prompt_from!(child, actor:, agents: nil, now: Time.now)
      if agents
        return accept_prompt_from_unlocked!(child, actor:, now:)
      end

      mutate(dispatch_prompt_queues: false) do |current, _events|
        target = find_agent_in!(current, child.key)
        accept_prompt_from_unlocked!(target, actor:, now:)
      end
    end

    def stop_agent!(key)
      mutate(dispatch_prompt_queues: false) do |agents, _events|
        target = agents.find { |agent| agent.key == key.to_s }
        raise ArgumentError, "Unknown agent: #{key}" unless target

        target.stop! if target.running?
        dispatch_prompt_queue!(target, agents) if prompt_queue_dispatchable?(target, ScheduleStore.new.load)
        target
      end
    end

    def enqueue_prompt!(key, prompt:, attachments: nil, accepted_at: nil, id: nil, client_request_id: nil,
                        authority: nil, message_metadata: nil, source: nil)
      mutate do |agents, _events|
        target = agents.find { |agent| agent.key == key.to_s }
        raise ArgumentError, "Unknown agent: #{key}" unless target
        raise ArgumentError, "Agent is no longer running" unless target.running?

        attributes = { prompt:, attachments:, accepted_at: accepted_at || Time.now, authority:, message_metadata:, source: }
        attributes[:id] = id if id
        attributes[:client_request_id] = client_request_id if client_request_id
        [target, target.enqueue_prompt!(**attributes)]
      end
    end

    def enqueue_prompt_from!(key, prompt:, attachments: nil, actor:, accepted_at: nil, id: nil,
                             client_request_id: nil, message_metadata: nil, source: nil, not_before: nil,
                             require_running: true)
      with_exclusive_lock do
        agents, = load_with_poll_events_unlocked(process_delegations: false, dispatch_prompt_queues: false)
        target = find_agent_in!(agents, key)
        raise ArgumentError, "Agent is no longer running" if require_running && !target.running?

        FileTransaction.run([AGENTS_FILE, DELEGATIONS_FILE, target.memory_path]) do
          entry = enqueue_prompt_from_unlocked!(
            target, prompt:, attachments:, actor:, accepted_at:, id:, client_request_id:,
            message_metadata:, source:, not_before:
          )
          save_unlocked(agents)
          [target, entry]
        end
      end
    end

    def enqueue_delayed_prompt_from!(key, prompt:, actor:, delay:, id: nil, source: nil)
      seconds = begin
        Float(delay)
      rescue ArgumentError, TypeError
        raise ArgumentError, "Delay must be a non-negative number"
      end
      raise ArgumentError, "Delay must be zero or greater" if seconds.negative?

      accepted_at = Time.now
      enqueue_prompt_from!(
        key,
        prompt:,
        actor:,
        accepted_at:,
        not_before: accepted_at + seconds,
        id:,
        source: source || (actor.internal? ? "internal_continuation" : actor.parent? ? "parent" : "user"),
        message_metadata: { "delayed_send" => true },
        require_running: false
      )
    end

    def edit_queued_prompt!(key, entry_id, prompt:)
      mutate(dispatch_prompt_queues: false) do |agents, _events|
        target = agents.find { |agent| agent.key == key.to_s }
        raise ArgumentError, "Unknown agent: #{key}" unless target

        [target, target.edit_queued_prompt!(entry_id, prompt:)]
      end
    end

    def delete_queued_prompt!(key, entry_id)
      mutate(dispatch_prompt_queues: false) do |agents, _events|
        target = agents.find { |agent| agent.key == key.to_s }
        raise ArgumentError, "Unknown agent: #{key}" unless target

        [target, target.delete_queued_prompt!(entry_id)]
      end
    end

    def retry_prompt_queue!(key)
      mutate do |agents, _events|
        target = agents.find { |agent| agent.key == key.to_s }
        raise ArgumentError, "Unknown agent: #{key}" unless target
        raise ArgumentError, "No queued dispatch is waiting for retry" unless target.prompt_queue_dispatch_error
        raise ArgumentError, "An inquiry must be resolved before retrying queued work" if target.inquiry_blocking_prompt_queue?

        target.clear_prompt_queue_dispatch_error!
        target.active_queue_work["resume_pending"] = true if target.active_queue_work && !target.prompt_queue_claim
        dispatch_prompt_queue!(target, agents)
        target
      end
    end

    def discard_prompt_queue!(key, reason: nil)
      mutate do |agents, _events|
        target = agents.find { |agent| agent.key == key.to_s }
        raise ArgumentError, "Unknown agent: #{key}" unless target
        raise ArgumentError, "An inquiry must be resolved before discarding queued work" if target.inquiry_blocking_prompt_queue?

        result = target.discard_failed_prompt_queue!(reason: reason)
        dispatch_prompt_queue!(target, agents)
        result.merge("agent" => target)
      end
    end

    def process_prompt_queue_entries!(key, entry_ids:, expected_entry_ids:)
      mutate(dispatch_prompt_queues: false) do |agents, _events|
        target = find_agent_in!(agents, key)
        raise ArgumentError, "Agent is running" if target.running?

        current_ids = target.visible_prompt_queue_entries.map { |entry| entry["id"].to_s }
        expected = Array(expected_entry_ids).map(&:to_s)
        unless expected == current_ids
          next({ "status" => "stale", "expected_entry_ids" => expected, "current_entry_ids" => current_ids,
                 "processed_entry_ids" => [], "agent" => target })
        end
        selected_ids = target.validate_queue_entry_ids!(entry_ids)
        target.cancel_pending_inquiry! if target.inquiry_blocking_prompt_queue?
        selected = target.prepare_queue_entries_for_processing!(selected_ids)
        dispatch_prompt_queue!(target, agents)
        {
          "status" => target.running? ? "started" : "accepted",
          "processed_entry_ids" => selected,
          "current_entry_ids" => target.visible_prompt_queue_entries.map { |entry| entry["id"].to_s },
          "agent" => target
        }
      end
    end

    def remove_prompt_queue_entries!(key, entry_ids:, expected_entry_ids:, reason: nil)
      mutate(dispatch_prompt_queues: false) do |agents, _events|
        target = find_agent_in!(agents, key)
        raise ArgumentError, "Agent is running" if target.running?

        current_ids = target.visible_prompt_queue_entries.map { |entry| entry["id"].to_s }
        expected = Array(expected_entry_ids).map(&:to_s)
        unless expected == current_ids
          next({ "status" => "stale", "expected_entry_ids" => expected, "current_entry_ids" => current_ids,
                 "removed_entry_ids" => [], "agent" => target })
        end
        result = target.remove_queue_entries!(entry_ids, reason:)
        result.merge("status" => "removed", "current_entry_ids" => target.visible_prompt_queue_entries.map do |entry|
          entry["id"].to_s
        end, "agent" => target)
      end
    end

    def read_prompt_queue!(key, read_at: Time.now)
      with_exclusive_lock do
        agents, = load_with_poll_events_unlocked(process_delegations: false, dispatch_prompt_queues: false)
        target = find_agent_in!(agents, key)
        paths = [AGENTS_FILE, DELEGATIONS_FILE, target.memory_path, target.attachments_path]
        result = nil
        FileTransaction.run(paths) do
          claim = target.prompt_queue_claim
          failed_claim = claim && target.prompt_queue_dispatch_error
          raise ArgumentError, "Queued work is already claimed for dispatch" if claim && !failed_claim
          batch = if failed_claim
                    target.queue_work_batch(claim.fetch("id"))
                  else
                    target.active_queue_work || target.open_queue_work_batch!(opened_at: read_at)
                  end
          raise ArgumentError, "No pending queue entries for #{target.key}" unless batch

          result = target.record_queue_read!(batch, created_at: read_at)
          mark_claim_reports_resumed!("entries" => result[:entries]) unless result[:idempotent]
          save_unlocked(agents)
          result[:agent] = target
        end
        result
      end
    end

    def complete_queue_work!(key, batch_id:, dispositions:, completed_at: Time.now)
      with_exclusive_lock do
        agents, = load_with_poll_events_unlocked(process_delegations: false, dispatch_prompt_queues: false)
        target = find_agent_in!(agents, key)
        result = target.complete_queue_work!(batch_id, dispositions, completed_at:)
        save_unlocked(agents)
        result.merge("agent" => target)
      end
    end

    def suspend_inquiry!(key, inquiry_id)
      mutate do |agents, _events|
        target = find_agent_in!(agents, key)
        raise ArgumentError, "Inquiry has changed; refresh and try again" unless target.suspend_inquiry!(inquiry_id)

        target
      end
    end

    def restore_inquiry!(key, inquiry_id)
      mutate do |agents, _events|
        target = find_agent_in!(agents, key)
        raise ArgumentError, "Inquiry is no longer restorable; refresh and try again" unless target.restore_inquiry!(inquiry_id)

        target
      end
    end

    def accept_ordinary_prompt!(key, text:, attachments:, actor:, retire_inquiry_id: nil, metadata: nil, event_id: nil)
      mutate(dispatch_prompt_queues: false) do |agents, _events|
        target = find_agent_in!(agents, key)
        accept_ordinary_prompt_unlocked!(
          target, text:, attachments:, actor:, retire_inquiry_id:, metadata:, event_id:
        )
      end
    end

    def answer_inquiry!(key, inquiry_id:, answer:, attachments:, feedback: nil, feedback_embedded: false, metadata: nil, event_id_prefix: nil)
      mutate(dispatch_prompt_queues: false) do |agents, _events|
        target = find_agent_in!(agents, key)
        expected_id = target.latest_inquiry_id.to_s
        if expected_id.empty? || inquiry_id.to_s != expected_id
          raise ArgumentError, "Inquiry has changed; refresh and try again"
        end

        accept_delegation_prompt!(target, owner: "user")
        target.add_user_message!(answer, inquiry_id: expected_id, attachments:, metadata:, event_id: event_id_prefix)
        unless feedback_embedded || feedback.to_s.empty?
          feedback_metadata = { "inquiry_feedback" => true }
          feedback_metadata.merge!(metadata) if metadata.is_a?(Hash)
          feedback_event_id = event_id_prefix.to_s.empty? ? nil : "#{event_id_prefix}:feedback"
          target.add_user_message!(feedback, metadata: feedback_metadata, event_id: feedback_event_id)
        end
        include_pending_queue_work_with_user_input!(target)
        target
      end
    end

    def archive_agent!(key, root: AGENT_ARCHIVE_DIR)
      archive_agents!([key], root:).fetch(key.to_s)
    end

    def archive_agents!(keys, root: AGENT_ARCHIVE_DIR)
      with_exclusive_lock do
        agents, = load_with_poll_events_unlocked(process_delegations: false, dispatch_prompt_queues: false)
        requested = Array(keys).map(&:to_s).uniq
        targets = requested.map do |key|
          agents.find { |agent| agent.key == key } || raise(ArgumentError, "Unknown agent: #{key}")
        end
        source_paths = targets.flat_map(&:log_files)
        transaction = FileTransaction.new([AGENTS_FILE, DELEGATIONS_FILE, *source_paths])
        destinations = targets.to_h do |target|
          run_aborted = target.running?
          target.retire_for_archive!
          archived_work = target.archive_pending_work!(run_aborted:)
          target.mark_archived_visibility!(!HQ::Visibility.agent_visible?(target, @projects))
          destination = target.archive_logs!(root)
          transaction.on_rollback { remove_failed_archive(destination) }
          reconcile_archived_callbacks(archived_work.fetch(:entries))
          [target.key, destination]
        end
        save_unlocked(
          agents.reject { |agent| requested.include?(agent.key) },
          allow_large_reduction: true
        )
        destinations
      rescue StandardError
        transaction&.rollback
        raise
      end
    end

    def reconcile_archived_callbacks(entries)
      report_ids = Array(entries).flat_map do |entry|
        metadata = entry["message_metadata"] || {}
        reports = Array(metadata["delegation_reports"])
        reports << metadata["delegation_report"] if reports.empty? && metadata["delegation_report"].is_a?(Hash)
        reports.filter_map { |report| report["id"] }
      end
      report_ids.each do |report_id|
        @delegation_coordinator.delegation_store.update_report!(report_id, resume_state: "parent_archived")
      end
    end

    def delegation_relationships(agent_key)
      @delegation_coordinator.relationships_for(agent_key)
    end

    def set_delegation_connected!(child_key, connected:, now: Time.now)
      with_exclusive_lock do
        agents, = load_with_poll_events_unlocked(process_delegations: false)
        child = agents.find { |agent| agent.key == child_key.to_s }
        raise ArgumentError, "Unknown agent: #{child_key}" unless child
        yield child if block_given?

        relation, counts, changed = @delegation_coordinator.set_connected!(
          child_key: child.key,
          connected:,
          now:
        )
        [child, relation, counts, changed]
      end
    end

    def clone_agent(agent, existing_agents: load)
      now = Time.now
      key = next_agent_key(agent.project_key, existing_agents, now:)
      attach_usage_metrics_store(ManagedAgent.new(
        key: key,
        name: agent.name,
        project_key: agent.project_key,
        project_group: agent.project_group,
        template_key: agent.template_key,
        workspace: agent.workspace,
        prompt: agent.prompt,
        created_at: now,
        sandbox_mode: agent.sandbox_mode,
        agent: agent.agent,
        model: agent.model,
        reasoning_effort: agent.reasoning_effort,
        response_style: agent.response_style,
        skills: agent.skills,
        color_index: next_color_index(existing_agents)
      ))
    end

    def replace_scheduled_target!(source_key, target, schedule_registry:, schedule_store:,
                                  expected_schedule_key: nil, &prepare)
      schedule_store.with_lock do
        with_exclusive_lock do
          agents, = load_with_poll_events_unlocked(process_delegations: false, dispatch_prompt_queues: false)
          source = find_agent_in!(agents, source_key)
          schedule_key = source.schedule_key.to_s
          raise ArgumentError, "Agent #{source.key} is not connected to a schedule" if schedule_key.empty?
          if expected_schedule_key && schedule_key != expected_schedule_key.to_s
            raise StaleScheduleTarget,
                  "Agent #{source.key} now belongs to schedule #{schedule_key.inspect}, not #{expected_schedule_key.inspect}"
          end
          raise ArgumentError, "Stop the running scheduled agent before starting a replacement" if source.running?
          if source.pending_prompts?
            raise ArgumentError, "Scheduled session #{source.key.inspect} has queued work; let it drain before replacing it"
          end
          if source.inquiry_blocking_prompt_queue?
            raise ArgumentError, "Scheduled session #{source.key.inspect} has an unresolved inquiry; answer it before replacing it"
          end

          schedule_registry.reload!
          schedule = schedule_registry.find(schedule_key)
          raise ArgumentError, "Schedule #{schedule_key.inspect} no longer exists" unless schedule

          states = schedule_store.load
          state = states[schedule_key]
          unless state && state.last_target_key.to_s == source.key
            actual = state&.last_target_key.to_s
            detail = actual.empty? ? "has no current target" : "now targets agent #{actual.inspect}"
            raise StaleScheduleTarget, "Schedule #{schedule_key.inspect} #{detail}"
          end

          configured_target = schedule.agent_key.to_s
          unless configured_target.empty? || configured_target == source.key
            raise StaleScheduleTarget,
                  "Schedule #{schedule_key.inspect} configuration now targets agent #{configured_target.inspect}"
          end

          project = project_for(source.project_key)
          paths = [
            AGENTS_FILE,
            schedule_store.path,
            schedule_registry.path,
            target.memory_path,
            target.pull_request_catalog_path
          ]
          begin
            FileTransaction.run(paths) do
              ensure_project_context_prompt!(target, project) if project
              prepare&.call(source, target)
              source.detach_schedule!(template_key: project&.agent_templates&.first&.key)
              adopt_schedule!(
                target,
                schedule_key:,
                name: schedule.name,
                system_message: schedule.system_message,
                created_at: target.created_at || Time.now
              )
              state.previous_target_key = source.key
              state.last_target_key = target.key
              state.last_target_kind = "agent"
              schedule_registry.replace_agent_target(
                schedule_key,
                expected_agent_key: source.key,
                replacement_agent_key: target.key
              ) unless configured_target.empty?
              agents.unshift(target)
              save_unlocked(agents)
              schedule_store.save(states)
            end
          rescue StandardError
            schedule_registry.reload!
            raise
          end
          [source, target, state]
        end
      end
    end

    def ensure_project_context_prompt!(agent, project)
      agent.ensure_project_context_prompt!(project_context_prompt(project), created_at: agent.created_at || Time.now)
    end

    def adopt_schedule!(agent, schedule_key:, name:, system_message: nil, created_at: Time.now)
      prompt = scheduled_system_prompt(schedule_key:, name:, system_message:)
      agent.associate_schedule!(schedule_key)
      agent.ensure_schedule_context_prompt!(prompt, created_at:)
      prompt
    end

    private

    def accept_active_prompt_unlocked!(target, agents, prompt:, actor:, event_id:, message_metadata:, attachments:,
                                       delayed:, delay:, client_request_id:, source:, retire_inquiry_id:, start:,
                                       parent_server_id:, attachment_importer:, transaction:)
      ensure_prompt_delegation_unlocked!(target, agents, actor:, parent_server_id:)
      if attachment_importer
        attachments = Array(attachment_importer.call(target))
        transaction.on_rollback do
          AgentAttachmentStore.new(target).remove_remote_uploads!(attachments)
        end
        raise ArgumentError, "At least one attachment must be stored" if attachments.empty?
      end
      metadata = message_metadata.is_a?(Hash) ? message_metadata.dup : {}
      metadata["prompt_arrival_event_id"] = event_id unless event_id.to_s.empty?
      metadata["client_request_id"] = client_request_id unless client_request_id.to_s.empty?

      if delayed
        seconds = prompt_delay_seconds!(delay)
        accepted_at = Time.now
        entry = enqueue_prompt_from_unlocked!(
          target, prompt:, attachments:, actor:, accepted_at:, not_before: accepted_at + seconds,
          id: client_request_id, client_request_id:, message_metadata: metadata,
          source: source || (actor&.internal? ? "internal_continuation" : actor&.parent? ? "parent" : "user")
        )
        return { status: :queued, agent: target, entry:, replayed: false }
      end

      if target.running?
        entry = enqueue_prompt_from_unlocked!(
          target, prompt:, attachments:, actor:, id: client_request_id, client_request_id:,
          message_metadata: metadata, source: source || (actor&.parent? ? "parent" : "user")
        )
        return { status: :queued, agent: target, entry:, replayed: false }
      end

      accept_ordinary_prompt_unlocked!(
        target, text: prompt, attachments:, actor:, retire_inquiry_id:, metadata:, event_id:
      )
      start_target!(target, agents, run_metadata: nil) if start && !target.running?
      { status: :accepted, agent: target, entry: nil, replayed: false }
    end

    def accept_prompt_from_unlocked!(target, actor:, now: Time.now)
      target.cancel_pending_sleep_recovery! unless actor&.internal?
      @delegation_coordinator.accept_prompt_from!(child: target, actor:, now:)
    end

    def enqueue_prompt_from_unlocked!(target, prompt:, attachments:, actor:, accepted_at: nil, id: nil,
                                      client_request_id: nil, message_metadata: nil, source: nil, not_before: nil)
      accept_prompt_from_unlocked!(target, actor:)
      metadata = target.message_author_metadata(actor) || {}
      metadata.merge!(message_metadata) if message_metadata.is_a?(Hash)
      attributes = {
        prompt:,
        attachments:,
        accepted_at: accepted_at || Time.now,
        not_before:,
        authority: @delegation_coordinator.ownership_stamp(target.key),
        message_metadata: metadata,
        source: source || (actor&.parent? ? "parent" : "user")
      }
      attributes[:id] = id if id
      attributes[:client_request_id] = client_request_id if client_request_id
      target.enqueue_prompt!(**attributes)
    end

    def accept_ordinary_prompt_unlocked!(target, text:, attachments:, actor:, retire_inquiry_id:, metadata:, event_id:)
      target.cancel_pending_sleep_recovery!
      active_id = target.latest_inquiry_id.to_s
      suspended_id = target.suspended_inquiry_id.to_s
      supplied_id = retire_inquiry_id.to_s
      unless active_id.empty?
        raise ArgumentError, "Inquiry has changed; refresh and try again" unless supplied_id.empty?

        target.cancel_pending_inquiry!
      end
      if suspended_id.empty?
        raise ArgumentError, "Inquiry is no longer restorable; refresh and try again" unless supplied_id.empty?
      elsif supplied_id.empty? || supplied_id != suspended_id
        raise ArgumentError, "Inquiry has changed; refresh and try again"
      else
        target.retire_suspended_inquiry!(suspended_id)
      end

      accept_prompt_from_unlocked!(target, actor:)
      author_metadata = target.message_author_metadata(actor)
      merged = [author_metadata, metadata].select { |value| value.is_a?(Hash) }
                                          .reduce({}) { |result, value| result.merge(value) }
      target.add_user_message!(text, attachments:, metadata: merged, event_id:)
      include_pending_queue_work_with_user_input!(target)
      target
    end

    # A parent-declared prompt is a durable operator action. Keep this event on
    # the parent transcript only after the target has accepted or queued it.
    # The prompt-arrival id also makes a transport retry idempotent.
    def record_accepted_agent_send!(parent:, target:, prompt:, event_id:, result:)
      return unless parent

      queued = result.fetch(:status) == :queued
      AgentMemory.new(parent).append_delegation_event!(
        queued ? "Queued message for #{target.display_name}" : "Sent message to #{target.display_name}",
        event_id: "agent-send:#{event_id}",
        metadata: {
          "event" => "agent_message_sent",
          "delivery_status" => queued ? "queued" : "accepted",
          "agent_reference" => @delegation_coordinator.delegation_store.relation_for_child(target.key)&.fetch("child", nil),
          "message" => prompt.to_s
        }.compact
      )
    end

    def active_prompt_parent_unlocked!(target, agents, actor:)
      return nil unless actor&.parent?

      parent = agents.find { |agent| agent.key == actor.agent_key }
      unless parent && HQ::Visibility.agent_visible?(parent, @projects)
        raise DelegationStore::Error, "Unknown parent agent: #{actor.agent_key}"
      end
      if target.delegation_parent && target.delegation_parent.fetch("agent_key", nil) != actor.agent_key
        raise DelegationStore::Error, "Only the recorded parent can prompt a delegated child"
      end
      parent
    end

    def ensure_prompt_delegation_unlocked!(target, agents, actor:, parent_server_id:)
      return unless actor&.parent?

      relation = @delegation_coordinator.delegation_store.relation_for_child(target.key)
      if relation
        unless relation.dig("parent", "agent_key") == actor.agent_key
          raise DelegationStore::Error, "Only the recorded parent can prompt a delegated child"
        end
      else
        @delegation_coordinator.attach!(
          agents:, child: target, parent_key: actor.agent_key, parent_server_id:
        )
      end
    end

    def validate_archived_prompt_actor_unlocked!(agent, active_agents, actor:)
      return unless actor&.parent?

      parent_key = agent.delegation_parent&.fetch("agent_key", nil)
      unless parent_key == actor.agent_key
        raise DelegationStore::Error, "Parent is not authorized for archived agent: #{agent.key}"
      end
      parent = active_agents.find { |candidate| candidate.key == actor.agent_key }
      unless parent && HQ::Visibility.agent_visible?(parent, @projects)
        raise DelegationStore::Error, "Unknown parent agent: #{actor.agent_key}"
      end
      @delegation_coordinator.delegation_store.validate_agent_prompt!(
        source_key: actor.agent_key, target_key: agent.key
      )
    end

    def record_archived_prompt_unlocked!(key, prompt:, attachments:, actor:, event_id:, metadata:, active_agents:)
      record = AgentArchiveStore.new.find(key)
      raise ArgumentError, "Unknown agent: #{key}" unless record

      agent = record.agent
      validate_archived_prompt_actor_unlocked!(agent, active_agents, actor:)
      memory = AgentMemory.new(agent)
      user_added = memory.append_user_message!(
        prompt, attachments:, metadata:, event_id:
      )
      abort_added = memory.append_assistant_message!(
        ManagedAgent::ARCHIVE_ABORT_MESSAGE,
        metadata: { "archive_aborted_arrival" => true, "event_id" => event_id },
        event_id: "#{event_id}:archive-abort"
      )
      if user_added || abort_added
        AgentArchiveStore.new.save(record)
      end
      { status: :archived, agent:, entry: nil, replayed: !user_added && !abort_added }
    end

    def prompt_replay_unlocked(target, event_id)
      id = event_id.to_s
      return nil if id.empty?

      entry = target.queued_prompts.find { |candidate| candidate.dig("message_metadata", "prompt_arrival_event_id") == id }
      return { status: :queued, agent: target, entry:, replayed: true } if entry

      recorded = AgentMemory.new(target).events.any? { |event| event["event_id"].to_s == id }
      { status: :accepted, agent: target, entry: nil, replayed: true } if recorded
    end

    def prompt_delay_seconds!(delay)
      seconds = begin
        Float(delay)
      rescue ArgumentError, TypeError
        raise ArgumentError, "Delay must be a non-negative number"
      end
      raise ArgumentError, "Delay must be zero or greater" if seconds.negative?

      seconds
    end

    def materialize_sleep_recovery!(agent, delay: 60, now: Time.now)
      run = agent.last_run
      metadata = run&.metadata
      return false unless metadata.is_a?(Hash) && metadata["sleep_recovery_pending"] == true

      incident = metadata["sleep_circuit_breaker_incident"]
      return false unless incident.is_a?(Hash) && !incident["id"].to_s.empty?

      stamp = @delegation_coordinator.ownership_stamp(agent.key)
      expected_generation = incident["ownership_generation"]
      if !expected_generation.nil? && stamp&.fetch("generation", nil) != expected_generation
        metadata["sleep_recovery_pending"] = false
        metadata["sleep_recovery_cancelled"] = "ownership_generation_changed"
        return true
      end

      incident_id = incident.fetch("id")
      accepted_at = now
      command = "tycho agent send #{Shellwords.escape(agent.key)} \"<continuation>\" --delay 60"
      prompt = "This session was abruptly stopped by Tycho's sleep circuit breaker. " \
               "Continue without blocking waits. Schedule future work with `#{command}` instead of sleeping."
      agent.enqueue_prompt!(
        id: "sleep-recovery:#{incident_id}",
        prompt:,
        accepted_at:,
        not_before: accepted_at + delay,
        authority: stamp,
        source: "sleep_circuit_breaker_recovery",
        message_metadata: {
          "sleep_recovery_for_incident_id" => incident_id,
          "sleep_recovery_ownership_generation" => expected_generation,
          "sleep_recovery_observed_at" => incident["observed_at"],
          "sleep_recovery_threshold" => incident["threshold"],
          "sleep_recovery_blocking_call_count" => incident["blocking_call_count"]
        }.compact
      )
      metadata["sleep_recovery_pending"] = false
      metadata["sleep_recovery_scheduled_at"] = accepted_at.utc.iso8601(6)
      true
    end

    def persist_created_delegation!(agents, child, delegation)
      parent_key = delegation.fetch(:parent_key).to_s
      parent = agents.find { |agent| agent.key == parent_key }
      raise DelegationStore::Error, "Unknown parent agent: #{parent_key}" unless parent

      paths = [AGENTS_FILE, DELEGATIONS_FILE, child.memory_path, parent.memory_path]
      FileTransaction.run(paths) do
        relation, = @delegation_coordinator.attach!(
          agents:, child:, parent_key:, parent_server_id: delegation[:parent_server_id]
        )
        child.associate_parent!(relation.fetch("parent"))
        @delegation_coordinator.accept_prompt_from!(child:, actor: delegation[:actor]) if delegation[:actor]
        agents.unshift(child)
        save_unlocked(agents)
      end
      child
    end

    def find_agent_in!(agents, key)
      agents.find { |agent| agent.key == key.to_s } || raise(ArgumentError, "Unknown agent: #{key}")
    end

    def dispatch_prompt_queues!(agents, schedule_states: ScheduleStore.new.load)
      changed = false
      agents.each do |agent|
        next unless prompt_queue_dispatchable?(agent, schedule_states)

        changed = dispatch_prompt_queue!(agent, agents) || changed
      end
      changed
    end

    def prompt_queue_dispatchable?(agent, schedule_states)
      return false unless agent.prompt_queue_dispatchable?

      schedule = schedule_states[agent.schedule_key.to_s] if agent.scheduled?
      !schedule || schedule.scheduled?
    end

    def dispatch_prompt_queue!(agent, agents)
      return false if agents.any? do |candidate|
        candidate.key != agent.key && canonical_workspace(candidate.workspace) == canonical_workspace(agent.workspace) &&
          candidate.running?
      end

      claim = agent.claim_pending_prompts!
      return false unless claim

      # Persist the claim before preparing or launching so another Tycho
      # process can never claim the same accepted entries.
      save_unlocked(agents)
      if agent.prepare_prompt_queue_claim!
        save_unlocked(agents)
      end

      baseline = claim["baseline_run_count"].to_i
      run_metadata = {
        "prompt_queue_claim_id" => claim["id"],
        "prompt_queue_entry_ids" => Array(claim["entries"]).map { |entry| entry["id"].to_s }
      }
      accepted = begin
        stamp = Array(claim["entries"]).last&.fetch("authority", nil)
        options = { run_metadata: }
        options[:delegation_stamp] = stamp if stamp
        if agent.method(:start!).parameters.any? { |_kind, name| name == :before_spawn }
          options[:before_spawn] = ->(_run) { save_unlocked(agents) }
        end
        agent.start!(**options)
      rescue StandardError => e
        agent.fail_prompt_queue_dispatch!(dispatch_failure_message(e.message))
        save_unlocked(agents)
        return true
      end

      agent.mark_last_run_prompt_queue_claim!(claim["id"]) if agent.run_count > baseline

      if accepted && agent.run_count > baseline
        mark_claim_reports_resumed!(claim)
        agent.complete_prompt_queue_claim!
      else
        detail = agent.last_summary.to_s.strip
        agent.fail_prompt_queue_dispatch!(dispatch_failure_message(detail))
      end
      save_unlocked(agents)
      true
    end

    def dispatch_failure_message(detail)
      suffix = detail.to_s.strip
      suffix = "The agent run was not accepted." if suffix.empty?
      "Queued work was retained. Fix the start failure, then choose Retry queue. #{suffix}"
    end

    def mark_claim_reports_resumed!(claim)
      Array(claim["entries"]).each do |entry|
        reports = Array(entry.dig("message_metadata", "delegation_reports"))
        reports = [entry.dig("message_metadata", "delegation_report")] if reports.empty?
        reports.each do |report|
          report_id = report&.fetch("id", nil)
          @delegation_coordinator.mark_report_resumed!(report_id, now: Time.now) if report_id
        end
      end
    end

    def include_pending_queue_work_with_user_input!(target)
      result = target.include_pending_queue_work_with_user_input!
      mark_claim_reports_resumed!("entries" => result[:entries]) if result && !result[:idempotent]
      result
    end

    def canonical_workspace(path)
      File.realpath(path.to_s)
    rescue StandardError
      File.expand_path(path.to_s)
    end

    def with_exclusive_lock
      FileUtils.mkdir_p(File.dirname(AGENTS_FILE))
      File.open("#{AGENTS_FILE}.lock", File::RDWR | File::CREAT, 0o600) do |file|
        file.flock(File::LOCK_EX)
        yield
      ensure
        file.flock(File::LOCK_UN)
      end
    end

    def remove_failed_archive(destination)
      return unless File.directory?(destination)

      Dir.children(destination).each { |name| FileUtils.rm_f(File.join(destination, name)) }
      Dir.rmdir(destination)
    rescue StandardError => e
      HQ.logger.error("AgentStore") { "Failed to clean rolled-back archive #{destination}: #{e.message}" }
    end

    def attach_usage_metrics_store(agent)
      agent.usage_metrics_store = @usage_metrics_store
      agent
    end

    def schedule_keys_by_agent(schedule_states = ScheduleStore.new.load)
      schedule_states.each_with_object({}) do |(schedule_key, state), result|
        agent_key = state.last_target_key.to_s
        result[agent_key] = schedule_key unless agent_key.empty?
      end
    end

    # Pick the palette slot least represented among existing agents. Ties broken
    # by lowest index so the first N agents fill 0..N-1 deterministically.
    def next_color_index(agents)
      counts = Array.new(PALETTE_SIZE, 0)
      agents.each do |agent|
        next unless agent.color_index.is_a?(Integer)

        slot = agent.color_index % PALETTE_SIZE
        counts[slot] += 1
      end
      counts.each_with_index.min_by { |count, index| [count, index] }.last
    end

    def backfill_color_indexes!(agents)
      missing = agents.reject { |agent| agent.color_index.is_a?(Integer) }
      return false if missing.empty?

      assigned = agents.select { |agent| agent.color_index.is_a?(Integer) }
      missing.each do |agent|
        agent.color_index = next_color_index(assigned)
        assigned << agent
      end
      true
    end

    def backfill_delegation_parents!(agents)
      changed = false
      agents.each do |agent|
        relation = @delegation_coordinator.delegation_store.relation_for_child(agent.key)
        next unless relation
        next if agent.delegation_parent

        agent.associate_parent!(relation.fetch("parent"))
        changed = true
      end
      changed
    end

    def running_for_poll_event?(agent)
      agent.status == "running" || (!!agent.pid && agent.last_run&.status == "running")
    end

    def next_suffix(project_key, agents)
      prefixes = agents.filter_map do |agent|
        match = agent.key.match(/^#{Regexp.escape(project_key)}-agent-(\d+)$/)
        match[1].to_i if match
      end
      project_count = agents.count { |agent| agent.project_key == project_key }
      [prefixes.max || 0, project_count].max + 1
    end

    def next_agent_key(project_key, agents, now: Time.now)
      timestamp = now.utc.strftime("%Y%m%d-%H%M%S-%6N")
      base = "#{project_key}-agent-#{timestamp}"
      existing_keys = agents.map(&:key)
      return base unless existing_keys.include?(base)

      loop do
        candidate = "#{base}-#{SecureRandom.hex(3)}"
        return candidate unless existing_keys.include?(candidate)
      end
    end

    def scheduled_agent_name(project, schedule_key:, name:)
      label = name.to_s.strip
      label.empty? ? "#{project.name} #{schedule_key}" : ManagedAgent.display_name_for(label, scheduled: true)
    end

    def scheduled_system_prompt(schedule_key:, name:, system_message: nil)
      self.class.schedule_system_prompt(schedule_key:, name:, system_message:)
    end

    def template_for(project, template_key)
      project.agent_templates.find { |template| template.key == template_key } || project.agent_templates.first
    end

    def backfill_project_context_prompt!(agent)
      project = project_for(agent.project_key)
      return false unless project

      ensure_project_context_prompt!(agent, project)
    end

    # The identity context is a launch-time snapshot of trusted local agent data.
    # It deliberately records only the immutable parent key, never mutable parent details.
    def backfill_agent_system_context_prompt!(agent)
      agent.ensure_agent_system_context_prompt!(created_at: agent.created_at || Time.now)
    end

    def seed_memory_system_prompts!(agent, project, prompt)
      created_at = agent.created_at || Time.now
      memory = HQ::AgentMemory.new(agent)
      return if memory.exists?

      project_context = project_context_prompt(project)
      memory.append_system_prompt!(project_context, created_at:, prompt_role: "project_context")
      memory.append_system_prompt!(prompt.to_s, created_at:, prompt_role: "base") unless prompt.to_s.strip.empty?
    rescue StandardError
      nil
    end

    def system_messages_for(project, prompt)
      created_at = Time.now
      [
        ManagedAgent::AgentMessage.new(role: "system", content: project_context_prompt(project), created_at:),
        ManagedAgent::AgentMessage.new(role: "system", content: prompt.to_s, created_at:)
      ].reject { |message| message.content.to_s.strip.empty? }
    end

    def project_context_prompt(project)
      lines = [
        "Project:",
        "- Key: #{project.key}",
        "- Name: #{project.name}",
        "- Path: #{project.path}"
      ]
      lines.join("\n")
    end

    def project_for(project_key)
      @projects.find { |project| project.key == project_key }
    end
  end
end
