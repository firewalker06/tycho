# frozen_string_literal: true

require_relative "constants"
require_relative "file_transaction"
require_relative "file_store"
require_relative "managed_agent"
require_relative "delegation_coordinator"
require_relative "schedule_store"
require_relative "visibility"
require_relative "../ui/rendering/styles"
require "securerandom"

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

    def initialize(projects, usage_metrics_store: nil, delegation_coordinator: nil)
      @projects = projects
      @usage_metrics_store = usage_metrics_store || UsageMetrics.store(
        path: File.join(File.dirname(AGENTS_FILE), "usage_metrics.json")
      )
      @delegation_coordinator = delegation_coordinator || DelegationCoordinator.new
    end

    def load
      agents, = load_with_poll_events
      agents
    end

    def load_with_poll_events
      with_exclusive_lock { load_with_poll_events_unlocked }
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
      schedule_keys = schedule_keys_by_agent
      agents = Array(FileStore.read_json(AGENTS_FILE, fallback: [])).map do |hash|
        agent = ManagedAgent.from_hash(hash)
        agent.usage_metrics_store = @usage_metrics_store
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
        if was_running && !running_for_poll_event?(agent)
          unless agent.no_action_needed?
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
        agent
      end
      changed = backfill_color_indexes!(agents) || changed
      changed = backfill_delegation_parents!(agents) || changed
      changed = @delegation_coordinator.process!(agents) || changed if process_delegations
      changed = dispatch_prompt_queues!(agents) || changed if dispatch_prompt_queues
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

    def save_unlocked(agents)
      FileStore.write_json(AGENTS_FILE, agents.map(&:to_hash))
    end

    def create_for_project(project)
      create_from_template(project, project.agent_templates.first.key)
    end

    def create_from_template(project, template_key)
      existing = load
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

    def create_scheduled(project, schedule_key:, name:, system_message: nil, existing_agents: load)
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
        agent: project.respond_to?(:agent) ? project.agent : project.config.agent,
        model: project.respond_to?(:model) ? project.model : project.config.model,
        reasoning_effort: project.respond_to?(:reasoning_effort) ? project.reasoning_effort : project.config.reasoning_effort,
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
        save_unlocked(current + additions) unless additions.empty?
      end
    end

    def start_agent!(key)
      mutate(dispatch_prompt_queues: false) do |agents, _events|
        target = agents.find { |agent| agent.key == key.to_s }
        raise ArgumentError, "Unknown agent: #{key}" unless target

        unless target.running?
          stamp = @delegation_coordinator.ownership_stamp(target.key)
          stamp ? target.start!(delegation_stamp: stamp) : target.start!
        end
        target
      end
    end

    def accept_delegation_prompt!(child, owner:, parent_key: nil, now: Time.now)
      @delegation_coordinator.accept_prompt!(child:, owner:, parent_key:, now:)
    end

    def accept_prompt_from!(child, actor:, agents: nil, now: Time.now)
      current = agents || load
      @delegation_coordinator.accept_prompt_from!(child:, actor:, now:)
    end

    def stop_agent!(key)
      mutate do |agents, _events|
        target = agents.find { |agent| agent.key == key.to_s }
        raise ArgumentError, "Unknown agent: #{key}" unless target

        target.stop! if target.running?
        target
      end
    end

    def enqueue_prompt!(key, prompt:, attachments: nil, accepted_at: nil)
      mutate do |agents, _events|
        target = agents.find { |agent| agent.key == key.to_s }
        raise ArgumentError, "Unknown agent: #{key}" unless target
        raise ArgumentError, "Agent is no longer running" unless target.running?

        [target, target.enqueue_prompt!(prompt:, attachments:, accepted_at: accepted_at || Time.now)]
      end
    end

    def edit_queued_prompt!(key, entry_id, prompt:)
      mutate do |agents, _events|
        target = agents.find { |agent| agent.key == key.to_s }
        raise ArgumentError, "Unknown agent: #{key}" unless target

        [target, target.edit_queued_prompt!(entry_id, prompt:)]
      end
    end

    def delete_queued_prompt!(key, entry_id)
      mutate do |agents, _events|
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
        raise ArgumentError, "An inquiry must be answered before retrying queued work" if target.latest_inquiry

        target.clear_prompt_queue_dispatch_error!
        dispatch_prompt_queue!(target, agents)
        target
      end
    end

    def archive_agent!(key, root: AGENT_ARCHIVE_DIR)
      archive_agents!([key], root:).fetch(key.to_s)
    end

    def archive_agents!(keys, root: AGENT_ARCHIVE_DIR)
      with_exclusive_lock do
        agents, = load_with_poll_events_unlocked(process_delegations: false)
        requested = Array(keys).map(&:to_s).uniq
        targets = requested.map do |key|
          agents.find { |agent| agent.key == key } || raise(ArgumentError, "Unknown agent: #{key}")
        end
        raise ArgumentError, "Agent is running" if targets.any?(&:running?)

        source_paths = targets.flat_map { |target| target.log_files.select { |path| File.exist?(path) } }
        transaction = FileTransaction.new([AGENTS_FILE, *source_paths])
        destinations = targets.to_h do |target|
          target.mark_archived_visibility!(!HQ::Visibility.agent_visible?(target, @projects))
          destination = target.archive_logs!(root)
          transaction.on_rollback { remove_failed_archive(destination) }
          [target.key, destination]
        end
        save_unlocked(agents.reject { |agent| requested.include?(agent.key) })
        destinations
      rescue StandardError
        transaction&.rollback
        raise
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

    def dispatch_prompt_queues!(agents)
      changed = false
      agents.each do |agent|
        next unless agent.prompt_queue_dispatchable?

        changed = dispatch_prompt_queue!(agent, agents) || changed
      end
      changed
    end

    def dispatch_prompt_queue!(agent, agents)
      claim = agent.claim_pending_prompts!
      return false unless claim

      # Persist the claim before preparing or launching so another Tycho
      # process can never claim the same accepted entries.
      save_unlocked(agents)
      if agent.prepare_prompt_queue_claim!
        save_unlocked(agents)
      end

      baseline = claim["baseline_run_count"].to_i
      accepted = begin
        stamp = @delegation_coordinator.ownership_stamp(agent.key)
        stamp ? agent.start!(delegation_stamp: stamp) : agent.start!
      rescue StandardError => e
        agent.fail_prompt_queue_dispatch!(dispatch_failure_message(e.message))
        save_unlocked(agents)
        return true
      end

      if accepted && agent.run_count > baseline
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

    def schedule_keys_by_agent
      ScheduleStore.new.load.each_with_object({}) do |(schedule_key, state), result|
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
