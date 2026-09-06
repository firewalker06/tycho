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
    INTRODUCTION = "I’m FRED, your Tycho Personal Assistant. I can explain Tycho, inspect agents, projects, schedules, and recent runs, and prepare project or agent work on this server.\n\nI report action results as data. I only propose mutations for exact Tycho confirmation; I never make arbitrary tooling changes. Creating an agent prepares it, and starting or messaging it needs its own confirmation.\n\nI use one daily conversation with a bounded handoff to the next day. Try: ‘Show running agents’, ‘Explain schedules’, or ‘Prepare an agent to review this project’."

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
      synchronize do |state|
        state["phase"] ||= "ready"
        state["settings_updated_at"] = @clock.call.utc.iso8601
        payload(state)
      end
    end

    # A restart is deliberately distinct from reset. It keeps the configured
    # settings and archive, but closes the current daily thread once it is idle
    # and starts a new generation with a compact handoff.
    def restart!(attrs = {})
      raise ArgumentError, "Restart FRED requires exact confirmation" unless attrs["confirmed"] == true

      synchronize do |state|
        reconcile!(state)
        raise ArgumentError, "FRED is finishing its daily rollover" if %w[closing summarizing archiving].include?(state["phase"])

        agent = active_agent(state)
        if agent
          raise ArgumentError, "Wait for FRED's current work to finish before restarting" if agent.running?

          handoff = fallback_handoff(agent, state, summary: "Conversation archived for a confirmed restart. Recent user messages are included as context.")
          write_handoff!(state, handoff, reason: "restart")
          @archiver.call(agent)
          clear_active_state!(state)
          state["phase"] = "dormant"
        end
      end
      open!
    end

    # Action execution is owned by the Remote service. Keeping its receipts in
    # lifecycle state gives the next daily session stable references without
    # starting another FRED run or relying on a model summary to rediscover them.
    def record_action_result!(proposal)
      return unless proposal.is_a?(Hash)

      synchronize do |state|
        id = proposal["id"].to_s
        return if id.empty?

        records = Array(state["task_references"])
        record = task_reference(proposal)
        records.reject! { |item| item["id"].to_s == id }
        records << record
        state["task_references"] = records.last(40)
        state["last_action_result"] = record
        payload(state)
      end
    end

    def continuity_history_entry(id)
      synchronize do |state|
        entry = Array(state["history"]).find { |item| item["id"].to_s == id.to_s }
        raise ArgumentError, "FRED history entry was not found" unless entry

        path = entry["path"].to_s
        raise ArgumentError, "FRED history entry is unavailable" unless File.file?(path)

        fit_handoff_json(bounded_handoff(FileStore.read_json(path, fallback: {})), 12_000).merge(
          "id" => entry["id"], "active_date" => entry["active_date"], "closed_at" => entry["closed_at"], "reason" => entry["reason"]
        )
      end
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
          agent = ManagedAgent.new(key: "personal-assistant-#{date}-#{state["generation"].to_i + 1}", name: "Personal Assistant · #{date}", project_key: "__personal_assistant__", template_key: "personal_assistant_daily", workspace: workspace, prompt:, created_at: now, agent: "codex", model: config.fetch("model"), reasoning_effort: config.fetch("reasoning_effort"), messages: [ManagedAgent::AgentMessage.new(role: "system", content: prompt, created_at: now)], role: ROLE)
          @agent_store.create_personal_assistant!(agent)
          state.merge!("active_key" => agent.key, "active_date" => date, "active_timezone" => config.fetch("timezone"), "generation" => state["generation"].to_i + 1, "phase" => "active")
          state.delete("summary_run_id"); state.delete("summary_intent_id")
          if state.dig("recovery", "state") == "fallback_continuity"
            state["recovery"] = state["recovery"].merge("state" => "recovered", "recovered_at" => now.utc.iso8601)
          end
          state.delete("last_error") unless state.dig("recovery", "state") == "retrying"
          payload(state).merge(agent: agent.to_hash)
        end
      end
    end

    # Reset is deliberately separate from the normal daily rollover. It first
    # makes every protected session safe to remove, then clears configuration
    # and lifecycle state. A failed stop/delete leaves configuration and state
    # intact so the operator can retry without creating an orphaned session.
    def reset!
      synchronize do |state|
        protected_sessions = @agent_store.load.select(&:personal_assistant?)
        protected_sessions.each { |agent| @agent_store.stop_agent!(agent.key) if agent.running? }

        protected_sessions.each do |agent|
          current = @agent_store.load.find { |candidate| candidate.key == agent.key && candidate.personal_assistant? }
          raise ArgumentError, "Personal Assistant is still running" if current&.running?

          @agent_store.delete_personal_assistant!(agent.key) if current
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
      current = @registry.personal_assistant
      {
        "model" => attrs.key?("model") ? attrs["model"].to_s.strip : current["model"].to_s,
        "reasoning_effort" => attrs.key?("reasoning_effort") ? attrs["reasoning_effort"].to_s.strip.downcase : current["reasoning_effort"].to_s,
        "timezone" => attrs.key?("timezone") ? attrs["timezone"].to_s.strip : current["timezone"].to_s
      }
    end

    def validate!(config)
      raise ArgumentError, "Codex model is required" if config["model"].empty?
      raise ArgumentError, "Codex reasoning effort is required" if config["reasoning_effort"].empty?
      raise ArgumentError, "Codex reasoning effort is invalid" unless config["reasoning_effort"].match?(/\A[a-z][a-z0-9_-]{0,31}\z/)
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

    def next_rollover_at(now, timezone)
      output = IO.popen(
        { "TZ" => timezone },
        [RbConfig.ruby, "-rtime", "-rdate", "-e", "now = Time.at(ARGV[0].to_f).getlocal; date = Date.new(now.year, now.month, now.day) + 1; puts Time.local(date.year, date.month, date.day).utc.iso8601", now.to_f.to_s],
        &:read
      ).to_s.strip
      output.empty? ? nil : output
    rescue StandardError
      nil
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
      agent = active_agent(state)
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
        state.delete("last_error")
        state.delete("recovery")
        state["phase"] = "archiving"
      end
      return unless state["phase"] == "archiving"
      @archiver.call(agent) if agent
      clear_active_state!(state); state["phase"] = "dormant"
    rescue StandardError => e
      state["last_error"] = e.message
      state["recovery"] = { "state" => state["phase"] == "summarizing" ? "fallback_continuity" : "retrying", "error" => truncate(e.message, 600), "at" => @clock.call.utc.iso8601 }
      if state["phase"] == "summarizing"
        handoff = fallback_handoff(agent, state)
        write_handoff!(state, handoff, reason: "summary_failure")
        state["phase"] = "archiving"
      end
    end

    def fallback_handoff(agent, state = {}, summary: "Fallback continuity generated by Tycho after summary failure.")
      user_messages = agent ? agent.messages.select { |message| message.role == "user" && !message.metadata&.fetch("personal_assistant_summary", false) }.map(&:content) : []
      messages = [user_messages.first, *user_messages.last(9)].compact.uniq
      {
        "summary" => summary,
        "open_items" => messages,
        "decisions" => [],
        "references" => [],
        "outstanding_child_agents" => task_reference_labels(state)
      }
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
      fallback = fallback_handoff(agent, state)
      return fallback unless result["status"] == "success" && agent&.last_run&.status == "success" && agent.last_run.run_id == state["summary_run_id"]

      handoff ? {
        "summary" => handoff["outcome"], "open_items" => [handoff["continuing_context"]],
        "decisions" => handoff["decisions"], "references" => handoff["references"],
        "lessons" => handoff["lessons"], "promotion_candidates" => handoff["promotion_candidates"],
        "outstanding_child_agents" => task_reference_labels(state)
      }.compact : fallback
    end

    def write_handoff!(state, handoff, reason: "daily_rollover")
      path = File.join(File.dirname(@state_path), "handoffs", "#{state["active_date"]}-#{state["generation"]}.json")
      return if state["handoff_path"] == path && File.file?(path)

      handoff = bounded_handoff(handoff)
      handoff["schema_version"] = 1
      handoff["provenance"] = { "agent_key" => truncate(state["active_key"].to_s, 160), "generation" => state["generation"].to_i }
      handoff["closed_at"] = @clock.call.utc.iso8601
      handoff["active_date"] = state["active_date"]
      handoff["reason"] = reason
      FileUtils.mkdir_p(File.dirname(path)); FileStore.write_json(path, handoff)
      state["handoff_path"] = path
      history = Array(state["history"]).reject { |entry| entry["path"] == path }
      history << handoff_history_entry(handoff, path, state)
      state["history"] = history.last(21)
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
      config = @registry.personal_assistant.slice("model", "reasoning_effort", "timezone")
      active = active_agent(state)
      timezone = state["active_timezone"] || config["timezone"]
      {
        state: state["phase"] || (@registry.personal_assistant["enabled"] ? "ready" : "unconfigured"),
        configured: @registry.personal_assistant["enabled"] == true,
        active_key: state["active_key"], active_date: state["active_date"], generation: state["generation"].to_i,
        introduction: INTRODUCTION, handoff_path: state["handoff_path"], error: state["last_error"],
        summary_run_id: state["summary_run_id"], config: config,
        active_settings: active ? { model: active.model, reasoning_effort: active.reasoning_effort, timezone: state["active_timezone"] } : nil,
        settings_apply: active ? "Changes apply to the next daily conversation or a confirmed restart." : "Changes apply when you open FRED.",
        next_rollover_at: active && timezone.to_s != "" ? next_rollover_at(@clock.call, timezone) : nil,
        continuity: continuity_payload(state), history: history_payload(state),
        task_references: Array(state["task_references"]).last(20).reverse,
        last_action_result: state["last_action_result"], recovery: state["recovery"]
      }
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
      compact = fit_handoff_json(bounded_handoff(handoff), 3_800)
      late_action_references = task_reference_labels(state)
      unless late_action_references.empty?
        compact["outstanding_child_agents"] = (Array(compact["outstanding_child_agents"]) + late_action_references).uniq.first(20)
        compact = fit_handoff_json(compact, 3_800)
      end
      return nil if compact.values.all? { |value| value.respond_to?(:empty?) && value.empty? }

      "[TYCHO PRIOR DAILY CONTINUITY — bounded]\n#{JSON.generate(compact)}"
    end

    def active_agent(state)
      key = state["active_key"].to_s
      return nil if key.empty?

      @agent_store.load.find { |candidate| candidate.key == key && candidate.personal_assistant? }
    end

    def clear_active_state!(state)
      state.delete("active_key")
      state.delete("active_date")
      state.delete("active_timezone")
      state.delete("summary_run_id")
      state.delete("summary_intent_id")
    end

    def task_reference(proposal)
      tracked = proposal["tracked"].is_a?(Hash) ? proposal["tracked"] : {}
      result = proposal["result"].is_a?(Hash) ? proposal["result"] : {}
      agent = tracked["kind"].to_s == "agent" ? tracked : (result["agent"].is_a?(Hash) ? result["agent"] : {})
      {
        "id" => truncate(proposal["id"].to_s, 160),
        "type" => truncate(proposal["type"].to_s, 80),
        "state" => truncate(proposal["state"].to_s, 80),
        "recorded_at" => @clock.call.utc.iso8601,
        "kind" => truncate(tracked["kind"].to_s, 80),
        "key" => truncate(tracked["key"] || agent["key"] || tracked["agent_key"] || tracked["project_key"] || tracked["schedule_key"], 160),
        "name" => truncate(tracked["name"] || agent["name"], 240),
        "status" => truncate(tracked["status"] || agent["status"], 80),
        "project_key" => truncate(tracked["project_key"] || agent["project_key"], 160),
        "error" => truncate(proposal["error"], 600),
        "recovery" => proposal["recovery"].is_a?(Hash) ? bounded_hash(proposal["recovery"], 1_000) : nil
      }.delete_if { |_key, value| value.nil? || value == "" }
    end

    def task_reference_labels(state)
      Array(state["task_references"]).last(20).filter_map do |reference|
        next unless reference.is_a?(Hash)

        name, key = reference["name"].to_s, reference["key"].to_s
        target = if !name.empty? && !key.empty?
                   "#{name} (#{key})"
                 else
                   name.empty? ? key : name
                 end
        label = [reference["kind"], target, reference["status"]].compact.reject(&:empty?).join(": ")
        label.empty? ? nil : truncate(label, 160)
      end
    end

    def handoff_history_entry(handoff, path, state)
      {
        "id" => File.basename(path, ".json"), "path" => path,
        "active_date" => handoff["active_date"], "generation" => state["generation"].to_i,
        "agent_key" => handoff.dig("provenance", "agent_key"),
        "closed_at" => handoff["closed_at"], "reason" => handoff["reason"],
        "summary" => truncate(handoff["summary"], 800), "open_items" => Array(handoff["open_items"]).first(6),
        "outstanding_child_agents" => Array(handoff["outstanding_child_agents"]).first(12)
      }
    end

    def history_payload(state)
      Array(state["history"]).last(14).reverse.map do |entry|
        {
          "id" => truncate(entry["id"], 160), "active_date" => truncate(entry["active_date"], 32),
          "generation" => entry["generation"].to_i, "agent_key" => truncate(entry["agent_key"], 160),
          "closed_at" => truncate(entry["closed_at"], 64), "reason" => truncate(entry["reason"], 80),
          "summary" => truncate(entry["summary"], 800),
          "open_items" => Array(entry["open_items"]).filter_map { |item| item.is_a?(String) ? truncate(item, 180) : nil }.first(4),
          "outstanding_child_agents" => Array(entry["outstanding_child_agents"]).filter_map { |item| item.is_a?(String) ? truncate(item, 160) : nil }.first(8)
        }.delete_if { |_key, value| value.nil? || value == "" }
      end
    end

    def continuity_payload(state)
      path = state["handoff_path"].to_s
      return nil unless File.file?(path)

      handoff = FileStore.read_json(path, fallback: {})
      fit_handoff_json(bounded_handoff(handoff), 3_800).merge(
        "active_date" => handoff["active_date"], "closed_at" => handoff["closed_at"],
        "reason" => handoff["reason"], "id" => File.basename(path, ".json")
      )
    end

    # Always truncate individual UTF-8 strings before serializing. Truncating
    # the generated JSON would produce an invalid document in the next prompt.
    def fit_handoff_json(handoff, bytes)
      compact = bounded_handoff(handoff)
      serialized = -> { JSON.generate(compact) }
      fields = %w[promotion_candidates lessons references decisions open_items outstanding_child_agents]
      while serialized.call.bytesize > bytes
        field = fields.find { |name| compact[name].is_a?(Array) && !compact[name].empty? }
        if field
          compact[field].pop
        elsif compact["summary"].bytesize > 400
          compact["summary"] = truncate(compact["summary"], compact["summary"].bytesize - 200)
        else
          break
        end
      end
      compact
    end

    def bounded_hash(value, bytes)
      text = JSON.generate(value)
      return value if text.bytesize <= bytes

      { "summary" => truncate(value["summary"] || value["error"] || "", bytes - 80), "truncated" => true }
    rescue StandardError
      { "truncated" => true }
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
