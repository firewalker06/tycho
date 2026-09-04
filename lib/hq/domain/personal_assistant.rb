# frozen_string_literal: true

require "date"
require "fileutils"
require "json"
require "time"
require "rbconfig"
require "securerandom"

require_relative "constants"
require_relative "file_store"
require_relative "managed_agent"

module HQ
  class PersonalAssistantLifecycle
    ROLE = "personal_assistant_daily"
    INTRODUCTION = "I’m your Tycho Personal Assistant. I can read Tycho documentation, inspect local status, offer skill installation, and coordinate agents on this Tycho server.\n\nI never make changes without an exact Tycho confirmation. I use one daily conversation and cannot be manually archived.\n\nTry: ‘Show the documentation for schedules’, ‘What agents are running?’, or ‘Prepare an agent to review this project’."

    def initialize(registry:, agent_store:, clock: -> { Time.now }, state_path: File.join(PERSONAL_ASSISTANT_DIR, "state.json"), summary_runner: nil, archiver: nil)
      @registry, @agent_store, @clock, @state_path = registry, agent_store, clock, state_path
      @summary_runner = summary_runner
      @archiver = archiver || method(:archive_internal!)
    end

    def status
      synchronize { |state| reconcile!(state); payload(state) }
    end

    def reconcile
      synchronize { |state| reconcile!(state); advance!(state); payload(state) }
    end

    def accepting_prompts?(key)
      synchronize { |state| reconcile!(state); state["phase"] == "active" && state["active_key"] == key.to_s }
    end

    def setup!(attrs)
      raise ArgumentError, "Setup must be explicitly confirmed" unless attrs["confirmed"] == true
      config = config_from(attrs)
      validate!(config)
      @registry.update_personal_assistant!(config.merge("enabled" => true))
      synchronize { |state| state["phase"] ||= "ready"; persist(state); payload(state) }
    end

    def open!
      synchronize do |state|
        reconcile!(state); advance!(state)
        config = configured!
        return payload(state) if state["active_key"]
        now = @clock.call
        date = local_date(now, config.fetch("timezone"))
        agent = ManagedAgent.new(key: "personal-assistant-#{date}-#{state["generation"].to_i + 1}", name: "Personal Assistant · #{date}", project_key: "__personal_assistant__", template_key: "personal_assistant_daily", workspace: workspace, prompt: INTRODUCTION, created_at: now, sandbox_mode: "read-only", agent: "codex", model: config.fetch("model"), reasoning_effort: config.fetch("reasoning_effort"), messages: [ManagedAgent::AgentMessage.new(role: "system", content: INTRODUCTION, created_at: now)], role: ROLE)
        @agent_store.mutate { |agents, _| raise ArgumentError, "A Personal Assistant session is already active" if agents.any?(&:personal_assistant?); agents.unshift(agent) }
        state.merge!("active_key" => agent.key, "active_date" => date, "active_timezone" => config.fetch("timezone"), "generation" => state["generation"].to_i + 1, "phase" => "active")
        persist(state)
        payload(state).merge(agent: agent.to_hash)
      end
    end

    private

    def configured!
      config = @registry.personal_assistant
      raise ArgumentError, "Personal Assistant is not configured" unless config["enabled"] == true
      config
    end

    def config_from(attrs)
      { "model" => attrs["model"].to_s.strip, "reasoning_effort" => attrs["reasoning_effort"].to_s.strip, "timezone" => attrs["timezone"].to_s.strip }
    end

    def validate!(config)
      raise ArgumentError, "Codex model is required" if config["model"].empty?
      raise ArgumentError, "Codex reasoning effort is required" if config["reasoning_effort"].empty?
      raise ArgumentError, "Timezone must be an IANA timezone" unless config["timezone"].match?(%r{\A[A-Za-z_]+(?:/[A-Za-z_+-]+)+\z}) && File.file?(File.join("/usr/share/zoneinfo", config["timezone"]))
    end

    def local_date(now, timezone)
      output = IO.popen({ "TZ" => timezone }, [RbConfig.ruby, "-e", "puts Time.at(ARGV[0].to_f).getlocal.strftime('%F')", now.to_f.to_s], &:read).to_s.strip
      output.empty? ? now.strftime("%F") : output
    end

    def workspace
      path = File.join(USER_WORKSPACES_DIR, "personal_assistant")
      FileUtils.mkdir_p(path)
      path
    end

    def reconcile!(state)
      return unless @registry.personal_assistant["enabled"] == true
      return unless state["active_key"]
      timezone = state["active_timezone"] || @registry.personal_assistant["timezone"]
      return if timezone.to_s.empty? || state["active_date"] == local_date(@clock.call, timezone)
      state["phase"] = "closing" if state["phase"] == "active"
    end

    def advance!(state)
      return unless %w[closing summarizing archiving].include?(state["phase"])
      agent = @agent_store.load.find { |candidate| candidate.key == state["active_key"] }
      return if agent&.running?
      if state["phase"] == "closing"
        dispatch_summary!(state, agent)
        return
      end
      if state["phase"] == "summarizing"
        return if agent&.running?
        handoff = summary_handoff(agent, state)
        write_handoff!(state, handoff)
        state["phase"] = "archiving"
      end
      return unless state["phase"] == "archiving"
      @archiver.call(agent) if agent
      state.delete("active_key"); state.delete("active_date"); state.delete("active_timezone"); state["phase"] = "dormant"
    rescue StandardError => e
      state["last_error"] = e.message
      if state["phase"] == "summarizing"
        handoff = fallback_handoff(agent)
        write_handoff!(state, handoff)
        state["phase"] = "archiving"
      end
    end

    def fallback_handoff(agent)
      messages = agent ? agent.messages.select { |message| message.role == "user" }.last(10).map(&:content) : []
      { "summary" => "Fallback continuity generated by Tycho after summary failure.", "open_items" => messages, "decisions" => [], "references" => [] }
    end

    def dispatch_summary!(state, agent)
      raise "Personal Assistant session is missing" unless agent
      return if state["summary_run_id"]

      run_id = SecureRandom.uuid
      @agent_store.mutate do |agents, _|
        target = agents.find { |candidate| candidate.key == agent.key }
        raise "Personal Assistant session is missing" unless target
        target.add_user_message!("[TYCHO INTERNAL SUMMARY ONLY] Summarize this daily session into the normal structured result. Do not propose or execute actions. Include summary, decisions, open items, references, and outstanding child agents.", metadata: { "personal_assistant_summary" => true, "summary_run_id" => run_id })
      end
      state["summary_run_id"] = run_id
      state["phase"] = "summarizing"
      # Persist the intent before asking the harness to run.  A transient launch
      # failure must not append a second summary prompt on the next scheduler tick.
      persist(state)
      @agent_store.start_agent!(agent.key)
    rescue StandardError
      state["summary_run_id"] ||= run_id if defined?(run_id)
      raise
    end

    def summary_handoff(agent, state)
      result = @summary_runner ? @summary_runner.call(agent) : agent&.structured_result
      result = {} unless result.is_a?(Hash)
      handoff = result["memory_handoff"] || result[:memory_handoff] || {}
      handoff = {} unless handoff.is_a?(Hash)
      fallback_handoff(agent).merge(handoff).merge("action_proposals_ignored" => true, "summary_run_id" => state["summary_run_id"])
    end

    def write_handoff!(state, handoff)
      return if state["handoff_path"] && File.file?(state["handoff_path"])

      handoff["schema_version"] = 1
      handoff["provenance"] = { "agent_key" => state["active_key"], "generation" => state["generation"].to_i }
      handoff["previous_day_detail"] = handoff["summary"].to_s.byteslice(0, 2_000)
      handoff["outstanding_child_agents"] ||= []
      handoff["continuity"] = handoff.to_json.byteslice(0, 4_000)
      handoff["closed_at"] = @clock.call.utc.iso8601
      handoff["active_date"] = state["active_date"]
      path = File.join(File.dirname(@state_path), "handoffs", "#{state["active_date"]}-#{state["generation"]}.json")
      FileUtils.mkdir_p(File.dirname(path)); FileStore.write_json(path, handoff)
      state["handoff_path"] = path
    end

    def archive_internal!(agent)
      @agent_store.mutate do |agents, _|
        target = agents.find { |candidate| candidate.key == agent.key }
        target.archive_logs! if target
        agents.reject! { |candidate| candidate.key == agent.key }
      end
    end

    def synchronize
      FileUtils.mkdir_p(File.dirname(@state_path))
      File.open("#{@state_path}.lock", "w") { |lock| lock.flock(File::LOCK_EX); state = FileStore.read_json(@state_path, fallback: {}); result = yield state; persist(state); result }
    end

    def persist(state)
      FileStore.write_json(@state_path, state.merge("version" => 1))
    end

    def payload(state)
      { state: state["phase"] || (@registry.personal_assistant["enabled"] ? "ready" : "unconfigured"), configured: @registry.personal_assistant["enabled"] == true, active_key: state["active_key"], active_date: state["active_date"], generation: state["generation"].to_i, introduction: INTRODUCTION, config: @registry.personal_assistant.slice("model", "reasoning_effort", "timezone") }
    end
  end
end
