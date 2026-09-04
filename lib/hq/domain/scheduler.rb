# frozen_string_literal: true

require "time"

require_relative "../registry"
require_relative "agent_store"
require_relative "file_transaction"
require_relative "project"
require_relative "push_notification_store"
require_relative "schedule_registry"
require_relative "schedule_store"
require_relative "web_push_notifier"

module HQ
  class Scheduler
    LoopStartError = Class.new(StandardError)
    RefreshError = Class.new(StandardError)
    DEFAULT_INTERVAL = 30
    MISSED_GRACE_SECONDS = 60

    attr_reader :registry, :schedule_registry, :store

    def initialize(registry: Registry.new, schedule_registry: nil, store: ScheduleStore.new,
                   push_notification_store: PushNotificationStore.new, web_push_notifier: nil)
      @registry = registry
      @projects = registry.projects.map { |config| Project.new(config) }
      @agent_store = AgentStore.new(@projects)
      @schedule_registry = schedule_registry || ScheduleRegistry.new(projects: @projects)
      @store = store
      @push_notification_store = push_notification_store
      @web_push_notifier = web_push_notifier || WebPushNotifier.new
    end

    def validate!
      schedule_registry.schedules
      true
    end

    def list(now: Time.now)
      schedules = schedule_registry.schedules
      states = store.load
      agents = load_agents
      changed = false
      rows = schedules.map do |schedule|
        state = store.state_for(states, schedule.key)
        changed = if expire_schedule!(schedule, state, now:)
                    true
                  else
                    ensure_next_due!(schedule, state, now:) || changed
                  end
        schedule_payload(schedule, state, agent: last_agent(schedule, state, agents))
      end
      store.save(states) if changed
      rows
    end

    def daemon_state(now: Time.now)
      store.daemon_state(now:)
    end

    def pause(key, now: Time.now)
      schedule = find_schedule!(key)
      states = store.load
      state = store.state_for(states, schedule.key)
      state.mark_paused!(now:)
      store.save(states)
      schedule_payload(schedule, state)
    end

    def resume(key, now: Time.now)
      schedule = find_schedule!(key)
      states = store.load
      state = store.state_for(states, schedule.key)
      ensure_not_expired!(schedule, state, states, now:)
      resume_state!(schedule, state, now:)
      store.save(states)
      { status: :resumed, schedule: schedule_payload(schedule, state) }
    end

    def resume_and_run_now(key, now: Time.now, dry_run: false)
      schedule, states, state = schedule_state_for(key)
      ensure_not_expired!(schedule, state, states, now:)
      resume_state!(schedule, state, now:)
      run_schedule(schedule, states, state, now:, dry_run:)
    end

    def refresh_session(key, now: Time.now)
      schedule = find_schedule!(key)
      state = store.state_for(store.load, schedule.key)
      target = last_agent(schedule, state, load_agents)
      if target
        @agent_store.stop_agent!(target.key) if target.running?
        @agent_store.archive_agent!(target.key)
        reconcile_archived_agent!(target.key, archived_agent: target, now:)
      end

      resume_and_run_now(schedule.key, now:)
    end

    def run_now(key, now: Time.now, dry_run: false)
      schedule, states, state = schedule_state_for(key)
      if expire_schedule!(schedule, state, now:)
        store.save(states)
        return { status: :skipped, schedule: schedule_payload(schedule, state) }
      end
      run_schedule(schedule, states, state, now:, dry_run:)
    end

    def run_schedule(schedule, states, state, now:, dry_run:)
      agents = load_agents
      result = dispatch_schedule(schedule, state, agents, now:, dry_run:)
      persist(agents, states, dry_run:)
      result
    end

    def remove(key)
      schedule = find_schedule!(key)
      agents = load_agents
      detached = agents.select { |agent| agent.schedule_key.to_s == schedule.key }
      state = store.load[schedule.key]

      FileTransaction.run([schedule_registry.path, store.path, AGENTS_FILE]) do
        schedule_registry.delete(schedule.key)
        store.delete(schedule.key)
        detached.each do |agent|
          project = @projects.find { |candidate| candidate.key == agent.project_key }
          agent.detach_schedule!(template_key: project&.agent_templates&.first&.key)
        end
        @agent_store.save(agents) if detached.any?
      end

      publish("schedule.removed", schedule, state || ScheduleState.new(key: schedule.key),
              agent_keys: detached.map(&:key))
      { schedule: schedule_payload(schedule, state || ScheduleState.new(key: schedule.key)), agents: detached }
    end

    def create_agent_loop!(agent:, agents:, schedule_key:, name:, interval_minutes:, ends_at:, message:, now: Time.now)
      raise LoopStartError, "Stop the running agent before starting a loop" if agent.running?
      unless agent.schedule_key.to_s.empty?
        raise LoopStartError, "Agent #{agent.key} already belongs to schedule #{agent.schedule_key}"
      end

      interval = Integer(interval_minutes.to_s, 10)
      raise ArgumentError, "Loop interval must be between 1 and 59 minutes" unless interval.between?(1, 59)
      raise ArgumentError, "Loop end time must be in the future" unless ends_at > now

      prompt = AgentStore.schedule_system_prompt(schedule_key:, name:)
      FileTransaction.run([schedule_registry.path, store.path, AGENTS_FILE, agent.memory_path]) do
        created = schedule_registry.create(
          "key" => schedule_key,
          "name" => name,
          "cron" => "*/#{interval} * * * *",
          "timezone" => "local",
          "ends_at" => ends_at.iso8601,
          "project_key" => agent.project_key,
          "agent_name" => agent.name,
          "agent_key" => agent.key,
          "system_message" => prompt,
          "message_source" => "inline",
          "message" => message
        )
        @agent_store.adopt_schedule!(
          agent, schedule_key:, name:, system_message: prompt, created_at: now
        )
        states = store.load
        state = store.state_for(states, created.key)
        state.mark_scheduled!
        state.last_target_kind = "agent"
        state.last_target_key = agent.key
        state.next_due_at = now
        state.resumed_at = now
        store.save(states)
        @agent_store.save(agents)

        result = run_now(created.key, now:)
        if result.fetch(:status) == :failed
          raise LoopStartError, result.fetch(:error)
        end
        unless result.fetch(:status) == :started
          raise LoopStartError, "Loop schedule did not start: #{result.fetch(:status)}"
        end

        result
      end
    end

    def reconcile_archived_agent!(agent_key, archived_agent: nil, now: Time.now)
      key = agent_key.to_s
      return false if key.empty?

      schedules = schedule_registry.schedules
      states = store.load
      changed = false
      schedules.each do |schedule|
        state = store.state_for(states, schedule.key)
        next unless state.last_target_key.to_s == key

        preserve_archived_agent_system_message!(schedule, archived_agent)
        reconcile_archived_agent_state!(schedule, state, key, now:)
        changed = true
      end
      store.save(states) if changed
      changed
    end

    def tick(now: Time.now, dry_run: false)
      schedules = schedule_registry.schedules
      states = store.load
      agents = load_agents
      totals = { started: 0, skipped: 0, queued: 0, completed: 0, failed: 0, dry_run: dry_run }

      reconcile_completed_runs!(schedules, states, agents, now:)

      schedules.each do |schedule|
        state = store.state_for(states, schedule.key)
        next if expire_schedule!(schedule, state, now:)

        ensure_next_due!(schedule, state, now:)
        next unless runnable?(schedule, state)
        next unless state.next_due_at && state.next_due_at <= now

        result = dispatch_schedule(schedule, state, agents, now:, dry_run:)
        totals[result.fetch(:status)] += 1 if totals.key?(result.fetch(:status))
      end

      persist(agents, states, dry_run:)
      totals
    end

    private

    def load_agents
      agents, = @agent_store.load_with_poll_events
      agents
    end

    def persist(agents, states, dry_run:)
      return if dry_run

      @agent_store.save(agents)
      store.save(states)
    end

    def schedule_payload(schedule, state, agent: nil)
      {
        key: schedule.key,
        name: schedule.name,
        status: state.status,
        enabled: schedule.enabled?,
        paused: state.paused?,
        stopped: state.stopped?,
        project_key: schedule.project_key,
        agent_name: schedule.agent_name,
        target_agent_key: schedule.agent_key,
        system_message: schedule.system_message,
        cron: schedule.cron,
        timezone: schedule.timezone,
        message_source: schedule.message_source,
        message: schedule.message,
        message_file: schedule.message_file,
        ends_at: schedule.ends_at&.iso8601,
        policy: schedule.policy,
        next_due_at: state.next_due_at&.iso8601,
        last_status: state.last_status,
        last_error: state.last_error,
        last_target_key: state.last_target_key,
        run_count: state.run_count.to_i,
        session_run_count: agent ? agent.run_count.to_i : state.run_count.to_i,
        skip_count: state.skip_count.to_i
      }
    end

    def find_schedule!(key)
      schedule = schedule_registry.find(key)
      raise ScheduleRegistry::Error, "Unknown schedule: #{key}" unless schedule

      schedule
    end

    def schedule_state_for(key)
      schedule = find_schedule!(key)
      states = store.load
      [schedule, states, store.state_for(states, schedule.key)]
    end

    def project_for(schedule)
      @projects.find { |project| project.key == schedule.project_key }
    end

    def ensure_next_due!(schedule, state, now:)
      return false if state.next_due_at

      state.next_due_at = schedule.next_due_after(now)
      true
    end

    def expire_schedule!(schedule, state, now:)
      return false unless schedule.expired?(now)
      return false if state.stopped? && state.last_status.to_s == "expired"

      state.mark_stopped!(now:)
      state.next_due_at = nil
      state.last_status = "expired"
      state.last_error = nil
      publish("schedule.expired", schedule, state, agent_key: state.last_target_key)
      true
    end

    def runnable?(schedule, state)
      state.scheduled?
    end

    def dispatch_schedule(schedule, state, agents, now:, dry_run: false)
      target = last_agent(schedule, state, agents)
      running = target&.running?
      if running
        return handle_overlap(schedule, state, now:, dry_run:)
      end
      if target && agent_needs_operator?(target)
        return hold_schedule_for_operator(schedule, state, target, now:)
      end
      if interactive_scheduled_session?(schedule, state, target)
        return skip_schedule_result(schedule, state, now:, reason: "interactive")
      end

      if dry_run
        return {
          status: :started,
          schedule: schedule_payload(schedule, state).merge(dry_run: true)
        }
      end

      message = schedule.message_text.to_s.strip
      raise ScheduleRegistry::Error, "Schedule #{schedule.key.inspect} has empty message" if message.empty?

      agent = target || build_scheduled_agent(schedule, agents)
      due_at = state.next_due_at || now
      @agent_store.add_scheduled_message!(agent, schedule_key: schedule.key, message: message, due_at: due_at)
      agents.unshift(agent) unless target
      @agent_store.save(agents)
      agent = @agent_store.start_agent!(agent.key)
      index = agents.index { |candidate| candidate.key == agent.key }
      agents[index] = agent if index

      state.last_due_at = due_at
      state.last_started_at = agent.started_at || now
      state.last_finished_at = nil
      state.last_status = "started"
      state.last_error = nil
      state.last_target_kind = "agent"
      state.last_target_key = agent.key
      state.next_due_at = schedule.next_due_after(now)
      state.resumed_at = nil
      state.run_count = state.run_count.to_i + 1
      publish("schedule.started", schedule, state, agent_key: agent.key)

      {
        status: :started,
        schedule: schedule_payload(schedule, state, agent: agent),
        agent: agent
      }
    rescue StandardError => e
      if agent
        state.last_target_kind = "agent"
        state.last_target_key = agent.key
      end
      state.last_status = "failed"
      state.last_error = e.message
      state.mark_stopped!(now:)
      notify_schedule_failure(schedule, state, now:, error: e.message)
      publish("schedule.failed", schedule, state, error: e.message)
      publish("schedule.stopped", schedule, state, reason: "failure")
      {
        status: :failed,
        schedule: schedule_payload(schedule, state),
        error: e.message
      }
    end

    def handle_overlap(schedule, state, now:, dry_run:)
      skip_schedule(schedule, state, now:, reason: "overlap")
      { status: :skipped, schedule: schedule_payload(schedule, state) }
    end

    def skip_schedule_result(schedule, state, now:, reason:)
      skip_schedule(schedule, state, now:, reason:)
      { status: :skipped, schedule: schedule_payload(schedule, state) }
    end

    def hold_schedule_for_operator(schedule, state, agent, now:)
      state.last_status = agent.status
      state.last_error = agent.last_summary
      state.last_finished_at ||= agent.finished_at || now
      state.mark_stopped!(now:)
      notify_schedule_input_required(schedule, state, agent, now:)
      publish("schedule.stopped", schedule, state, agent_key: agent.key, reason: "input_required")
      { status: :skipped, schedule: schedule_payload(schedule, state) }
    end

    def skip_schedule(schedule, state, now:, reason:)
      state.last_status = "skipped"
      state.last_error = reason
      state.skip_count = state.skip_count.to_i + 1
      state.next_due_at = schedule.next_due_after(now)
      state.mark_stopped!(now:) if reason.to_s == "interactive"
      publish("schedule.skipped", schedule, state, reason:)
    end

    def build_scheduled_agent(schedule, agents)
      project = project_for(schedule)
      @agent_store.create_scheduled(
        project,
        schedule_key: schedule.key,
        name: schedule.agent_name,
        system_message: schedule.system_message,
        existing_agents: agents
      )
    end

    def reconcile_archived_agent_state!(schedule, state, agent_key, now:)
      state.previous_target_key = agent_key
      state.last_target_key = nil
      state.last_target_kind = nil
      state.last_finished_at ||= now
      state.run_count = 0
      state.mark_scheduled! if state.stopped? || state.paused?
      publish("schedule.agent_archived", schedule, state,
              agent_key: agent_key,
              target_key: agent_key,
              reason: "manual_archive")
    end

    def preserve_archived_agent_system_message!(schedule, archived_agent)
      return false unless archived_agent
      return false unless schedule.system_message.to_s.strip.empty?

      schedule_registry.persist_system_message(schedule.key, archived_agent.prompt)
    rescue ScheduleRegistry::Error
      false
    end

    def last_agent(schedule, state, agents)
      key = state.last_target_key.to_s
      key = schedule.agent_key.to_s if key.empty?
      return nil if key.empty?

      agents.find { |agent| agent.key == key }
    end

    def resume_state!(schedule, state, now:)
      was_stopped = state.stopped?
      was_paused = state.paused?
      state.mark_scheduled!
      state.next_due_at = schedule.next_due_after(now)
      state.resumed_at = now if was_stopped || was_paused
      reason = was_stopped ? "stopped" : (was_paused ? "paused" : "manual")
      publish("schedule.resumed", schedule, state, reason: reason)
    end

    def ensure_not_expired!(schedule, state, states, now:)
      return unless schedule.expired?(now)

      expire_schedule!(schedule, state, now:)
      store.save(states)
      raise ScheduleRegistry::Error, "Schedule #{schedule.key.inspect} ended at #{schedule.ends_at.iso8601}"
    end

    def interactive_scheduled_session?(schedule, state, agent)
      return false unless schedule.archive_previous_agent?
      return false unless agent
      boundary = [state.last_started_at, state.resumed_at].compact.max
      return false unless boundary

      !agent.latest_user_message_after(
        boundary,
        ignored_metadata: { "scheduled_prompt" => true },
        inclusive: true
      ).to_s.strip.empty?
    end

    def agent_needs_operator?(agent)
      (agent.status == "awaiting-input" && agent.latest_inquiry) || agent.status == "blocked"
    end

    def reconcile_completed_runs!(schedules, states, agents, now:)
      schedules.each do |schedule|
        state = store.state_for(states, schedule.key)
        agent = last_agent(schedule, state, agents)
        next unless agent

        agent.poll!
        if agent.running?
          state.last_status = "running" if state.last_status == "started"
          next
        end
        next unless %w[started running queued].include?(state.last_status.to_s)
        next unless agent.last_run

        state.last_finished_at = agent.finished_at || now
        if agent.status == "succeeded"
          handle_success(schedule, state, agent, now:)
        elsif agent_needs_operator?(agent)
          handle_input_required(schedule, state, agent, now:)
        else
          handle_failure(schedule, state, agent, now:)
        end
      end
    end

    def handle_success(schedule, state, agent, now:)
      recovering = !!state.failure_started_at
      no_action = agent.no_action_needed?
      state.last_status = no_action ? "no_action_needed" : "succeeded"
      state.last_error = nil
      if no_action
        state.failure_started_at = nil
        publish("schedule.completed", schedule, state, agent_key: agent.key, status: agent.effective_status)
        return
      end
      if recovering
        notify_schedule_recovery(schedule, state, agent, now:)
        state.recovery_notified_at = now
        state.first_success_notified_at ||= now
        state.failure_started_at = nil
        publish("schedule.recovered", schedule, state, agent_key: agent.key, status: agent.status)
      elsif state.first_success_notified_at.nil?
        notify_schedule_first_success(schedule, state, agent, now:)
        state.first_success_notified_at = now
      end
      publish("schedule.completed", schedule, state, agent_key: agent.key, status: agent.status)
    end

    def handle_input_required(schedule, state, agent, now:)
      state.last_status = agent.status
      state.last_error = agent.last_summary
      state.failure_started_at ||= now
      state.mark_stopped!(now:)
      notify_schedule_input_required(schedule, state, agent, now:)
      publish("schedule.stopped", schedule, state, agent_key: agent.key, reason: "input_required")
    end

    def handle_failure(schedule, state, agent, now:)
      state.last_status = agent.status
      state.last_error = agent.last_summary
      state.failure_started_at ||= now
      state.mark_stopped!(now:)
      notify_schedule_failure(schedule, state, now:, agent:)
      publish("schedule.failed", schedule, state, agent_key: agent.key, status: agent.status)
      publish("schedule.stopped", schedule, state, agent_key: agent.key, reason: "failure")
    end

    def notify_schedule_failure(schedule, state, now:, agent: nil, error: nil)
      id = [
        "schedule",
        schedule.key,
        "failure",
        state.last_target_key,
        state.last_finished_at&.iso8601 || now.iso8601
      ].join(":")
      payload = {
        title: "Schedule failed",
        body: "#{schedule.name}: #{error || agent&.last_summary || state.last_error || "failed"}. Schedule stopped.",
        tag: "hq:schedule:#{schedule.key}:failure",
        url: agent ? "/#agent/#{agent.key}" : "/#setup"
      }
      send_schedule_push(id, payload, urgency: "high", ttl: 3600)
    end

    def notify_schedule_input_required(schedule, state, agent, now:)
      id = [
        "schedule",
        schedule.key,
        "input-required",
        state.last_target_key,
        state.last_finished_at&.iso8601 || now.iso8601
      ].join(":")
      payload = {
        title: "Schedule needs input",
        body: "#{schedule.name}: #{agent.last_summary || state.last_error || "waiting for operator input"}. Schedule stopped.",
        tag: "hq:schedule:#{schedule.key}:input-required",
        url: "/#agent/#{agent.key}"
      }
      send_schedule_push(id, payload, urgency: "high", ttl: 3600)
    end

    def notify_schedule_first_success(schedule, state, agent, now:)
      id = ["schedule", schedule.key, "first-success"].join(":")
      payload = {
        title: "Schedule succeeded",
        body: "#{schedule.name}: first run succeeded. Next run: #{format_time(state.next_due_at)}.",
        tag: "hq:schedule:#{schedule.key}:first-success",
        url: "/#agent/#{agent.key}"
      }
      send_schedule_push(id, payload, urgency: "normal", ttl: 900)
    end

    def notify_schedule_recovery(schedule, state, agent, now:)
      id = ["schedule", schedule.key, "recovery", state.failure_started_at&.iso8601 || now.iso8601].join(":")
      payload = {
        title: "Schedule succeeded after failure",
        body: "#{schedule.name}: succeeded after failure. Next run: #{format_time(state.next_due_at)}.",
        tag: "hq:schedule:#{schedule.key}:recovery",
        url: "/#agent/#{agent.key}"
      }
      send_schedule_push(id, payload, urgency: "normal", ttl: 900)
    end

    def send_schedule_push(id, payload, urgency:, ttl:)
      return unless @push_notification_store.record!(id, kind: "schedule", tag: payload.fetch(:tag))

      @web_push_notifier.send_payload!(payload, urgency:, ttl:)
    rescue StandardError => e
      HQ.logger.warn("Schedule") { "Schedule push failed: #{e.class} - #{e.message}" }
      nil
    end

    def format_time(value)
      value ? value.strftime("%Y-%m-%d %H:%M") : "unknown"
    end

    def publish(event, schedule, state, attrs = {})
      HQ.hooks.publish(
        event,
        {
          schedule_key: schedule.key,
          project_key: schedule.project_key,
          target_kind: "agent",
          target_key: state.last_target_key,
          next_due_at: state.next_due_at&.iso8601,
          last_status: state.last_status
        }.merge(attrs)
      )
    rescue StandardError
      nil
    end
  end
end
