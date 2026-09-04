# frozen_string_literal: true

require "date"
require "fileutils"
require "json"
require "time"
require "rbconfig"

require_relative "constants"
require_relative "file_store"
require_relative "managed_agent"

module HQ
  class PersonalAssistantLifecycle
    ROLE = "personal_assistant_daily"
    INTRODUCTION = "I’m your Tycho Personal Assistant. I can read Tycho documentation, inspect local status, offer skill installation, and coordinate agents on this Tycho server.\n\nI never make changes without an exact Tycho confirmation. I use one daily conversation and cannot be manually archived.\n\nTry: ‘Show the documentation for schedules’, ‘What agents are running?’, or ‘Prepare an agent to review this project’."

    def initialize(registry:, agent_store:, clock: -> { Time.now }, state_path: File.join(PERSONAL_ASSISTANT_DIR, "state.json"))
      @registry, @agent_store, @clock, @state_path = registry, agent_store, clock, state_path
    end

    def status
      synchronize { |state| reconcile!(state); payload(state) }
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
        reconcile!(state)
        config = configured!
        return payload(state) if state["active_key"]
        now = @clock.call
        date = local_date(now, config.fetch("timezone"))
        agent = ManagedAgent.new(key: "personal-assistant-#{date}-#{state["generation"].to_i + 1}", name: "Personal Assistant · #{date}", project_key: "__personal_assistant__", template_key: "personal_assistant_daily", workspace: workspace, prompt: INTRODUCTION, created_at: now, sandbox_mode: "read-only", agent: "codex", model: config.fetch("model"), reasoning_effort: config.fetch("reasoning_effort"), messages: [ManagedAgent::AgentMessage.new(role: "system", content: INTRODUCTION, created_at: now)], role: ROLE)
        @agent_store.mutate { |agents, _| raise ArgumentError, "A Personal Assistant session is already active" if agents.any?(&:personal_assistant?); agents.unshift(agent) }
        state.merge!("active_key" => agent.key, "active_date" => date, "generation" => state["generation"].to_i + 1, "phase" => "active")
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
      output = IO.popen({ "TZ" => timezone }, [RbConfig.ruby, "-e", "puts Time.now.strftime('%F')"], &:read).to_s.strip
      output.empty? ? now.strftime("%F") : output
    end

    def workspace
      path = File.join(USER_WORKSPACES_DIR, "personal_assistant")
      FileUtils.mkdir_p(path)
      path
    end

    def reconcile!(state)
      return unless state["active_key"] && @registry.personal_assistant["enabled"] == true
      state["phase"] = "closing" if state["active_date"] != local_date(@clock.call, @registry.personal_assistant.fetch("timezone"))
      persist(state)
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
