# frozen_string_literal: true

require_relative "constants"
require_relative "file_transaction"
require_relative "file_store"
require_relative "agent_store_recovery"
require_relative "managed_agent"
require_relative "delegation_coordinator"
require_relative "schedule_store"
require_relative "visibility"
require_relative "../ui/rendering/styles"
require "securerandom"
require "shellwords"

module HQ
  class AgentStore
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

    def save_unlocked(agents, allow_retired_keys: false)
      current = File.exist?(AGENTS_FILE) ? Array(FileStore.read_json(AGENTS_FILE, fallback: [])) : []
      records = @recovery.prepare(agents.map(&:to_hash), current_records: current, allow_retired_keys:)
      FileStore.write_json(AGENTS_FILE, records)
      @recovery.after_save(records, allow_retired_keys:)
    end

    def create_for_project(project)
      create_from_template(project, project.agent_templates.first.key)
    end

    # Protected daily sessions use the same exclusive, durable store lifecycle
    # as normal agents. This prevents a state file from pointing at an agent
    # that was never committed, or an archived PA leaving its record behind.
    def create_personal_assistant!(agent)
      mutate(dispatch_prompt_queues: false) do |agents, _events|
        raise ArgumentError, "A Personal Assistant session is already active" if agents.any?(&:personal_assistant?)

        agents.unshift(agent)
        agent
      end
    end

    def archive_personal_assistant!(key)
      with_exclusive_lock do
        agents, = load_with_poll_events_unlocked(process_delegations: false, dispatch_prompt_queues: false)
        target = find_agent_in!(agents, key)
        raise ArgumentError, "Not a Personal Assistant session" unless target.personal_assistant?
        raise ArgumentError, "Personal Assistant is still running" if target.running?

        transaction = FileTransaction.new([AGENTS_FILE, *target.log_files.select { |path| File.exist?(path) }])
        destination = target.archive_logs!
        transaction.on_rollback { remove_failed_archive(destination) }
        save_unlocked(agents.reject { |agent| agent.key == target.key })
      rescue StandardError
        transaction&.rollback
        raise
      end
    end

    def delete_personal_assistant!(key)
      with_exclusive_lock do
        agents, = load_with_poll_events_unlocked(process_delegations: false)
        target = find_agent_in!(agents, key)
        raise ArgumentError, "Not a Personal Assistant session" unless target.personal_assistant?
        raise ArgumentError, "Personal Assistant is still running" if target.running?

        paths = target.log_files.select { |path| File.exist?(path) }
        FileTransaction.run([AGENTS_FILE, *paths]) do
          paths.each { |path| FileUtils.rm_f(path) }
          save_unlocked(agents.reject { |agent| agent.key == target.key })
        end
      end
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
        child.cancel_pending_sleep_recovery! unless actor&.internal?
        return @delegation_coordinator.accept_prompt_from!(child:, actor:, now:)
      end

      mutate(dispatch_prompt_queues: false) do |current, _events|
        target = find_agent_in!(current, child.key)
        target.cancel_pending_sleep_recovery! unless actor&.internal?
        @delegation_coordinator.accept_prompt_from!(child: target, actor:, now:)
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
          accept_prompt_from!(target, actor:, agents:)
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
          entry = target.enqueue_prompt!(**attributes)
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

    def read_prompt_queue!(key, read_at: Time.now)
      with_exclusive_lock do
        agents, = load_with_poll_events_unlocked(process_delegations: false, dispatch_prompt_queues: false)
        target = find_agent_in!(agents, key)
        paths = [AGENTS_FILE, DELEGATIONS_FILE, target.memory_path, target.attachments_path]
        result = nil
        FileTransaction.run(paths) do
          raise ArgumentError, "Queued work is already claimed for dispatch" if target.prompt_queue_claim
          batch = target.active_queue_work || target.open_queue_work_batch!(opened_at: read_at)
          raise ArgumentError, "No pending queue entries for #{target.key}" unless batch

          read_id = batch["read_id"].to_s
          first_read = read_id.empty?
          read_id = "queue-read:#{SecureRandom.uuid}" if first_read
          target.mark_queue_work_read!(batch, read_id:)
          entries = Array(batch["entries"])
          content = QueueWork.contract(batch, agent_key: target.key)
          attachments = target.consolidated_prompt_queue_attachments(entries)
          read_entries = target.consolidated_prompt_queue_entries(entries, state: batch["state"])
          projection = QueueWork.projection(batch)
          metadata = target.consolidated_prompt_queue_metadata(entries).merge(
            "queue_read" => true,
            "read_label" => "Read queue",
            "prompt_queue_entries" => read_entries,
            "queue_work_batch_id" => batch["id"],
            "queue_work_state" => batch["state"],
            "queue_work_projection" => projection
          )
          if first_read
            AgentMemory.new(target).append_queue_read!(
              content,
              read_id:,
              created_at: read_at,
              attachments:,
              metadata:
            )
            mark_claim_reports_resumed!("entries" => entries)
          end
          save_unlocked(agents)
          result = {
            agent: target,
            entries:,
            read_entries:,
            content:,
            attachments:,
            read_id:,
            batch: QueueWork.payload(batch),
            idempotent: !first_read
          }
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

        accept_prompt_from!(target, actor:, agents:)
        author_metadata = target.message_author_metadata(actor)
        message_metadata = [author_metadata, metadata].select { |value| value.is_a?(Hash) }.reduce({}) { |result, value| result.merge(value) }
        target.add_user_message!(text, attachments:, metadata: message_metadata, event_id:)
        target
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
        if targets.any?(&:personal_assistant?)
          raise ArgumentError, "Personal Assistant is managed by its daily lifecycle and cannot be archived manually"
        end
        raise ArgumentError, "Agent is running" if targets.any?(&:running?)
        blocked = targets.select { |target| target.pending_prompts? && !target.delegation_callback_prompts_only? }
        unless blocked.empty?
          descriptions = blocked.map do |target|
            entries = target.queued_prompts
            ordinary = entries.count { |entry| entry["source"] != "delegation_callback" }
            callbacks = entries.length - ordinary
            queue = if callbacks.positive?
                      "mixed queue (#{ordinary} ordinary, #{callbacks} delegation callbacks)"
                    else
                      noun = ordinary == 1 ? "prompt" : "prompts"
                      "#{ordinary} ordinary queued #{noun}"
                    end
            "#{target.key}: #{queue}"
          end
          raise ArgumentError,
                "Archive blocked to protect queued user work (#{descriptions.join("; ")}). " \
                "Run or delete the ordinary queued prompts before archiving."
        end

        source_paths = targets.flat_map(&:log_files)
        transaction = FileTransaction.new([AGENTS_FILE, DELEGATIONS_FILE, *source_paths])
        destinations = targets.to_h do |target|
          callbacks = target.archive_delegation_callback_prompts!
          target.mark_archived_visibility!(!HQ::Visibility.agent_visible?(target, @projects))
          destination = target.archive_logs!(root)
          transaction.on_rollback { remove_failed_archive(destination) }
          reconcile_archived_callbacks(callbacks)
          [target.key, destination]
        end
        save_unlocked(agents.reject { |agent| requested.include?(agent.key) })
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
      run_metadata = { "prompt_queue_claim_id" => claim["id"] }
      request_ids = Array(claim["personal_assistant_client_request_ids"]).filter_map do |id|
        value = id.to_s.strip
        value.empty? ? nil : value
      end
      run_metadata["personal_assistant_client_request_ids"] = request_ids unless request_ids.empty?
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
