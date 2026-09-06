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
require_relative "memory_handoff"

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
      synchronize { |state| snapshot_finalized_proposals!(state); reconcile!(state); payload(state) }
    end

    def reconcile
      synchronize { |state| snapshot_finalized_proposals!(state); reconcile!(state); snapshot_finalized_proposals!(state); advance!(state); payload(state) }
    end

    def finalized_proposals
      synchronize { |state| snapshot_finalized_proposals!(state); Array(state["finalized_proposals"]).reject { |snapshot| snapshot["registered"] == true } }
    end

    def mark_finalized_proposals_registered!(run_id)
      synchronize do |state|
        state["finalized_proposals"] = Array(state["finalized_proposals"]).map { |snapshot| snapshot["run_id"].to_s == run_id.to_s ? snapshot.merge("registered" => true) : snapshot }
      end
    end

    def accepting_prompts?(key)
      synchronize { |state| snapshot_finalized_proposals!(state); reconcile!(state); state["phase"] == "active" && state["active_key"] == key.to_s }
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
        protected = @agent_store.load.find(&:personal_assistant?)
        if state["active_key"] && !protected
          state.delete("active_key"); state.delete("active_date"); state.delete("active_timezone")
          state["phase"] = "dormant"
        elsif !state["active_key"] && protected
          state.merge!("active_key" => protected.key, "active_date" => local_date(protected.created_at || @clock.call, config.fetch("timezone")), "active_timezone" => config.fetch("timezone"), "phase" => "active")
        end
        if state["active_key"]
          payload(state)
        else
          now = @clock.call
          date = local_date(now, config.fetch("timezone"))
          # Registered records are only replay protection. Once a new daily
          # session begins, retain unresolved older work but drop consumed IDs.
          state["finalized_proposals"] = Array(state["finalized_proposals"]).reject { |snapshot| snapshot["registered"] == true }
          prior = prior_continuity(state)
          prompt = [INTRODUCTION, prior].compact.join("\n\n")
          agent = ManagedAgent.new(key: "personal-assistant-#{date}-#{state["generation"].to_i + 1}", name: "Personal Assistant · #{date}", project_key: "__personal_assistant__", template_key: "personal_assistant_daily", workspace: workspace, prompt:, created_at: now, sandbox_mode: "read-only", agent: "codex", model: config.fetch("model"), reasoning_effort: config.fetch("reasoning_effort"), messages: [ManagedAgent::AgentMessage.new(role: "system", content: prompt, created_at: now)], role: ROLE)
          @agent_store.create_personal_assistant!(agent)
          state.merge!("active_key" => agent.key, "active_date" => date, "active_timezone" => config.fetch("timezone"), "generation" => state["generation"].to_i + 1, "phase" => "active")
          state.delete("summary_run_id"); state.delete("handoff_path"); state.delete("last_error")
          payload(state).merge(agent: agent.to_hash)
        end
      end
    end

    # Reset is deliberately separate from the normal daily rollover. It first
    # makes every protected session safe to remove, then clears configuration
    # and lifecycle state. A failed stop/archive leaves configuration and state
    # intact so the operator can retry without creating an orphaned session.
    def reset!
      synchronize do |state|
        protected_sessions = @agent_store.load.select(&:personal_assistant?)
        protected_sessions.each { |agent| @agent_store.stop_agent!(agent.key) if agent.running? }

        protected_sessions.each do |agent|
          current = @agent_store.load.find { |candidate| candidate.key == agent.key && candidate.personal_assistant? }
          raise ArgumentError, "Personal Assistant is still running" if current&.running?

          @agent_store.archive_personal_assistant!(agent.key) if current
        end

        yield if block_given?
        @registry.clear_personal_assistant!
        state.clear
        payload(state)
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
      zone = config["timezone"]
      raise ArgumentError, "Timezone must be an IANA timezone" unless iana_timezone?(zone)
    end

    def iana_timezone?(zone)
      return false if zone.include?("..") || zone.start_with?("/")

      root = File.realpath("/usr/share/zoneinfo")
      path = File.realpath(File.expand_path(zone, root))
      return false unless path.start_with?("#{root}/") && File.file?(path)

      File.binread(path, 4) == "TZif"
    rescue Errno::ENOENT, Errno::ENOTDIR
      false
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
      unless @registry.personal_assistant["enabled"] == true
        adopt_orphan!(state)
        return unless controlled_shutdown!(state)

        state.delete("active_key"); state.delete("active_date"); state.delete("active_timezone")
        state["phase"] = "unconfigured"
        return
      end
      return unless state["active_key"]
      unless @agent_store.load.any? { |agent| agent.key == state["active_key"] && agent.personal_assistant? }
        state.delete("active_key"); state.delete("active_date"); state.delete("active_timezone")
        state["phase"] = "dormant"
        return
      end
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
        unless state["summary_run_id"]
          dispatch_summary!(state, agent)
          return
        end
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

      intent_id = state["summary_intent_id"] || SecureRandom.uuid
      state["summary_intent_id"] = intent_id
      @agent_store.mutate do |agents, _|
        target = agents.find { |candidate| candidate.key == agent.key }
        raise "Personal Assistant session is missing" unless target
        unless target.messages.any? { |message| message.metadata&.fetch("personal_assistant_summary_intent", nil) == intent_id }
          target.add_user_message!("[TYCHO INTERNAL SUMMARY ONLY] Summarize this daily session into the normal structured result. Do not propose or execute actions. Include summary, decisions, open items, references, and outstanding child agents.", metadata: { "personal_assistant_summary" => true, "personal_assistant_summary_intent" => intent_id })
        end
      end
      state["phase"] = "summarizing"
      # Persist the intent before asking the harness to run.  A transient launch
      # failure must not append a second summary prompt on the next scheduler tick.
      persist(state)
      existing = agent.runs.find { |run| run.metadata&.fetch("personal_assistant_summary_intent", nil) == intent_id }
      started = existing ? agent : @agent_store.start_agent!(agent.key, run_metadata: { "personal_assistant_summary_intent" => intent_id })
      summary_run = existing || started.last_run
      state["summary_run_id"] = summary_run&.run_id
      raise "Personal Assistant summary did not create a run" if state["summary_run_id"].to_s.empty?
    rescue StandardError
      raise
    end

    def summary_handoff(agent, state)
      result = @summary_runner ? @summary_runner.call(agent) : agent&.structured_result
      result = {} unless result.is_a?(Hash)
      handoff = MemoryHandoff.normalize(result["memory_handoff"] || result[:memory_handoff])
      fallback = fallback_handoff(agent)
      return fallback unless result["status"] == "success" && agent&.last_run&.status == "success" && agent.last_run.run_id == state["summary_run_id"]

      handoff ? { "summary" => handoff["outcome"], "open_items" => [handoff["continuing_context"]], "decisions" => handoff["decisions"], "references" => handoff["references"], "lessons" => handoff["lessons"], "promotion_candidates" => handoff["promotion_candidates"] }.compact : fallback
    end

    def write_handoff!(state, handoff)
      return if state["handoff_path"] && File.file?(state["handoff_path"])

      handoff = bounded_handoff(handoff)
      handoff["schema_version"] = 1
      handoff["provenance"] = { "agent_key" => truncate(state["active_key"].to_s, 160), "generation" => state["generation"].to_i }
      handoff["closed_at"] = @clock.call.utc.iso8601
      handoff["active_date"] = state["active_date"]
      path = File.join(File.dirname(@state_path), "handoffs", "#{state["active_date"]}-#{state["generation"]}.json")
      FileUtils.mkdir_p(File.dirname(path)); FileStore.write_json(path, handoff)
      state["handoff_path"] = path
    end

    def archive_internal!(agent)
      @agent_store.archive_personal_assistant!(agent.key)
    end

    def synchronize
      FileUtils.mkdir_p(File.dirname(@state_path))
      File.open("#{@state_path}.lock", "w") { |lock| lock.flock(File::LOCK_EX); state = FileStore.read_json(@state_path, fallback: {}); result = yield state; persist(state); result }
    end

    def persist(state)
      FileStore.write_json(@state_path, state.merge("version" => 1))
    end

    def payload(state)
      { state: state["phase"] || (@registry.personal_assistant["enabled"] ? "ready" : "unconfigured"), configured: @registry.personal_assistant["enabled"] == true, active_key: state["active_key"], active_date: state["active_date"], generation: state["generation"].to_i, introduction: INTRODUCTION, handoff_path: state["handoff_path"], error: state["last_error"], summary_run_id: state["summary_run_id"], config: @registry.personal_assistant.slice("model", "reasoning_effort", "timezone") }
    end

    def bounded_handoff(value)
      value = value.is_a?(Hash) ? value : {}
      text = ->(key, limit) { truncate(value[key].to_s, limit) }
      list = ->(key, count, limit) { Array(value[key]).filter_map { |item| item.is_a?(String) ? truncate(item, limit) : nil }.reject(&:empty?).first(count) }
      { "summary" => text.call("summary", 2_000), "open_items" => list.call("open_items", 12, 600), "decisions" => list.call("decisions", 20, 600), "references" => list.call("references", 20, 600), "lessons" => list.call("lessons", 12, 600), "promotion_candidates" => list.call("promotion_candidates", 12, 600), "outstanding_child_agents" => list.call("outstanding_child_agents", 20, 160) }
    end

    def prior_continuity(state)
      path = state["handoff_path"].to_s
      return nil unless File.file?(path)

      handoff = FileStore.read_json(path, fallback: {})
      compact = bounded_handoff(handoff)
      return nil if compact.values.all? { |value| value.respond_to?(:empty?) && value.empty? }

      "[TYCHO PRIOR DAILY CONTINUITY — bounded]\n#{truncate(JSON.generate(compact), 4_000)}"
    end

    def truncate(value, bytes)
      string = value.to_s.encode(Encoding::UTF_8, invalid: :replace, undef: :replace).strip
      string.each_char.with_object(String.new) { |char, result| break result if result.bytesize + char.bytesize > bytes; result << char }
    end

    def controlled_shutdown!(state)
      adopt_orphan!(state)
      key = state["active_key"].to_s
      return if key.empty?

      agent = @agent_store.load.find { |candidate| candidate.key == key && candidate.personal_assistant? }
      return true unless agent
      @agent_store.stop_agent!(key) if agent.running?
      agent = @agent_store.load.find { |candidate| candidate.key == key && candidate.personal_assistant? }
      return false if agent&.running?

      @agent_store.archive_personal_assistant!(key) if agent
      true
    rescue StandardError => e
      state["last_error"] = e.message
      false
    end

    def adopt_orphan!(state)
      return if state["active_key"]

      agent = @agent_store.load.find(&:personal_assistant?)
      return unless agent

      state.merge!("active_key" => agent.key, "active_date" => state["active_date"] || @clock.call.strftime("%F"), "active_timezone" => state["active_timezone"] || @registry.personal_assistant["timezone"], "phase" => "active")
    end

    def snapshot_finalized_proposals!(state)
      return unless state["active_key"] && %w[active closing].include?(state["phase"])

      agent = @agent_store.load.find { |candidate| candidate.key == state["active_key"] && candidate.personal_assistant? }
      return unless agent
      snapshots = Array(state["finalized_proposals"])
      agent.runs.each do |run|
        proposals = run.metadata&.fetch("personal_assistant_action_proposals", nil)
        next unless run.status == "success" && proposals.is_a?(Array) && proposals.any?
        next if run.run_id.to_s == state["summary_run_id"].to_s && !state["summary_run_id"].to_s.empty?
        next if snapshots.any? { |snapshot| snapshot["run_id"] == run.run_id }

        snapshots << { "run_id" => run.run_id, "active_key" => agent.key, "proposals" => proposals }
      end
      state["finalized_proposals"] = snapshots
    end
  end
end
