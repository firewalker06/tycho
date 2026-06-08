# frozen_string_literal: true

require "time"

require_relative "../registry"
require_relative "agent_store"
require_relative "app_project"
require_relative "push_notification_store"
require_relative "schedule_registry"
require_relative "schedule_store"
require_relative "web_push_notifier"

module HQ
  class Scheduler
    DEFAULT_INTERVAL = 30
    MISSED_GRACE_SECONDS = 60

    attr_reader :registry, :schedule_registry, :store

    def initialize(registry: Registry.new, schedule_registry: nil, store: ScheduleStore.new,
                   push_notification_store: PushNotificationStore.new, web_push_notifier: nil)
      @registry = registry
      @projects = registry.projects.map { |config| AppProject.new(config) }
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
      changed = false
      rows = schedules.map do |schedule|
        state = store.state_for(states, schedule.key)
        changed = ensure_next_due!(schedule, state, now:) || changed
        schedule_payload(schedule, state)
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
      was_stopped = state.stopped?
      was_paused = state.paused?
      state.mark_scheduled!
      state.next_due_at = schedule.next_due_after(now)
      if was_stopped
        agents = load_agents
        retire_previous_session!(schedule, state, agents, now:)
        publish("schedule.resumed", schedule, state, reason: "stopped")
        persist(agents, states, dry_run: false)
        return { status: :resumed, schedule: schedule_payload(schedule, state) }
      end

      publish("schedule.resumed", schedule, state, reason: was_paused ? "paused" : "manual")
      store.save(states)
      { status: :resumed, schedule: schedule_payload(schedule, state) }
    end

    def run_now(key, now: Time.now, dry_run: false)
      schedule = find_schedule!(key)
      states = store.load
      state = store.state_for(states, schedule.key)
      agents = load_agents
      result = dispatch_schedule(schedule, state, agents, now:, dry_run:)
      persist(agents, states, dry_run:)
      result
    end

    def reconcile_archived_agent!(agent_key, now: Time.now)
      key = agent_key.to_s
      return false if key.empty?

      schedules = schedule_registry.schedules
      states = store.load
      changed = false
      schedules.each do |schedule|
        state = store.state_for(states, schedule.key)
        next unless state.last_target_key.to_s == key

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
        ensure_next_due!(schedule, state, now:)
        next unless runnable?(schedule, state)
        next unless state.next_due_at && state.next_due_at <= now

        if missed_due?(state, now) && schedule.missed_policy == "skip_missed"
          skip_schedule(schedule, state, now:, reason: "missed")
          totals[:skipped] += 1
          next
        end

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

    def schedule_payload(schedule, state)
      {
        key: schedule.key,
        name: schedule.name,
        status: state.status,
        enabled: schedule.enabled?,
        paused: state.paused?,
        stopped: state.stopped?,
        project_key: schedule.project_key,
        agent_name: schedule.agent_name,
        cron: schedule.cron,
        timezone: schedule.timezone,
        message_source: schedule.message_source,
        message: schedule.message,
        message_file: schedule.message_file,
        policy: schedule.policy,
        next_due_at: state.next_due_at&.iso8601,
        last_status: state.last_status,
        last_error: state.last_error,
        last_target_key: state.last_target_key,
        run_count: state.run_count.to_i,
        skip_count: state.skip_count.to_i
      }
    end

    def find_schedule!(key)
      schedule = schedule_registry.find(key)
      raise ScheduleRegistry::Error, "Unknown schedule: #{key}" unless schedule

      schedule
    end

    def project_for(schedule)
      @projects.find { |project| project.key == schedule.project_key }
    end

    def ensure_next_due!(schedule, state, now:)
      return false if state.next_due_at

      state.next_due_at = schedule.next_due_after(now)
      true
    end

    def runnable?(schedule, state)
      schedule.enabled? && state.scheduled?
    end

    def missed_due?(state, now)
      state.next_due_at && state.next_due_at < now - MISSED_GRACE_SECONDS
    end

    def dispatch_schedule(schedule, state, agents, now:, dry_run: false)
      target = last_agent(state, agents)
      running = target&.running?
      if running && schedule.overlap_policy != "parallel"
        return handle_overlap(schedule, state, now:, dry_run:)
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

      archive_previous_agent!(schedule, state, agents) unless running
      message = schedule.message_text.to_s.strip
      raise ScheduleRegistry::Error, "Schedule #{schedule.key.inspect} has empty message" if message.empty?

      project = project_for(schedule)
      agent = @agent_store.create_scheduled(
        project,
        schedule_key: schedule.key,
        name: schedule.agent_name,
        message: message,
        existing_agents: agents
      )
      agent.start!
      agents.unshift(agent)

      due_at = state.next_due_at || now
      state.last_due_at = due_at
      state.last_started_at = agent.started_at || now
      state.last_finished_at = nil
      state.last_status = "started"
      state.last_error = nil
      state.last_target_kind = "agent"
      state.last_target_key = agent.key
      state.next_due_at = schedule.next_due_after(now)
      state.run_count = state.run_count.to_i + 1
      publish("schedule.started", schedule, state, agent_key: agent.key)

      {
        status: :started,
        schedule: schedule_payload(schedule, state),
        agent: agent
      }
    rescue StandardError => e
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
      case schedule.overlap_policy
      when "queue"
        state.last_status = "queued"
        publish("schedule.skipped", schedule, state, reason: "queued")
        { status: :queued, schedule: schedule_payload(schedule, state) }
      else
        skip_schedule(schedule, state, now:, reason: "overlap")
        { status: :skipped, schedule: schedule_payload(schedule, state) }
      end
    end

    def skip_schedule_result(schedule, state, now:, reason:)
      skip_schedule(schedule, state, now:, reason:)
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

    def archive_previous_agent!(schedule, state, agents)
      return unless schedule.archive_previous_agent?
      return if state.last_target_key.to_s.empty?

      target = agents.find { |agent| agent.key == state.last_target_key }
      return unless target
      return if target.running?

      archive_path = target.archive_logs!
      agents.reject! { |agent| agent.key == target.key }
      state.previous_target_key = target.key
      publish("schedule.agent_archived", schedule, state, agent_key: target.key, archive_path:)
    end

    def reconcile_archived_agent_state!(schedule, state, agent_key, now:)
      state.previous_target_key = agent_key
      state.last_target_key = nil
      state.last_target_kind = nil
      state.last_finished_at ||= now
      publish("schedule.agent_archived", schedule, state,
              agent_key: agent_key,
              target_key: agent_key,
              reason: "manual_archive")
    end

    def retire_previous_session!(schedule, state, agents, now:)
      return if state.last_target_key.to_s.empty?

      target = agents.find { |agent| agent.key == state.last_target_key }
      return unless target

      target.retire_for_archive! if target.respond_to?(:retire_for_archive!)
      archive_path = target.archive_logs!
      agents.reject! { |agent| agent.key == target.key }
      state.previous_target_key = target.key
      state.last_target_key = nil
      state.last_target_kind = nil
      state.last_finished_at ||= now
      publish("schedule.agent_archived", schedule, state,
              agent_key: target.key,
              target_key: target.key,
              archive_path: archive_path,
              reason: "resume_stopped_schedule")
    end

    def last_agent(state, agents)
      return nil if state.last_target_key.to_s.empty?

      agents.find { |agent| agent.key == state.last_target_key }
    end

    def interactive_scheduled_session?(schedule, state, agent)
      return false unless schedule.archive_previous_agent?
      return false unless agent
      return false unless state.last_started_at

      !agent.latest_user_message_after(
        state.last_started_at,
        ignored_metadata: { "scheduled_prompt" => true },
        inclusive: true
      ).to_s.strip.empty?
    end

    def reconcile_completed_runs!(schedules, states, agents, now:)
      schedules.each do |schedule|
        state = store.state_for(states, schedule.key)
        agent = last_agent(state, agents)
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
        else
          handle_failure(schedule, state, agent, now:)
        end
      end
    end

    def handle_success(schedule, state, agent, now:)
      recovering = !!state.failure_started_at
      state.last_status = "succeeded"
      state.last_error = nil
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
