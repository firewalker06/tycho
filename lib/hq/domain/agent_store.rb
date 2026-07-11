# frozen_string_literal: true

require_relative "constants"
require_relative "file_store"
require_relative "managed_agent"
require_relative "../ui/rendering/styles"

module HQ
  class AgentStore
    PALETTE_SIZE = HQ::UI::Rendering::Styles::CHAT_BORDER_PALETTE.length
    PollEvent = Struct.new(:agent_key, :from_status, :to_status, :run_count, keyword_init: true)

    def initialize(projects)
      @projects = projects
    end

    def load
      agents, = load_with_poll_events
      agents
    end

    def load_with_poll_events
      return [[], []] unless File.exist?(AGENTS_FILE)

      changed = false
      events = []
      agents = Array(FileStore.read_json(AGENTS_FILE, fallback: [])).map do |hash|
        agent = ManagedAgent.from_hash(hash)
        changed = true if hash != agent.to_hash
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
      save(agents) if changed
      [agents, events]
    rescue StandardError => e
      HQ.logger.warn("AgentStore") { "Failed to load agents from #{AGENTS_FILE}: #{e.class} - #{e.message}" }
      [[], []]
    end

    def save(agents)
      FileStore.write_json(AGENTS_FILE, agents.map(&:to_hash))
    end

    def create_for_project(project)
      create_from_template(project, project.agent_templates.first.key)
    end

    def create_from_template(project, template_key)
      existing = load
      suffix = next_suffix(project.key, existing)
      key = "#{project.key}-agent-#{suffix}"
      template = template_for(project, template_key)
      agent = ManagedAgent.new(
        key: key,
        name: "#{project.name} #{template.name.downcase} #{suffix}",
        project_key: project.key,
        template_key: template.key,
        workspace: project.path,
        prompt: template.prompt,
        sandbox_mode: template.sandbox_mode,
        agent: template.agent,
        model: template.model,
        reasoning_effort: template.reasoning_effort,
        messages: system_messages_for(project, template.prompt),
        color_index: next_color_index(existing)
      )
      seed_memory_system_prompts!(agent, project, template.prompt)
      agent
    end

    def create_scheduled(project, schedule_key:, name:, system_message: nil, existing_agents: load)
      suffix = next_suffix(project.key, existing_agents)
      key = "#{project.key}-agent-#{suffix}"
      now = Time.now
      prompt = scheduled_system_prompt(schedule_key:, name:, system_message:)
      system_messages = system_messages_for(project, prompt)
      agent = ManagedAgent.new(
        key: key,
        name: scheduled_agent_name(project, schedule_key:, name:),
        project_key: project.key,
        template_key: "scheduled",
        workspace: project.path,
        prompt: prompt,
        sandbox_mode: "danger-full-access",
        agent: project.respond_to?(:agent) ? project.agent : project.config.agent,
        model: project.respond_to?(:model) ? project.model : project.config.model,
        reasoning_effort: project.respond_to?(:reasoning_effort) ? project.reasoning_effort : project.config.reasoning_effort,
        messages: system_messages,
        created_at: now,
        color_index: next_color_index(existing_agents)
      )
      seed_memory_system_prompts!(agent, project, prompt)
      agent
    end

    def add_scheduled_message!(agent, schedule_key:, message:, due_at: nil)
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

    def clone_agent(agent, existing_agents: load)
      suffix = next_suffix(agent.project_key, existing_agents)
      key = "#{agent.project_key}-agent-#{suffix}"
      ManagedAgent.new(
        key: key,
        name: agent.name,
        project_key: agent.project_key,
        template_key: agent.template_key,
        workspace: agent.workspace,
        prompt: agent.prompt,
        sandbox_mode: agent.sandbox_mode,
        agent: agent.agent,
        model: agent.model,
        reasoning_effort: agent.reasoning_effort,
        skills: agent.skills,
        color_index: next_color_index(existing_agents)
      )
    end

    def ensure_project_context_prompt!(agent, project)
      agent.ensure_project_context_prompt!(project_context_prompt(project), created_at: agent.created_at || Time.now)
    end

    private

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

    def running_for_poll_event?(agent)
      agent.status == "running" || (!!agent.pid && agent.last_run&.status == "running")
    end

    def next_suffix(project_key, agents)
      prefixes = agents.filter_map do |agent|
        match = agent.key.match(/^#{Regexp.escape(project_key)}-agent-(\d+)$/)
        match[1].to_i if match
      end
      (prefixes.max || 0) + 1
    end

    def scheduled_agent_name(project, schedule_key:, name:)
      label = name.to_s.strip
      label.empty? ? "#{project.name} #{schedule_key}" : ManagedAgent.display_name_for(label, scheduled: true)
    end

    def scheduled_system_prompt(schedule_key:, name:, system_message: nil)
      custom = system_message.to_s.strip
      return custom unless custom.empty?

      label = name.to_s.strip
      title = label.empty? ? schedule_key.to_s : "#{label} (#{schedule_key})"
      [
        "This managed agent is owned by the Tycho schedule #{title}.",
        "Treat each scheduled user message as one recurring run in the same long-lived session.",
        "Use prior session context when it helps, but make each run's outcome clear and operator-facing.",
        "Use structured status `no_action_needed` when the scheduled check completed and there is nothing to act on.",
        "Use structured status `success` only when you completed a concrete action or produced a requested deliverable.",
        "If you need human input, ask a precise structured inquiry and stop instead of guessing."
      ].join("\n")
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
