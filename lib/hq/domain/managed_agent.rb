# frozen_string_literal: true

require_relative "constants"
require_relative "log_paths"
require_relative "attachment_normalizer"
require_relative "queue_work"
require_relative "agent_command_builder"
require_relative "harness_execution"
require_relative "agent_memory"
require_relative "agent_stream_projector"
require_relative "agent_result_normalizer"
require_relative "memory_handoff"
require_relative "agent_structured_result"
require_relative "agent_correction_runner"
require_relative "agent_system_context"
require_relative "response_style_policy"
require_relative "skill_installer"
require_relative "executable_resolver"
require_relative "../harness_registry"
require_relative "../log_file_reader"
require_relative "../parser"
require_relative "agent_chat_log"
require_relative "process_liveness"
require_relative "agent_cost_snapshot"
require_relative "file_store"
require_relative "usage_metrics"
require_relative "context_pressure"
require_relative "project_workspace"
require "digest"
require "securerandom"
require "shellwords"
require "rbconfig"

module HQ
  class ManagedAgent
    FALLBACK_SUMMARY_CONTEXT_MAX_CHARS = 800
    FALLBACK_SUMMARY_CONTEXT_MAX_LINES = 12
    AgentMessage = Struct.new(:role, :content, :created_at, :streaming, :kind, :tool_name, :tool_use_id, :metadata,
                              keyword_init: true) do
      def self.from_hash(hash)
        new(
          role: hash["role"],
          content: hash["content"].to_s,
          created_at: ManagedAgent.parse_time(hash["created_at"]),
          streaming: false,
          kind: hash["kind"].to_s.empty? ? "text" : hash["kind"].to_s,
          tool_name: hash["tool_name"],
          tool_use_id: hash["tool_use_id"],
          metadata: hash["metadata"].is_a?(Hash) ? hash["metadata"] : nil
        )
      end

      def to_hash
        result = {
          "role" => role,
          "content" => content,
          "created_at" => created_at&.iso8601
        }
        result["kind"] = kind unless kind.to_s.empty? || kind == "text"
        result["tool_name"] = tool_name unless tool_name.to_s.empty?
        result["tool_use_id"] = tool_use_id unless tool_use_id.to_s.empty?
        result["metadata"] = metadata if metadata.is_a?(Hash) && !metadata.empty?
        result
      end
    end

    AgentRun = Struct.new(
      :started_at, :finished_at, :exit_code, :status, :log_path, :command, :session_id, :response_style_source,
      :agent, :model, :log_start_offset, :run_id, :run_scoped_status, :delegation_owner, :delegation_generation,
      :metadata,
      keyword_init: true
    ) do
      def self.from_hash(hash)
        command = hash["command"]
        log_start_offset = hash["log_start_offset"]
        log_start_offset = nil unless log_start_offset.is_a?(Integer) && log_start_offset >= 0
        new(
          started_at: ManagedAgent.parse_time(hash["started_at"]),
          finished_at: ManagedAgent.parse_time(hash["finished_at"]),
          exit_code: hash["exit_code"],
          status: hash["status"],
          log_path: hash["log_path"],
          command: command,
          session_id: hash["session_id"],
          response_style_source: hash["response_style_source"],
          agent: hash["agent"],
          model: hash["model"],
          log_start_offset: log_start_offset,
          run_id: hash["run_id"],
          run_scoped_status: hash["run_scoped_status"] == true,
          delegation_owner: hash["delegation_owner"],
          delegation_generation: hash["delegation_generation"],
          metadata: hash["metadata"].is_a?(Hash) ? hash["metadata"] : {}
        )
      end

      def to_hash
        result = {
          "started_at" => started_at&.iso8601,
          "finished_at" => finished_at&.iso8601,
          "exit_code" => exit_code,
          "status" => status,
          "log_path" => log_path,
          "command" => command
        }
        result["session_id"] = session_id unless session_id.to_s.empty?
        result["response_style_source"] = response_style_source unless response_style_source.to_s.empty?
        result["agent"] = agent unless agent.to_s.empty?
        result["model"] = model unless model.to_s.empty?
        result["log_start_offset"] = log_start_offset if log_start_offset.is_a?(Integer) && log_start_offset >= 0
        result["run_id"] = run_id unless run_id.to_s.empty?
        result["run_scoped_status"] = true if run_scoped_status
        result["delegation_owner"] = delegation_owner unless delegation_owner.to_s.empty?
        result["delegation_generation"] = delegation_generation if delegation_generation.is_a?(Integer)
        result["metadata"] = metadata if metadata.is_a?(Hash) && !metadata.empty?
        result
      end
    end

    NO_ACTION_STATUS_GUIDANCE = "Choose `status: no_action_needed` only for a successful observational or " \
                                "recurring check where no new condition required action and you did not complete " \
                                "a requested change, answer, commit, review, or deliverable. Use `status: success` " \
                                "when you completed any requested action or produced the requested result, even " \
                                "if nothing remains to do afterward. `no_action_needed` is a quiet outcome that " \
                                "suppresses operator unread and push notifications, so do not use it as a synonym " \
                                "for \"finished\" or \"no next steps.\""
    SUMMARY_SECTIONS_EXAMPLE = '{"type":"text","text":"## Findings\\n- First\\n- Second","url":null,"attachment":null}'
    SUMMARY_SECTIONS_GUIDANCE = "Always provide a non-empty `summary` as the concise preview. " \
                                "Set `summary_sections` to `null` for simple runs. For substantive runs such as " \
                                "investigations, reviews, builds, or plans with multiple findings, decisions, or " \
                                "verification results, provide ordered rich blocks as a standalone expanded " \
                                "account. Put headings, bullets, numbered lists, tables, and prose in Markdown " \
                                "`text` blocks; use `link` and `attachment` blocks for their respective targets. " \
                                "Set every unused block field to `null`. Example Markdown list block: " \
                                "`#{SUMMARY_SECTIONS_EXAMPLE}`"
    FINAL_OUTPUT_CHECKLIST = "For `summary`, write a concise operator-facing Markdown summary of the outcome, " \
                             "key changes or findings, blockers, and next steps in 1-3 short paragraphs or bullets. " \
                             "#{SUMMARY_SECTIONS_GUIDANCE} " \
                             "#{NO_ACTION_STATUS_GUIDANCE} " \
                             "Before final structured output, check whether this run created or referenced a PR, " \
                             "plan, review, report, markdown file, image, or other durable artifact. " \
                             "If yes, include it in `attachments`: use `type: file` with `path` for local files, " \
                             "or `type: link` with an http(s) `url` for web links."
    LEGACY_SCHEDULED_NAME_PREFIX = "[Scheduled]"
    DIRECT_OUTPUT_IDLE_TIMEOUT_SECONDS = 5 * 60
    PROCESS_OUTPUT_MARKER = "=== process output ==="
    ARCHIVE_ABORT_MESSAGE = "Run aborted since agent already archived"
    STRUCTURED_OUTPUT_CORRECTION_LIMIT = 2
    MAX_STRUCTURED_OUTPUT_CORRECTION_LIMIT = 5
    UNPROCESSED_QUEUE_WORK_STATUSES = %w[failed blocked input_required].freeze

    def self.with_final_output_checklist(prompt)
      text = prompt.to_s.rstrip
      return FINAL_OUTPUT_CHECKLIST if text.empty?
      return text if text.include?(FINAL_OUTPUT_CHECKLIST)

      "#{text}\n\n#{FINAL_OUTPUT_CHECKLIST}"
    end

    attr_reader :key, :name, :project_key, :template_key, :workspace, :prompt, :created_at, :role, :started_at,
                :finished_at, :pid, :last_exit_code, :log_path, :runs, :sandbox_mode, :agent, :messages, :skills,
                :model, :reasoning_effort, :response_style, :session_id, :session_bootstrapped, :color_index, :summary,
                :structured_result, :schedule_key, :cost_snapshot, :project_group, :delegation_parent, :archive_path,
                :archived_at, :project_hidden_at_archive, :prompt_queue, :prompt_queue_claim, :queue_work,
                :prompt_queue_dispatch_error
    attr_reader :context_pressure_acknowledged_signal, :context_pressure_dismissed
    attr_writer :summary, :structured_result, :cost_snapshot

    def usage_metrics_store=(store)
      @usage_metrics_store = store
    end

    def initialize(key:, name:, project_key:, template_key:, workspace:, prompt:, created_at: nil, started_at: nil,
                   finished_at: nil, pid: nil, last_exit_code: nil, log_path: nil, runs: nil,
                   stop_requested_at: nil, sandbox_mode: "danger-full-access", agent: "codex", messages: nil,
                   model: nil, reasoning_effort: nil, response_style: nil, skills: nil, unread: false, session_id: nil,
                   session_bootstrapped: nil, color_index: nil, summary: nil, structured_result: nil, schedule_key: nil,
                   cost_snapshot: nil, total_run_count: nil, project_group: nil, delegation_parent: nil,
                   archived: false, archive_path: nil, archived_at: nil, project_hidden_at_archive: nil,
                   prompt_queue: nil, prompt_queue_claim: nil, prompt_queue_dispatch_error: nil, queue_work: nil, role: nil,
                   context_pressure_acknowledged_signal: nil, context_pressure_dismissed: false)
      @key = key
      @name = name
      @project_key = project_key
      @role = role.to_s.strip.empty? ? nil : role.to_s
      @project_group = project_group.to_s
      @template_key = template_key
      @workspace = workspace
      @prompt = prompt
      @created_at = created_at || Time.now
      @started_at = started_at
      @finished_at = finished_at
      @pid = pid
      @last_exit_code = last_exit_code
      @log_path = log_path || LogPaths.agent_raw_log_path(@project_key, created_at: @created_at)
      @runs = Array(runs)
      @stop_requested_at = stop_requested_at
      @sandbox_mode = normalize_sandbox_mode(sandbox_mode)
      @agent = normalize_agent(agent)
      @model = normalize_model(model)
      @reasoning_effort = normalize_reasoning_effort(reasoning_effort)
      @response_style = normalize_response_style(response_style)
      @messages = normalize_messages(messages)
      seed_memory_from_initial_messages!(messages)
      @skills = normalize_skills(skills)
      @unread = unread ? true : false
      @session_id = normalize_session_id(session_id)
      @session_bootstrapped = !@session_id.empty? && session_bootstrapped != false
      @color_index = color_index.is_a?(Integer) ? color_index : nil
      @structured_result = structured_result.is_a?(Hash) ? structured_result : nil
      @summary = summary.is_a?(String) && !summary.empty? ? summary : nil
      @schedule_key = normalize_schedule_key(schedule_key)
      @cost_snapshot = AgentCostSnapshot.normalize(cost_snapshot)
      @total_run_count = infer_total_run_count(total_run_count)
      @delegation_parent = normalize_delegation_parent(delegation_parent)
      @archived = archived == true
      @archive_path = archive_path.to_s.empty? ? nil : archive_path.to_s
      @archived_at = archived_at
      @project_hidden_at_archive = project_hidden_at_archive unless project_hidden_at_archive.nil?
      @prompt_queue = normalize_prompt_queue(prompt_queue)
      @prompt_queue_claim = normalize_prompt_queue_claim(prompt_queue_claim)
      @queue_work = QueueWork.normalize(
        queue_work,
        legacy_claim: @prompt_queue_claim,
        entry_normalizer: method(:normalize_prompt_queue_entry)
      )
      @prompt_queue_dispatch_error = normalize_prompt_queue_dispatch_error(prompt_queue_dispatch_error)
      reconcile_prompt_queue_claim!
      @context_pressure_acknowledged_signal = context_pressure_acknowledged_signal.to_s
      @context_pressure_dismissed = context_pressure_dismissed == true
    end

    def color_index=(value)
      @color_index = value.is_a?(Integer) ? value : nil
    end

    def skills=(value)
      @skills = normalize_skills(value)
    end

    def ensure_project_context_prompt!(content, created_at: @created_at || Time.now)
      text = content.to_s
      return false if text.empty?
      return false if @messages.any? { |message| message.role == "system" && message.content.to_s == text }

      @messages.unshift(AgentMessage.new(role: "system", content: text, created_at:))
      trim_messages!
      memory_store.prepend_system_prompt_once!(text, created_at:, prompt_role: "project_context")
      true
    end

    def ensure_agent_system_context_prompt!(created_at: @created_at || Time.now)
      memory_store.insert_system_prompt_once!(
        current_agent_system_context,
        created_at:,
        prompt_role: "agent_context",
        before_prompt_role: "base"
      )
    end

    def ensure_schedule_context_prompt!(content, created_at: Time.now)
      text = content.to_s.strip
      return false if text.empty?
      return false if @messages.any? { |message| message.role == "system" && message.content.to_s == text }

      @messages << AgentMessage.new(role: "system", content: text, created_at:)
      trim_messages!
      memory_store.append_system_prompt!(text, created_at:, prompt_role: "schedule")
      true
    end

    def self.from_hash(hash)
      runs = Array(hash["runs"]).map { |run| AgentRun.from_hash(run) }
      runs.each do |run|
        next unless run.run_id.to_s.empty?

        components = [hash["key"], run.started_at&.utc&.iso8601(6), run.log_start_offset].map(&:to_s)
        run.run_id = Digest::SHA256.hexdigest("usage-run-v1\0#{components.join("\0")}")
      end
      launch_settings = launch_settings_from_runs(runs)
      model = hash["model"].to_s.strip.empty? ? launch_settings[:model] : hash["model"]
      reasoning_effort = if hash["reasoning_effort"].to_s.strip.empty?
                           launch_settings[:reasoning_effort]
                         else
                           hash["reasoning_effort"]
                         end
      session_id = hash["session_id"].to_s.strip
      recovered_session_run = runs.reverse_each.find { |run| !run.session_id.to_s.strip.empty? } if session_id.empty?
      session_id = recovered_session_run&.session_id if session_id.empty?
      session_bootstrapped = if hash.key?("session_bootstrapped")
                               hash["session_bootstrapped"]
                             elsif session_id && HQ.harness_adapter(hash["agent"]) == "claude"
                               recovered_session_run&.status != "running"
                             end
      new(
        key: hash["key"],
        name: hash["name"],
        project_key: hash["project_key"],
        template_key: hash["template_key"] || "default",
        workspace: hash["workspace"],
        prompt: hash["prompt"],
        created_at: parse_time(hash["created_at"]),
        started_at: parse_time(hash["started_at"]),
        finished_at: parse_time(hash["finished_at"]),
        pid: hash["pid"],
        last_exit_code: hash["last_exit_code"],
        log_path: hash["log_path"] || LogPaths.legacy_agent_raw_log_path(hash["key"]),
        runs: runs,
        stop_requested_at: parse_time(hash["stop_requested_at"]),
        sandbox_mode: hash["sandbox_mode"],
        agent: hash["agent"],
        model: model,
        reasoning_effort: reasoning_effort,
        response_style: hash.key?("response_style") ? hash["response_style"] : nil,
        skills: hash["skills"],
        unread: hash["unread"],
        session_id: session_id,
        session_bootstrapped: session_bootstrapped,
        color_index: hash["color_index"],
        summary: hash["summary"],
        structured_result: hash["structured_result"],
        schedule_key: hash["schedule_key"],
        cost_snapshot: hash["cost_snapshot"],
        total_run_count: hash["total_run_count"],
        project_group: hash["project_group"],
        delegation_parent: hash["delegation_parent"],
        archived: hash["archived"],
        archive_path: hash["archive_path"],
        archived_at: parse_time(hash["archived_at"]),
        project_hidden_at_archive: hash["project_hidden_at_archive"],
        prompt_queue: hash["prompt_queue"],
        prompt_queue_claim: hash["prompt_queue_claim"],
        prompt_queue_dispatch_error: hash["prompt_queue_dispatch_error"],
        queue_work: hash["queue_work"],
        role: hash["role"],
        context_pressure_acknowledged_signal: hash["context_pressure_acknowledged_signal"],
        context_pressure_dismissed: hash["context_pressure_dismissed"]
      )
    end

    def self.launch_settings_from_runs(runs)
      settings = {}
      runs.reverse_each do |run|
        parts = split_command(run.command)
        next if parts.empty?

        settings[:model] ||= model_from_command(parts)
        settings[:reasoning_effort] ||= reasoning_effort_from_command(parts)
        break if settings[:model] && settings[:reasoning_effort]
      end
      settings
    end

    def self.split_command(command)
      Shellwords.split(command.to_s)
    rescue ArgumentError
      []
    end

    def self.model_from_command(parts)
      command_option_parts(parts).each_with_index do |part, index|
        return nonempty_argument(parts[index + 1]) if part == "--model" || part == "-m"
        return nonempty_argument(part.split("=", 2).last) if part.start_with?("--model=")
      end
      nil
    end

    def self.reasoning_effort_from_command(parts)
      command_option_parts(parts).each_with_index do |part, index|
        return nonempty_argument(parts[index + 1]) if part == "--effort"
        return nonempty_argument(part.split("=", 2).last) if part.start_with?("--effort=")

        if part == "-c" || part == "--config"
          effort = reasoning_effort_from_config(parts[index + 1])
          return effort if effort
        elsif part.start_with?("--config=")
          effort = reasoning_effort_from_config(part.split("=", 2).last)
          return effort if effort
        end
      end
      nil
    end

    def self.command_option_parts(parts)
      separator = parts.index("--")
      separator ? parts[0...separator] : parts
    end

    def self.reasoning_effort_from_config(value)
      text = value.to_s.strip
      return nil unless text.start_with?("model_reasoning_effort")

      raw_value = text.split("=", 2).last
      return nil if raw_value == text

      nonempty_argument(unquote_argument(raw_value))
    end

    def self.unquote_argument(value)
      text = value.to_s.strip
      if (text.start_with?("\"") && text.end_with?("\"")) ||
         (text.start_with?("'") && text.end_with?("'"))
        return text[1...-1]
      end

      text
    end

    def self.nonempty_argument(value)
      text = value.to_s.strip
      text.empty? ? nil : text
    end

    def self.display_name_for(name, scheduled: false)
      text = name.to_s
      return text unless scheduled

      stripped = text.sub(/\A#{Regexp.escape(LEGACY_SCHEDULED_NAME_PREFIX)}\s*/, "")
      stripped.empty? ? text : stripped
    end

    private_class_method :launch_settings_from_runs, :split_command, :model_from_command,
                         :reasoning_effort_from_command, :command_option_parts,
                         :reasoning_effort_from_config, :unquote_argument,
                         :nonempty_argument

    def to_hash
      result = {
        "key" => @key,
        "name" => @name,
        "project_key" => @project_key,
        "template_key" => @template_key,
        "workspace" => @workspace,
        "prompt" => @prompt,
        "created_at" => @created_at&.iso8601,
        "started_at" => @started_at&.iso8601,
        "finished_at" => @finished_at&.iso8601,
        "pid" => @pid,
        "last_exit_code" => @last_exit_code,
        "log_path" => @log_path,
        "runs" => @runs.map(&:to_hash),
        "total_run_count" => run_count,
        "stop_requested_at" => @stop_requested_at&.iso8601,
        "sandbox_mode" => @sandbox_mode,
        "agent" => @agent,
        "skills" => @skills,
        "unread" => @unread
      }
      result["model"] = @model unless @model.to_s.empty?
      result["reasoning_effort"] = @reasoning_effort unless @reasoning_effort.to_s.empty?
      result["response_style"] = @response_style unless @response_style.nil?
      unless @session_id.to_s.empty?
        result["session_id"] = @session_id
        result["session_bootstrapped"] = @session_bootstrapped
      end
      result["color_index"] = @color_index unless @color_index.nil?
      result["summary"] = @summary unless @summary.to_s.empty?
      result["structured_result"] = @structured_result if @structured_result.is_a?(Hash) && !@structured_result.empty?
      result["schedule_key"] = @schedule_key unless @schedule_key.to_s.empty?
      result["cost_snapshot"] = @cost_snapshot if @cost_snapshot.is_a?(Hash) && !@cost_snapshot.empty?
      result["project_group"] = @project_group unless @project_group.empty?
      result["role"] = @role unless @role.to_s.empty?
      result["delegation_parent"] = @delegation_parent if @delegation_parent
      result["archived"] = true if archived?
      result["archive_path"] = @archive_path if archived? && @archive_path
      result["archived_at"] = @archived_at&.iso8601 if archived? && @archived_at
      result["project_hidden_at_archive"] = @project_hidden_at_archive unless @project_hidden_at_archive.nil?
      result["prompt_queue"] = @prompt_queue unless @prompt_queue.empty?
      result["prompt_queue_claim"] = @prompt_queue_claim if @prompt_queue_claim
      result["prompt_queue_dispatch_error"] = @prompt_queue_dispatch_error if @prompt_queue_dispatch_error
      result["queue_work"] = @queue_work if Array(@queue_work["batches"]).any?
      unless @context_pressure_acknowledged_signal.empty?
        result["context_pressure_acknowledged_signal"] = @context_pressure_acknowledged_signal
      end
      result["context_pressure_dismissed"] = true if @context_pressure_dismissed
      result
    end

    def context_pressure
      stat = File.stat(raw_log_path) if File.file?(raw_log_path)
      cache_key = [stat&.size, stat&.mtime&.to_f, @context_pressure_acknowledged_signal]
      return @context_pressure_cache if @context_pressure_cache_key == cache_key && @context_pressure_cache

      @context_pressure_cache_key = cache_key
      @context_pressure_cache = ContextPressure.new(self).snapshot
    end

    def acknowledge_context_pressure!(signal_id)
      current = context_pressure
      expected = current["signal_id"].to_s
      raise ArgumentError, "Context pressure signal has changed; refresh and try again" if expected.empty? || signal_id.to_s != expected

      @context_pressure_acknowledged_signal = expected
      @context_pressure_cache_key = nil
      context_pressure
    end

    def dismiss_context_pressure!
      @context_pressure_dismissed = true
      @context_pressure_cache_key = nil
      context_pressure
    end

    def enqueue_prompt!(prompt:, attachments: nil, accepted_at: Time.now, not_before: nil, id: SecureRandom.uuid,
                        client_request_id: nil, authority: nil, message_metadata: nil, source: nil)
      entry = {
        "id" => id.to_s,
        "prompt" => prompt.to_s.strip,
        "attachments" => normalize_attachments(attachments) || [],
        "accepted_at" => accepted_at.utc.iso8601(6)
      }
      entry["not_before"] = not_before.utc.iso8601(6) if not_before
      request_id = client_request_id.to_s.strip
      entry["client_request_id"] = request_id unless request_id.empty?
      entry["authority"] = normalize_prompt_queue_authority(authority) if authority
      entry["message_metadata"] = message_metadata if message_metadata.is_a?(Hash) && !message_metadata.empty?
      entry["source"] = source.to_s unless source.to_s.empty?
      raise ArgumentError, "Queued prompt is required" if entry["prompt"].empty?

      @prompt_queue << entry
      entry
    end

    def edit_queued_prompt!(id, prompt:, updated_at: Time.now)
      entry = @prompt_queue.find { |candidate| candidate["id"] == id.to_s }
      raise ArgumentError, "Unknown queued prompt: #{id}" unless entry
      raise ArgumentError, "Delegated replies cannot be edited" if entry["source"] == "delegation_callback"

      text = prompt.to_s.strip
      raise ArgumentError, "Queued prompt is required" if text.empty?

      entry["prompt"] = text
      entry["updated_at"] = updated_at.utc.iso8601(6)
      entry
    end

    def delete_queued_prompt!(id)
      index = @prompt_queue.index { |candidate| candidate["id"] == id.to_s }
      raise ArgumentError, "Unknown queued prompt: #{id}" unless index
      raise ArgumentError, "Delegated replies cannot be deleted" if @prompt_queue[index]["source"] == "delegation_callback"

      @prompt_queue.delete_at(index)
    end

    def claim_pending_prompts!(claimed_at: Time.now)
      return @prompt_queue_claim if @prompt_queue_claim
      batch = active_queue_work
      resuming_batch = batch && batch.fetch("delivery_count", 0).to_i.positive?
      if batch
        return nil unless batch["resume_pending"] == true

        QueueWork.consume_resume_request!(batch)
      else
        return nil unless prompt_queue_due?(claimed_at)

        batch = open_queue_work_batch!(opened_at: claimed_at)
      end
      delivery_ids = QueueWork.consume_manual_entry_ids!(batch)
      entries = Array(batch["entries"]).select { |entry| delivery_ids.include?(entry["id"].to_s) }
      @prompt_queue_claim = {
        "id" => batch["id"],
        "entries" => entries,
        "claimed_at" => claimed_at.utc.iso8601(6),
        "baseline_run_count" => run_count,
        "message_appended" => resuming_batch
      }
      @prompt_queue_dispatch_error = nil
      @prompt_queue_claim
    end

    def prepare_prompt_queue_claim!
      claim = @prompt_queue_claim
      return false unless claim
      return false if claim["message_appended"]

      entries = Array(claim["entries"])
      newest_entry = entries.last || {}
      batch = QueueWork.find(@queue_work, claim["id"])
      prompt = batch ? QueueWork.contract(batch, agent_key: @key, entry_ids: entries.map { |entry| entry["id"] }) :
        consolidated_prompt_queue_content(entries)
      attachments = consolidated_prompt_queue_attachments(entries)
      metadata = newest_entry["message_metadata"].is_a?(Hash) ? newest_entry["message_metadata"].dup : {}
      metadata.merge!(consolidated_prompt_queue_metadata(entries))
      metadata["prompt_queue_claim_id"] = claim["id"]
      metadata["queue_work_batch_id"] = batch["id"] if batch
      recovery_metadata = circuit_breaker_recovery_metadata(entries, claim:, batch:)
      metadata["circuit_breaker_recovery"] = recovery_metadata if recovery_metadata
      if batch
        record_queue_read!(batch, created_at: self.class.parse_time(claim["claimed_at"]) || Time.now, metadata:)
      else
        add_user_message!(prompt, attachments:, metadata:)
      end
      claim["message_appended"] = true
      true
    end

    def consume_prompt_queue_for_read!
      raise ArgumentError, "Queued work is already claimed for dispatch" if @prompt_queue_claim
      batch = active_queue_work || open_queue_work_batch!
      raise ArgumentError, "No pending queue entries" unless batch

      @prompt_queue_dispatch_error = nil
      Array(batch["entries"])
    end

    def active_queue_work
      QueueWork.active(@queue_work)
    end

    def queue_work_batch(batch_id = nil)
      return QueueWork.find(@queue_work, batch_id) unless batch_id.to_s.empty?

      active_queue_work || Array(@queue_work["batches"]).last
    end

    def queue_work_payload(batch_id = nil)
      batch = queue_work_batch(batch_id)
      QueueWork.payload(batch) if batch
    end

    def open_queue_work_batch!(opened_at: Time.now)
      return active_queue_work if active_queue_work
      eligible, future = @prompt_queue.partition { |entry| prompt_entry_due?(entry, opened_at) }
      return nil if eligible.empty?

      entries = eligible
      @prompt_queue = future
      batch = QueueWork.build_batch(entries, opened_at:)
      @queue_work["batches"] << batch
      @queue_work["active_batch_id"] = batch["id"]
      batch
    end

    def mark_queue_work_read!(batch, read_id:)
      QueueWork.mark_delivered!(batch, read_id:)
    end

    def record_queue_read!(batch, created_at: Time.now, metadata: nil)
      entries = Array(batch["entries"])
      read_id = batch["read_id"].to_s
      first_read = read_id.empty?
      read_id = "queue-read:#{SecureRandom.uuid}" if first_read
      mark_queue_work_read!(batch, read_id:)

      content = QueueWork.contract(batch, agent_key: @key)
      attachments = consolidated_prompt_queue_attachments(entries)
      read_entries = consolidated_prompt_queue_entries(entries, state: batch["state"])
      event_metadata = metadata.is_a?(Hash) ? metadata.dup : {}
      event_metadata.merge!(consolidated_prompt_queue_metadata(entries)).merge!(
        "queue_read" => true,
        "read_label" => "Read queue",
        "prompt_queue_entries" => read_entries,
        "queue_work_batch_id" => batch["id"],
        "queue_work_state" => batch["state"],
        "queue_work_projection" => QueueWork.projection(batch)
      )
      if first_read
        AgentMemory.new(self).append_queue_read!(
          content,
          read_id:,
          created_at:,
          attachments:,
          metadata: event_metadata
        )
      end
      {
        entries:,
        read_entries:,
        content:,
        attachments:,
        read_id:,
        batch: QueueWork.payload(batch),
        idempotent: !first_read
      }
    end

    def include_pending_queue_work_with_user_input!(claimed_at: Time.now)
      batch = active_queue_work || open_queue_work_batch!(opened_at: claimed_at)
      return nil unless batch

      QueueWork.consume_resume_request!(batch) if batch["resume_pending"] == true
      result = record_queue_read!(batch, created_at: claimed_at)
      @prompt_queue_claim = nil
      @prompt_queue_dispatch_error = nil
      result
    end

    def complete_queue_work!(batch_id, dispositions, completed_at: Time.now)
      batch = QueueWork.find(@queue_work, batch_id)
      raise ArgumentError, "Unknown queue-work batch: #{batch_id}" unless batch

      result = QueueWork.apply_dispositions!(batch, dispositions, completed_at:)
      @queue_work.delete("active_batch_id") if QueueWork.terminal?(batch)
      reconcile_prompt_queue_claim!
      result
    end

    def prepare_queue_entries_for_processing!(entry_ids)
      ids = validate_queue_entry_ids!(entry_ids)
      batch = active_queue_work

      selected_queued = @prompt_queue.select { |entry| ids.include?(entry["id"].to_s) }
      @prompt_queue.reject! { |entry| ids.include?(entry["id"].to_s) }
      if batch
        batch["entries"].concat(selected_queued)
      else
        batch = QueueWork.build_batch(selected_queued)
        @queue_work["batches"] << batch
        @queue_work["active_batch_id"] = batch["id"]
      end
      QueueWork.request_manual_delivery!(batch, ids)
      ids
    end

    def validate_queue_entry_ids!(entry_ids)
      ids = Array(entry_ids).map(&:to_s).uniq
      raise ArgumentError, "Select at least one queue entry" if ids.empty?

      batch = active_queue_work
      unresolved = batch ? QueueWork.unresolved_ids(batch) : []
      queued_by_id = @prompt_queue.to_h { |entry| [entry["id"].to_s, entry] }
      unknown = ids.reject { |id| unresolved.include?(id) || queued_by_id.key?(id) }
      raise ArgumentError, "Queue changed; refresh and try again (missing: #{unknown.join(', ')})" unless unknown.empty?

      ids
    end

    def remove_queue_entries!(entry_ids, reason:, removed_at: Time.now)
      ids = validate_queue_entry_ids!(entry_ids)
      batch = active_queue_work
      unresolved = batch ? QueueWork.unresolved_ids(batch) : []
      selected_queued = @prompt_queue.select { |entry| ids.include?(entry["id"].to_s) }
      @prompt_queue.reject! { |entry| ids.include?(entry["id"].to_s) }
      removal_reason = reason.to_s.strip
      removal_reason = "Removed from the queue by an operator" if removal_reason.empty?
      results = []
      [[batch, ids.select { |id| unresolved.include?(id) }],
       [selected_queued.empty? ? nil : QueueWork.build_batch(selected_queued), selected_queued.map { |entry| entry["id"] }]].each do |target_batch, selected_ids|
        next unless target_batch && selected_ids.any?

        @queue_work["batches"] << target_batch unless target_batch.equal?(batch)
        dispositions = Array(target_batch["entries"]).filter_map do |entry|
          next unless selected_ids.include?(entry["id"].to_s)

          outcome = QueueWork.entry_kind(entry) == "delegated_report" ? "superseded_with_reason" : "declined_with_reason"
          { "entry_id" => entry["id"].to_s, "outcome" => outcome, "reason" => removal_reason }
        end
        results << QueueWork.apply_dispositions!(target_batch, dispositions, completed_at: removed_at)
      end
      if batch && QueueWork.terminal?(batch)
        @queue_work.delete("active_batch_id")
        reconcile_prompt_queue_claim!
      end
      { "removed_entry_ids" => ids, "results" => results }
    end

    def discard_failed_prompt_queue!(reason: "Discarded by operator after failed dispatch", discarded_at: Time.now)
      raise ArgumentError, "No queued dispatch is waiting to be discarded" unless @prompt_queue_dispatch_error

      claim = @prompt_queue_claim
      batch = claim && QueueWork.find(@queue_work, claim["id"])
      raise ArgumentError, "No failed claimed batch is available to discard" unless batch
      if Array(batch["entries"]).any? { |entry| entry["source"] == "delegation_callback" }
        raise ArgumentError, "Delegated replies cannot be discarded; retry the queue instead"
      end

      dispositions = Array(batch["entries"]).map do |entry|
        {
          "entry_id" => entry.fetch("id"),
          "outcome" => "declined_with_reason",
          "reason" => reason.to_s.strip.empty? ? "Discarded by operator after failed dispatch" : reason.to_s.strip
        }
      end
      result = complete_queue_work!(batch.fetch("id"), dispositions, completed_at: discarded_at)
      result["discarded"] = true
      result
    end

    def reconcile_prompt_queue_claim!
      claim = @prompt_queue_claim
      return false unless claim

      batch = QueueWork.find(@queue_work, claim["id"])
      return false unless QueueWork.terminal?(batch)

      complete_prompt_queue_claim!
      true
    end

    def consolidated_prompt_queue_content(entries)
      Array(entries).map { |entry| entry["prompt"].to_s.strip }.reject(&:empty?).join("\n\n---\n\n")
    end

    def consolidated_prompt_queue_attachments(entries)
      normalize_attachments(Array(entries).flat_map { |entry| Array(entry["attachments"]) }) || []
    end

    def consolidated_prompt_queue_entries(entries, state: "read")
      Array(entries).map do |entry|
        {
          "id" => entry["id"].to_s,
          "prompt" => entry["prompt"].to_s,
          "attachments" => normalize_attachments(entry["attachments"]) || [],
          "accepted_at" => entry["accepted_at"],
          "not_before" => entry["not_before"],
          "source" => entry["source"].to_s.empty? ? "user" : entry["source"].to_s,
          "kind" => QueueWork.entry_kind(entry),
          "authority" => entry["authority"]&.slice("owner", "generation"),
          "state" => state
        }.compact
      end
    end

    def consolidated_prompt_queue_metadata(entries)
      entries = Array(entries)
      sources = entries.map { |entry| entry["source"].to_s.empty? ? "user" : entry["source"].to_s }
      {
        "prompt_queue_batch" => true,
        "prompt_queue_entry_ids" => entries.map { |entry| entry["id"].to_s },
        "prompt_queue_entry_count" => entries.length,
        "prompt_queue_sources" => sources.tally
      }
    end

    def complete_prompt_queue_claim!
      @prompt_queue_claim = nil
      @prompt_queue_dispatch_error = nil
    end

    def mark_last_run_prompt_queue_claim!(claim_id)
      return false unless last_run

      last_run.metadata = {} unless last_run.metadata.is_a?(Hash)
      last_run.metadata["prompt_queue_claim_id"] = claim_id.to_s
      true
    end

    def last_run_from_prompt_queue?
      !last_run&.metadata&.fetch("prompt_queue_claim_id", nil).to_s.empty?
    end

    def dispatched_prompt_queue_claim
      claim = @prompt_queue_claim
      return nil unless claim
      return nil unless last_run&.metadata&.fetch("prompt_queue_claim_id", nil).to_s == claim["id"].to_s
      return nil unless run_count > claim["baseline_run_count"].to_i
      return nil if last_run.metadata&.fetch("start_failure", false)

      claim
    end

    def fail_prompt_queue_dispatch!(message, failed_at: Time.now)
      @prompt_queue_dispatch_error = {
        "message" => message.to_s.strip,
        "failed_at" => failed_at.utc.iso8601(6),
        "retryable" => true
      }
    end

    def clear_prompt_queue_dispatch_error!
      @prompt_queue_dispatch_error = nil
    end

    def queued_prompts
      batch = active_queue_work
      claimed = Array(batch&.fetch("entries", nil)).map do |entry|
        state = @prompt_queue_dispatch_error ? "failed" : batch.fetch("state", "in_progress")
        entry.merge("state" => state, "queue_work_batch_id" => batch["id"])
      end
      claimed + @prompt_queue.map { |entry| entry.merge("state" => "queued") }
    end

    def visible_prompt_queue_entries
      entries = @prompt_queue.map { |entry| entry.merge("state" => "queued") }
      batch = active_queue_work
      return entries unless batch
      unresolved = QueueWork.unresolved_ids(batch)
      batch_entries = Array(batch["entries"]).select { |entry| unresolved.include?(entry["id"].to_s) }
      if running? && @prompt_queue_dispatch_error.nil?
        claimed_ids = if @prompt_queue_claim
                        Array(@prompt_queue_claim["entries"]).map { |entry| entry["id"].to_s }
                      else
                        batch_entries.map { |entry| entry["id"].to_s }
                      end
        visible = batch_entries.reject { |entry| claimed_ids.include?(entry["id"].to_s) }
                               .map { |entry| entry.merge("state" => "queued", "queue_work_batch_id" => batch["id"]) } + entries
        return visible.each_with_index.sort_by { |(entry, index)| [entry["accepted_at"].to_s, index] }.map(&:first)
      end

      state = if @prompt_queue_dispatch_error
                "failed"
              else
                queue_work_unprocessed_status || batch.fetch("state", "in_progress")
              end
      visible = batch_entries.map do |entry|
        entry.merge("state" => state, "queue_work_batch_id" => batch["id"])
      end + entries
      visible.each_with_index.sort_by { |(entry, index)| [entry["accepted_at"].to_s, index] }.map(&:first)
    end

    def queue_work_unprocessed_status
      return nil unless active_queue_work
      return nil if running?

      result_status = effective_status.to_s
      return nil unless UNPROCESSED_QUEUE_WORK_STATUSES.include?(result_status)

      run_status = last_run&.status.to_s
      return result_status if result_status == "input_required" && %w[input_required awaiting-input].include?(run_status)
      return result_status if run_status == result_status

      nil
    end

    def queue_work_unprocessed_reason
      result_status = queue_work_unprocessed_status
      "queue not processed since state is #{result_status}" if result_status
    end

    def prompt_queue_stopped_reason
      return nil if visible_prompt_queue_entries.empty? || running? || prompt_queue_dispatchable?

      "Automatic queue processing stopped because agent state is #{effective_status}"
    end

    def prompt_queue_dispatchable?
      has_run_context = last_run || next_prompt_queue_entry&.fetch("source", nil) == "delegation_callback"
      !archived? && !running? && !blocked? && !inquiry_blocking_prompt_queue? &&
        (!UNPROCESSED_QUEUE_WORK_STATUSES.include?(effective_status.to_s) || active_queue_work&.fetch("resume_pending", false)) &&
        @prompt_queue_dispatch_error.nil? && has_run_context &&
        ((@prompt_queue_claim && @prompt_queue_dispatch_error.nil?) ||
         (active_queue_work&.fetch("resume_pending", false) && !@prompt_queue_claim) ||
         (!active_queue_work && prompt_queue_due? && !@prompt_queue_claim))
    end

    def prompt_queue_due?(at = Time.now)
      @prompt_queue.any? { |entry| prompt_entry_due?(entry, at) }
    end

    def cancel_pending_sleep_recovery!
      removed = @prompt_queue.select { |entry| entry["source"] == "sleep_circuit_breaker_recovery" }
      return 0 if removed.empty?

      @prompt_queue.reject! { |entry| entry["source"] == "sleep_circuit_breaker_recovery" }
      incident_ids = removed.filter_map { |entry| entry.dig("message_metadata", "sleep_recovery_for_incident_id") }
      @runs.reverse_each do |run|
        incident_id = run.metadata&.dig("sleep_circuit_breaker_incident", "id")
        next unless incident_ids.include?(incident_id)

        run.metadata["sleep_recovery_cancelled"] = "manual_intent"
        break
      end
      removed.length
    end

    def pending_prompts?
      !@prompt_queue.empty? || !@prompt_queue_claim.nil? || !active_queue_work.nil?
    end

    def delegation_callback_prompts_only?
      entries = queued_prompts
      !entries.empty? && entries.all? { |entry| entry["source"] == "delegation_callback" }
    end

    def archive_pending_work!(archived_at: Time.now, reason: ARCHIVE_ABORT_MESSAGE, run_aborted: false)
      message = reason.to_s.strip
      message = ARCHIVE_ABORT_MESSAGE if message.empty?
      inquiry_cancelled = cancel_pending_inquiry!(
        created_at: archived_at,
        message: "Inquiry cancelled because agent was archived"
      )
      batches = [active_queue_work].compact
      unless @prompt_queue.empty?
        batch = QueueWork.build_batch(@prompt_queue, opened_at: archived_at)
        @queue_work["batches"] << batch
        batches << batch
      end

      memory = AgentMemory.new(self)
      archived_entries = []
      batches.each do |batch|
        unresolved = QueueWork.unresolved_ids(batch)
        next if unresolved.empty?

        entries = Array(batch["entries"]).select { |entry| unresolved.include?(entry["id"].to_s) }
        delivered = batch.fetch("delivery_count", 0).to_i.positive? || @prompt_queue_claim&.fetch("id", nil) == batch["id"]
        delivery_state = delivered ? "delivered_or_in_flight" : "not_delivered"
        entries.each do |entry|
          metadata = entry["message_metadata"].is_a?(Hash) ? entry["message_metadata"].dup : {}
          metadata.merge!(
            "archived_without_run" => !delivered,
            "queue_work_delivery_state" => delivery_state,
            "queue_work_batch_id" => batch["id"],
            "queue_work_state" => "archived",
            "queue_work_abort_message" => message,
            "queue_work_entry_id" => entry["id"].to_s
          )
          metadata["queued_at"] = entry["accepted_at"] unless entry["accepted_at"].to_s.empty?
          marked = memory.mark_user_message_archived_without_run!(
            { "queue_work_batch_id" => batch["id"] }, queued_at: entry["accepted_at"],
            delivery_state:, abort_message: message
          )
          memory.append_user_message!(
            entry.fetch("prompt"), created_at: archived_at, attachments: entry["attachments"], metadata:,
            event_id: metadata["prompt_arrival_event_id"]
          ) unless marked
        end
        dispositions = entries.map do |entry|
          outcome = if delivered
                      "aborted_with_uncertainty"
                    elsif QueueWork.entry_kind(entry) == "delegated_report"
                      "superseded_with_reason"
                    else
                      "declined_with_reason"
                    end
          { "entry_id" => entry.fetch("id").to_s, "outcome" => outcome, "reason" => message }
        end
        QueueWork.apply_dispositions!(batch, dispositions, completed_at: archived_at)
        archived_entries.concat(entries)
      end

      @prompt_queue = []
      @prompt_queue_claim = nil
      @prompt_queue_dispatch_error = nil
      @queue_work.delete("active_batch_id") unless active_queue_work
      if run_aborted || archived_entries.any?
        memory.append_assistant_message!(message, created_at: archived_at,
                                         metadata: { "archive_aborted_run" => true, "archived_queue_entry_count" => archived_entries.length })
      end
      { entries: archived_entries, inquiry_cancelled: inquiry_cancelled }
    end

    def unread?
      @unread
    end

    def archived?
      @archived
    end

    def refresh_session_identity!
      capture_session_id!
      @session_id
    end

    def mark_archived_visibility!(hidden)
      @project_hidden_at_archive = hidden == true
    end

    def scheduled?
      !@schedule_key.to_s.empty?
    end

    def associate_schedule!(schedule_key)
      @schedule_key = normalize_schedule_key(schedule_key)
    end

    def detach_schedule!(template_key: nil)
      @schedule_key = nil
      replacement = template_key.to_s.strip
      @template_key = replacement if @template_key.to_s == "scheduled" && !replacement.empty?
      self
    end

    def reconcile_project_group!(value)
      normalized = value.to_s
      return false if @project_group == normalized

      @project_group = normalized
      true
    end

    def associate_parent!(reference)
      normalized = normalize_delegation_parent(reference)
      raise ArgumentError, "Invalid delegation parent" unless normalized
      if @delegation_parent && @delegation_parent != normalized
        raise ArgumentError, "Agent #{@key} already has a different parent"
      end

      @delegation_parent ||= normalized
    end

    def display_name
      self.class.display_name_for(@name, scheduled: scheduled?)
    end

    def mark_unread!
      @unread = true
    end

    def mark_read!
      @unread = false
    end

    def start!(delegation_stamp: nil, run_metadata: nil, before_spawn: nil)
      return if running?

      finalize_previous_run!
      reconcile_session_bootstrap!
      if missing_native_session_identity?
        HQ.logger.warn("Agent") do
          "#{@key} has prior #{@agent} runs without a native session ID; starting a fresh native session"
        end
      end
      if claude_like_agent? && @session_id.to_s.empty?
        @session_id = SecureRandom.uuid
        @session_bootstrapped = false
      end
      response_style_text = resolved_response_style
      response_style_source = response_style_source_for(response_style_text)
      prompt_text = prompt_for_execution(response_style: response_style_text, include_hidden_guidance: false)
      execution = build_command
      command = execution.fetch(:command)
      environment = execution.fetch(:env, {})
      if (missing = missing_executable_for(command))
        return record_start_failure!(
          "Agent harness #{@agent.inspect} executable not found: #{missing}",
          command,
          run_metadata:
        )
      end

      @started_at = Time.now
      @finished_at = nil
      @last_exit_code = nil
      @stop_requested_at = nil
      mark_read!
      run_id = SecureRandom.uuid
      status_path = run_status_file_path(run_id)
      pid_path = run_pid_file_path(run_id)
      FileUtils.rm_f(status_path)
      FileUtils.rm_f(last_message_file_path)
      FileUtils.rm_f(invalid_structured_output_file_path)
      invalidate_derived_logs!
      log_start_offset = nil
      File.open(@log_path, "a") do |file|
        file.puts
        file.puts "=== [#{@started_at.strftime("%Y-%m-%d %H:%M:%S")}] start ==="
        log_start_offset = file.pos
        file.puts "workspace=#{@workspace}"
        file.puts "session_id=#{@session_id}" unless @session_id.to_s.empty?
        file.puts "prompt=#{prompt_text}"
        file.puts
        file.puts PROCESS_OUTPUT_MARKER
      end

      log_file = File.open(@log_path, "a")
      launch = structured_output_runner_launch(command, environment)
      run = AgentRun.new(
        started_at: @started_at,
        status: "running",
        log_path: @log_path,
        command: Shellwords.join(command),
        session_id: @session_id,
        response_style_source: response_style_source,
        agent: @agent,
        model: @model,
        log_start_offset: log_start_offset,
        run_id: run_id,
        run_scoped_status: true,
        delegation_owner: delegation_stamp&.fetch("owner", nil),
        delegation_generation: delegation_stamp&.fetch("generation", nil),
        metadata: run_metadata.is_a?(Hash) ? run_metadata : {}
      )
      memory_store.append_run_started!(run_id: run.run_id, created_at: @started_at)
      record_run!(run)
      before_spawn&.call(run)
      @pid = spawn(
        external_process_environment(launch.fetch(:env)).merge(
          "TYCHO_STATUS_PATH" => status_path,
          "TYCHO_PID_PATH" => pid_path,
          "TYCHO_AGENT_KEY" => @key,
          "TYCHO_EXECUTABLE" => File.join(ROOT_DIR, "bin", "tycho"),
          "TYCHO_STREAM_RECORDER_PATH" => File.expand_path("agent_stream_recorder", __dir__),
          "TYCHO_RAW_LOG_PATH" => @log_path,
          "TYCHO_MEMORY_PATH" => memory_path,
          "TYCHO_AGENT_TYPE" => harness_adapter,
          "TYCHO_RUN_ID" => run.run_id,
          "TYCHO_SLEEP_INCIDENT_PATH" => sleep_incident_file_path(run.run_id)
        ),
        current_ruby_executable, "--disable-gems", "-e", agent_runner_script, *launch.fetch(:command),
        chdir: @workspace, out: log_file, err: %i[child out], pgroup: true
      )
      log_file.close
      monitor_agent_process(@pid, status_path)
      HQ.logger.info("Agent") { "Started #{@key} (pid=#{@pid})" }
      @structured_result = nil
      @summary = nil
      HQ.hooks.publish("agent.run.started",
                       agent_key: @key,
                       project_key: @project_key,
                       workspace: @workspace,
                       session_id: @session_id.to_s,
                       pid: @pid)
      true
    rescue SystemCallError => e
      log_file&.close rescue nil
      if defined?(run) && run
        @pid = nil
        @finished_at = Time.now
        @last_exit_code = 127
        @structured_result = nil
        @summary = nil
        run.finished_at = @finished_at
        run.exit_code = @last_exit_code
        run.status = "failed"
        run.metadata = (run.metadata || {}).merge("start_failure" => true, "spawn_error" => e.message)
        FileUtils.rm_f(run_pid_file_path(run.run_id))
        before_spawn&.call(run)
        begin
          if @usage_metrics_store
            UsageMetrics.record_run(agent: self, run:, usage_entries: [], metrics_store: @usage_metrics_store)
          end
        rescue StandardError => metrics_error
          HQ.logger.warn("Agent") { "Failed to record spawn failure metrics for #{@key}: #{metrics_error.message}" }
        end
      end
      raise
    end

    def stop!
      return unless running?

      @stop_requested_at = Time.now
      terminate_process_group!(term_timeout: 1.0)
      poll! unless process_group_alive?
      HQ.logger.info("Agent") { "Stopped #{@key}" }
    rescue Errno::ESRCH, Errno::EPERM
      HQ.logger.warn("Agent") { "Failed to stop #{@key}: process not found or permission denied" }
      clear_foreign_pid!
    end

    def retire_for_archive!(timeout: 1.0)
      if @pid && process_group_alive?
        @stop_requested_at ||= Time.now
        terminate_process_group!(term_timeout: timeout)
        raise IOError, "Agent process group did not stop" if process_group_alive?
      end

      finalize_retired_run!
    end

    def poll!
      return unless @pid
      stop_stale_direct_output_wait! if running?
      return if running?

      recognize_sleep_circuit_breaker!
      @finished_at ||= Time.now
      @last_exit_code = read_exit_code
      @last_exit_code ||= 143 if @stop_requested_at
      FileUtils.rm_f(run_pid_file_path(last_run.run_id)) if last_run&.run_id
      finalize_latest_run!
      HQ.logger.info("Agent") { "#{@key} exited (code=#{@last_exit_code})" }
      @pid = nil
      HQ.hooks.publish("agent.run.finished",
                       agent_key: @key,
                       project_key: @project_key,
                       project_path: @workspace,
                       exit_code: @last_exit_code,
                       status: effective_status.to_s)
      dispatch_inquiry_hook!
    end

    def finalize_previous_run!
      return unless @pid
      return if running?

      @finished_at ||= Time.now
      @last_exit_code = read_exit_code
      FileUtils.rm_f(run_pid_file_path(last_run.run_id))
      @pid = nil
      finalize_latest_run!
      @pid = nil
    end

    # Self-heal for claude-like agents whose first run emitted the session_id
    # but whose `session_bootstrapped` flag never flipped (e.g. the prior run
    # was never finalized because HQ restarted or the poll tick was missed).
    # Without this, a restart would launch with `--session-id <id>` again, and
    # the CLI rejects it with "Session ID ... is already in use."
    def reconcile_session_bootstrap!
      return unless claude_like_agent?
      return if @session_bootstrapped
      return if @session_id.to_s.empty?
      return unless File.exist?(@log_path)

      target = @session_id
      found = File.foreach(@log_path).any? do |line|
        stripped = line.strip
        next false unless stripped.start_with?("{")

        event = begin
          JSON.parse(stripped)
        rescue JSON::ParserError
          nil
        end
        event.is_a?(Hash) && event["session_id"].to_s == target
      end

      @session_bootstrapped = true if found
    end

    def running?
      return false unless @pid
      return false if completed_status_available?
      return false unless ProcessLiveness.alive?(@pid)

      own_process_group?(@pid)
    end

    def completed_status_available?
      status_file_paths.any? { |path| valid_status_file?(path) }
    end

    def own_process_group?(pid)
      Process.getpgid(pid) == pid
    rescue Errno::ESRCH, Errno::EPERM
      false
    end

    def clear_foreign_pid!
      @pid = nil
      # rubocop:disable Style/OrAssignment
      @finished_at = Time.now unless @finished_at
      # rubocop:enable Style/OrAssignment
    end

    def status
      return "running" if running?
      return "awaiting-input" if awaiting_input?
      return "blocked" if blocked?
      return "idle" if @started_at.nil? && last_run.nil?
      return "idle" if @last_exit_code.nil?
      return "stopped" if stopped_exit_code?

      structured_status = @structured_result&.dig("status").to_s.strip
      return "succeeded" if %w[success succeeded no_action_needed].include?(structured_status)
      return "partial" if structured_status == "partial"
      return "failed" if structured_status == "failed"
      return "succeeded" if @last_exit_code.zero?

      "failed"
    end

    def workspace_name
      File.basename(@workspace.to_s.empty? ? "/" : @workspace)
    end

    def raw_log_path
      @log_path
    end

    def conversation_log_path
      derived_log_path("conversation.log")
    end

    def system_log_path
      derived_log_path("system.log")
    end

    def memory_path
      derived_log_path("memory.jsonl")
    end

    def attachments_path
      derived_log_path("attachments.json")
    end

    def pull_request_catalog_path
      derived_log_path("pull_request_catalog.json")
    end

    def invalidate_derived_logs!
      [conversation_log_path, system_log_path].each do |path|
        FileUtils.rm_f(path)
      end
    end

    def log_files
      [
        raw_log_path,
        conversation_log_path,
        system_log_path,
        memory_path,
        attachments_path,
        pull_request_catalog_path,
        "#{pull_request_catalog_path}.bak",
        "#{pull_request_catalog_path}.lock",
        invalid_structured_output_file_path,
        *status_file_paths,
        *@runs.filter_map { |run| run_status_file_path(run.run_id) unless run.run_id.to_s.empty? },
        *@runs.filter_map { |run| run_pid_file_path(run.run_id) unless run.run_id.to_s.empty? },
        *@runs.filter_map { |run| sleep_incident_file_path(run.run_id) unless run.run_id.to_s.empty? },
        last_message_file_path,
        legacy_status_file_path,
        legacy_last_message_file_path
      ].uniq
    end

    def archive_logs!(root = AGENT_ARCHIVE_DIR)
      present = log_files.select { |path| File.exist?(path) }
      destination = LogPaths.agent_archive_destination(root, @key)
      FileUtils.mkdir_p(destination)
      present.each do |path|
        FileUtils.mv(path, File.join(destination, File.basename(path)))
      end
      @usage_metrics_store&.mark_agent_archived(@key)
      FileStore.write_json(File.join(destination, "agent_manifest.json"), to_hash)
      archived_metrics = Array(@usage_metrics_store&.runs).select { |record| record["agent_key"] == @key }
      FileStore.write_json(
        File.join(destination, "usage_metrics.json"),
        { "schema_version" => UsageMetrics::Store::SCHEMA_VERSION, "runs" => archived_metrics }
      )
      FileUtils.touch(root)
      destination
    end

    def interactive_command
      command_builder.interactive
    end

    def harness_execution
      custom = HQ.custom_harness(@agent)
      if custom
        execution = custom.resolved_execution
        return { command: execution.fetch(:command), env: HarnessExecution.command_environment(execution.fetch(:env)) }
      end

      { command: [native_harness_executable], env: {} }
    end

    def rename!(name)
      @name = name
    end

    def update!(name:, template_key:, workspace:, prompt:, sandbox_mode: @sandbox_mode, agent: @agent,
                model: @model, reasoning_effort: @reasoning_effort, response_style: @response_style)
      previous_prompt = @prompt
      @name = name
      @template_key = template_key
      @workspace = workspace
      @prompt = prompt
      @sandbox_mode = normalize_sandbox_mode(sandbox_mode)
      @agent = normalize_agent(agent)
      @model = normalize_model(model)
      @reasoning_effort = normalize_reasoning_effort(reasoning_effort)
      @response_style = normalize_response_style(response_style)
      reset_base_prompt!
      memory_store.replace_system_prompt!(previous_prompt, @prompt, created_at: Time.now)
      HQ.hooks.publish("agent.updated",
                       agent_key: @key,
                       project_key: @project_key,
                       name: @name,
                       template_key: @template_key,
                       workspace: @workspace,
                       agent: @agent,
                       model: @model,
                       reasoning_effort: @reasoning_effort,
                       response_style: @response_style)
    end

    def effective_response_style_source
      response_style_source_for(resolved_response_style)
    end

    def add_user_message!(content, inquiry_id: nil, attachments: nil, metadata: nil, event_id: nil)
      text = content.to_s.strip
      return if text.empty?

      normalized_attachments = normalize_attachments(attachments) || []
      inquiry = latest_inquiry
      resolved_inquiry_id = inquiry_id.to_s.strip
      resolved_inquiry_id = latest_inquiry_id if inquiry && resolved_inquiry_id.empty?
      created_at = Time.now
      message_metadata = metadata.is_a?(Hash) ? metadata.dup : {}
      memory_metadata = metadata.is_a?(Hash) ? metadata.dup : {}
      message_metadata["attachments"] = normalized_attachments unless normalized_attachments.empty?
      if inquiry
        message_metadata["inquiry_response"] = true
        message_metadata["inquiry_id"] = resolved_inquiry_id unless resolved_inquiry_id.empty?
        memory_metadata["inquiry_response"] = true
        memory_metadata["inquiry_id"] = resolved_inquiry_id unless resolved_inquiry_id.empty?
      end
      message_metadata = nil if message_metadata.empty?
      memory_metadata = nil if memory_metadata.empty?
      @messages << AgentMessage.new(role: "user", content: text, created_at:, metadata: message_metadata)
      trim_messages!
      memory_store.append_user_message!(text, created_at:, attachments: normalized_attachments,
                                        metadata: memory_metadata, event_id:)
      if inquiry
        inquiry_event_id = event_id.to_s.strip.empty? ? nil : "#{event_id}:inquiry-response"
        memory_store.append_inquiry_response!(text, created_at:, inquiry_id: resolved_inquiry_id, event_id: inquiry_event_id)
      end
      HQ.hooks.publish("agent.message.user_added",
                       agent_key: @key,
                       project_key: @project_key,
                       content: text,
                       attachment_count: normalized_attachments.length)
      if inquiry
        HQ.hooks.publish("agent.inquiry.answered",
                         agent_key: @key,
                         project_key: @project_key,
                         answer: text)
      end
    end

    def message_author_metadata(actor)
      if actor&.internal? && actor.agent_key == @key
        return { "message_author" => { "type" => "agent", "agent_key" => @key, "name" => @name } }
      end
      return nil unless actor&.parent?
      return nil unless @delegation_parent&.fetch("agent_key", nil) == actor.agent_key

      author = @delegation_parent.each_with_object({ "type" => "agent" }) do |(key, value), result|
        next unless %w[server_id server_name agent_key name project_key].include?(key)
        next if value.nil? || value.to_s.empty?

        result[key] = value
      end
      { "message_author" => author }
    end

    def cancel_pending_inquiry!(created_at: Time.now, message: nil)
      inquiry_id = (latest_inquiry_id || suspended_inquiry_id).to_s
      return false if inquiry_id.empty?

      memory_store.append_inquiry_cancelled!(created_at:, inquiry_id:, message:)
      true
    end

    def suspended_inquiry
      memory_store.suspended_inquiry
    end

    def suspended_inquiry_id
      memory_store.suspended_inquiry_id
    end

    def inquiry_blocking_prompt_queue?
      !latest_inquiry.nil? || !suspended_inquiry.nil?
    end

    def suspend_inquiry!(inquiry_id, created_at: Time.now)
      expected_id = latest_inquiry_id.to_s
      return false if expected_id.empty? || inquiry_id.to_s != expected_id

      memory_store.append_inquiry_suspended!(created_at:, inquiry_id: expected_id)
    end

    def restore_inquiry!(inquiry_id, created_at: Time.now)
      expected_id = suspended_inquiry_id.to_s
      return false if expected_id.empty? || inquiry_id.to_s != expected_id

      memory_store.append_inquiry_restored!(created_at:, inquiry_id: expected_id)
    end

    def retire_suspended_inquiry!(inquiry_id, created_at: Time.now)
      expected_id = suspended_inquiry_id.to_s
      return false if expected_id.empty? || inquiry_id.to_s != expected_id

      memory_store.append_inquiry_retired!(created_at:, inquiry_id: expected_id)
    end

    def add_assistant_message!(content)
      text = content.to_s.strip
      return if text.empty?

      @messages << AgentMessage.new(role: "assistant", content: text, created_at: Time.now)
      trim_messages!
      HQ.hooks.publish("agent.message.assistant_added",
                       agent_key: @key,
                       project_key: @project_key,
                       content: text)
    end

    def conversation_messages
      memory_store.conversation_messages.map do |message|
        AgentMessage.new(
          role: message[:role],
          content: message[:content],
          created_at: message[:created_at],
          metadata: message[:metadata].is_a?(Hash) ? message[:metadata] : nil
        )
      end
    end

    def latest_user_message_after(time, ignored_metadata: nil, inclusive: false)
      memory_store.latest_user_message_after(time, ignored_metadata:, inclusive:)
    end

    def run_count
      @total_run_count = [@total_run_count, @runs.length].max
    end

    def reconcile_run_count!(value)
      count = Integer(value)
      @total_run_count = [@total_run_count, count, @runs.length].max if count >= 0
    rescue ArgumentError, TypeError
      @total_run_count
    end

    def last_run
      @runs.last
    end

    def last_result_label
      return "never run" unless last_run

      case effective_status
      when "running" then "in progress"
      when "success", "succeeded" then "success"
      when "no_action_needed" then "no action"
      when "input_required" then "awaiting input"
      when "partial" then "partial"
      when "blocked" then "blocked"
      when "stopped" then "stopped"
      when "failed" then "failed"
      else
        effective_status.to_s
      end
    end

    def last_summary
      return "No runs yet" if run_count.zero?

      structured_summary || inquiry_message || @summary || (status == "running" ? "Run in progress" : "Run summary unavailable")
    end

    def latest_inquiry
      sentinel = Object.new
      memory_inquiry = memory_store.latest_inquiry(fallback: sentinel)
      return nil if memory_inquiry.nil?

      cached_inquiry = current_structured_inquiry
      return cached_inquiry if memory_inquiry.equal?(sentinel)

      merge_inquiries(memory_inquiry, cached_inquiry)
    end

    def latest_inquiry_id
      inquiry = latest_inquiry
      return nil unless inquiry

      stored_id = memory_store.latest_inquiry_id
      return stored_id unless stored_id.to_s.strip.empty?

      inquiry_identity(inquiry, run: last_run)
    end

    def attachments
      dedupe_attachments(memory_store.attachments + current_structured_attachments)
    end

    def delete_attachment!(attachment)
      deleted = memory_store.delete_attachment!(attachment)
      delete_structured_attachment!(attachment) || deleted
    end

    def effective_status
      cached = @structured_result&.dig("status").to_s.strip
      return cached unless cached.empty?

      last_run&.status
    end

    def no_action_needed?
      effective_status == "no_action_needed"
    end

    def delegation_recovery_context
      metadata = last_run&.metadata
      return nil unless metadata.is_a?(Hash) && metadata["stop_reason"] == "sleep_circuit_breaker"

      incident = metadata["sleep_circuit_breaker_incident"]
      return nil unless incident.is_a?(Hash) && !incident["id"].to_s.empty?

      incident_id = incident.fetch("id")
      recovery_entry = queued_prompts.find do |entry|
        entry["source"] == "sleep_circuit_breaker_recovery" &&
          entry.dig("message_metadata", "sleep_recovery_for_incident_id").to_s == incident_id.to_s
      end
      state, reason = delegation_recovery_state(metadata, recovery_entry)
      accepted_at = self.class.parse_time(recovery_entry&.fetch("accepted_at", nil))
      not_before = self.class.parse_time(recovery_entry&.fetch("not_before", nil))
      {
        "type" => "sleep_circuit_breaker",
        "incident_id" => incident_id,
        "expected_safety_behavior" => true,
        "state" => state,
        "scheduled_at" => recovery_entry&.fetch("accepted_at", nil),
        "not_before" => recovery_entry&.fetch("not_before", nil),
        "delay_seconds" => accepted_at && not_before ? (not_before - accepted_at).round : nil,
        "parent_action" => %w[pending scheduled resuming].include?(state) ? "none" : "required",
        "reason" => reason,
        "cancels_on" => %w[manual_prompt ownership_change]
      }.compact
    end

    # A parent-owned turn reports through the delegation coordinator. Its
    # completion is not an operator-facing event, even if the child remains
    # delegated after the turn ends. Match the per-run stamp to the current
    # relationship so a stale run cannot lose both its callback and operator
    # attention after a takeover.
    def suppresses_operator_attention?(delegation_stamp: nil)
      run = last_run
      return false unless run&.delegation_owner == "parent"
      return false unless delegation_stamp.is_a?(Hash)

      delegation_stamp["owner"] == "parent" &&
        run.delegation_generation.is_a?(Integer) &&
        run.delegation_generation == delegation_stamp["generation"]
    end

    def last_activity_at
      @finished_at || @started_at || @created_at
    end

    # Re-derive the agent-level summary cache from raw.log. Always reads the
    # last `=== […] start ===` segment of @log_path, parses out the structured
    # result, and updates @structured_result / @summary plus the latest run's
    # status. Safe to call any time — used by finalize_latest_run! and by the
    # explicit rebuild path.
    def build_summary!
      payload = read_structured_result_payload_from_log
      structured = payload ? normalize_structured_result(payload) : nil

      @structured_result = structured
      @summary = compute_summary_text(structured)
      if (run = @runs.last)
        run.status = effective_status if run.status != "running"
      end
      @summary
    end

    def self.parse_time(value)
      return nil if value.to_s.empty?

      Time.parse(value.to_s)
    rescue StandardError
      nil
    end

    private

    def current_ruby_executable
      configured = RbConfig.ruby.to_s
      return configured if File.file?(configured) && File.executable?(configured)

      resolved = ExecutableResolver.executable_path("ruby")
      return resolved if resolved

      raise Errno::ENOENT,
            "Tycho's Ruby executable no longer exists at #{configured.inspect}, and no current ruby was found on PATH. " \
            "Install or activate Ruby, then restart Tycho before retrying the queue"
    end

    def delegation_recovery_state(metadata, entry)
      cancelled = metadata["sleep_recovery_cancelled"].to_s
      return ["cancelled", cancelled] unless cancelled.empty?

      suppressed = metadata["sleep_recovery_suppressed"].to_s
      return ["suppressed", suppressed] unless suppressed.empty?
      return ["pending", nil] if metadata["sleep_recovery_pending"] == true
      return ["not_scheduled", "automatic_recovery_not_scheduled"] unless entry
      return ["failed", @prompt_queue_dispatch_error["message"]] if entry["state"] == "failed"
      return ["resuming", nil] unless entry["state"] == "queued"

      ["scheduled", nil]
    end

    def circuit_breaker_recovery_metadata(entries, claim:, batch:)
      return nil unless entries.length == 1

      entry = entries.first
      return nil unless entry["source"] == "sleep_circuit_breaker_recovery"

      message_metadata = entry["message_metadata"].is_a?(Hash) ? entry["message_metadata"] : {}
      accepted_at = self.class.parse_time(entry["accepted_at"])
      not_before = self.class.parse_time(entry["not_before"])
      delay_seconds = not_before && accepted_at ? (not_before - accepted_at).round : nil
      {
        "incident_id" => message_metadata["sleep_recovery_for_incident_id"],
        "entry_id" => entry["id"],
        "instruction" => entry["prompt"],
        "accepted_at" => entry["accepted_at"],
        "not_before" => entry["not_before"],
        "resumed_at" => claim["claimed_at"],
        "delay_seconds" => delay_seconds,
        "blocking_call_count" => message_metadata["sleep_recovery_blocking_call_count"],
        "threshold" => message_metadata["sleep_recovery_threshold"],
        "stopped_at" => message_metadata["sleep_recovery_observed_at"],
        "queue_work_batch_id" => batch&.fetch("id", nil)
      }.compact
    end

    def derived_log_path(suffix)
      LogPaths.derived_agent_log_path(@log_path, suffix)
    end

    def command_builder(prompt: prompt_for_execution, session_id: @session_id,
                        session_bootstrapped: @session_bootstrapped)
      execution = harness_execution
      AgentCommandBuilder.new(
        agent: @agent,
        harness_adapter: harness_adapter,
        workspace: @workspace,
        sandbox_mode: @sandbox_mode,
        model: @model,
        reasoning_effort: @reasoning_effort,
        session_id: session_id,
        session_bootstrapped: session_bootstrapped,
        prompt: prompt,
        harness_command_prefix: execution.fetch(:command),
        harness_command_environment: execution.fetch(:env),
        last_message_file_path: last_message_file_path,
        result_schema_path: result_schema_path,
        claude_result_schema: canonical_result_schema_json
      )
    end

    def build_command(prompt: prompt_for_execution)
      command_builder(prompt:).build
    end

    def structured_output_runner_launch(command, environment)
      return { command:, env: environment } unless structured_output_correction_supported?

      correction = command_builder(
        prompt: AgentCorrectionRunner::PROMPT_PLACEHOLDER,
        session_id: AgentCorrectionRunner::SESSION_PLACEHOLDER,
        session_bootstrapped: true
      ).build
      config = {
        "initial_command" => command,
        "correction_command" => correction.fetch(:command),
        "harness_adapter" => harness_adapter,
        "schema_path" => result_schema_path,
        "last_message_path" => last_message_file_path,
        "invalid_response_path" => invalid_structured_output_file_path,
        "session_id" => @session_id.to_s,
        "correction_limit" => structured_output_correction_limit
      }
      runner_command = [
        current_ruby_executable,
        "--disable-gems",
        "-I", File.expand_path("../..", __dir__),
        "-r", "hq/domain/agent_correction_runner",
        "-e", "HQ::AgentCorrectionRunner.run_from_environment!"
      ]
      {
        command: runner_command,
        env: environment.merge("TYCHO_AGENT_RUNNER_CONFIG" => JSON.generate(config))
      }
    end

    def structured_output_correction_supported?
      File.file?(result_schema_path) && %w[codex claude pi].include?(harness_adapter)
    end

    def structured_output_correction_limit
      value = Integer(ENV.fetch("TYCHO_STRUCTURED_OUTPUT_CORRECTION_LIMIT", STRUCTURED_OUTPUT_CORRECTION_LIMIT.to_s))
      [[value, 0].max, MAX_STRUCTURED_OUTPUT_CORRECTION_LIMIT].min
    rescue ArgumentError, TypeError
      STRUCTURED_OUTPUT_CORRECTION_LIMIT
    end

    def missing_executable_for(command)
      executable = executable_for_preflight(command)
      return "execution command" if executable.to_s.empty?
      return nil if executable_available?(executable)

      executable
    end

    def executable_for_preflight(command)
      parts = Array(command).map(&:to_s).reject(&:empty?)
      return nil if parts.empty?

      first = parts.first
      return first unless File.basename(first) == "env"

      parts.drop(1).find { |part| !part.include?("=") } || first
    end

    def executable_available?(command)
      if command.include?(File::SEPARATOR)
        return File.file?(command) && File.executable?(command)
      end

      ENV.fetch("PATH", "").split(File::PATH_SEPARATOR).any? do |dir|
        path = File.join(dir, command)
        File.file?(path) && File.executable?(path)
      end
    end

    def record_start_failure!(message, command, run_metadata: nil)
      @started_at = Time.now
      @finished_at = @started_at
      @last_exit_code = 127
      @stop_requested_at = nil
      @pid = nil
      mark_read!
      FileUtils.rm_f(status_file_path)
      FileUtils.rm_f(last_message_file_path)
      FileUtils.rm_f(invalid_structured_output_file_path)
      invalidate_derived_logs!

      log_start_offset = nil
      File.open(@log_path, "a") do |file|
        file.puts
        file.puts "=== [#{@started_at.strftime("%Y-%m-%d %H:%M:%S")}] start failed ==="
        log_start_offset = file.pos
        file.puts "workspace=#{@workspace}"
        file.puts "session_id=#{@session_id}" unless @session_id.to_s.empty?
        file.puts "command=#{Shellwords.join(command)}"
        file.puts "error=#{message}"
        file.puts
      end

      metadata = run_metadata.is_a?(Hash) ? run_metadata.dup : {}
      metadata["start_failure"] = true
      metadata["start_error"] = message.to_s[0, 600]
      failed_run = record_run!(AgentRun.new(
        run_id: SecureRandom.uuid,
        started_at: @started_at,
        finished_at: @finished_at,
        exit_code: @last_exit_code,
        status: "failed",
        log_path: @log_path,
        command: Shellwords.join(command),
        agent: @agent,
        model: @model,
        log_start_offset: log_start_offset,
        metadata:
      ))
      if @usage_metrics_store
        UsageMetrics.record_run(
          agent: self,
          run: failed_run,
          usage_entries: [],
          metrics_store: @usage_metrics_store
        )
      end
      @structured_result = nil
      @summary = message
      HQ.logger.warn("Agent") { "Failed to start #{@key}: #{message}" }
      false
    end

    def claude_session_arguments
      command_builder(prompt: "").claude_session_arguments
    end

    def status_file_path
      return run_status_file_path(last_run.run_id) unless last_run&.run_id.to_s.empty?

      unscoped_status_file_path
    end

    def status_file_paths
      return [run_status_file_path(last_run.run_id)] unless last_run&.run_id.to_s.empty?

      [unscoped_status_file_path, legacy_status_file_path].uniq
    end

    def run_status_file_path(run_id)
      token = Digest::SHA256.hexdigest(run_id.to_s)[0, 24]
      derived_log_path("run-#{token}.status")
    end

    def run_pid_file_path(run_id)
      token = Digest::SHA256.hexdigest(run_id.to_s)[0, 24]
      derived_log_path("run-#{token}.pid")
    end

    def sleep_incident_file_path(run_id)
      token = Digest::SHA256.hexdigest(run_id.to_s)[0, 24]
      derived_log_path("run-#{token}.sleep-incident.json")
    end

    def unscoped_status_file_path
      derived_log_path("status")
    end

    def legacy_status_file_path
      File.join(AGENT_LOGS_DIR, "#{@key}.status")
    end

    def agent_runner_script
      <<~RUBY
        begin
          File.write(ENV.fetch("TYCHO_PID_PATH"), Process.pid.to_s)
        rescue StandardError
          nil
        end
        status = begin
          recorder_path = ENV["TYCHO_STREAM_RECORDER_PATH"].to_s
          if !recorder_path.empty? && !ENV["TYCHO_MEMORY_PATH"].to_s.empty?
            require recorder_path
            HQ::AgentStreamRecorder.run(
              command: ARGV,
              raw_log_path: ENV.fetch("TYCHO_RAW_LOG_PATH"),
              memory_path: ENV.fetch("TYCHO_MEMORY_PATH"),
              agent_type: ENV.fetch("TYCHO_AGENT_TYPE"),
              run_id: ENV.fetch("TYCHO_RUN_ID"),
              incident_path: ENV["TYCHO_SLEEP_INCIDENT_PATH"]
            )
          else
            result = system(*ARGV)
            child = $?
            if result.nil?
              warn "failed to execute \#{ARGV.first.inspect} (exit 127)"
              127
            elsif child&.signaled?
              128 + child.termsig.to_i
            else
              child ? child.exitstatus.to_i : (result ? 0 : 1)
            end
          end
        rescue SystemCallError => e
          warn e.message
          127
        rescue StandardError => e
          warn e.message
          1
        end
        begin
          path = ENV.fetch("TYCHO_STATUS_PATH")
          temporary_path = "\#{path}.tmp-\#{Process.pid}"
          File.write(temporary_path, status.to_s)
          File.rename(temporary_path, path)
        rescue StandardError
          nil
        ensure
          File.delete(temporary_path) if temporary_path && File.exist?(temporary_path)
        end
        begin
          executable = ENV.fetch("TYCHO_EXECUTABLE")
          agent_key = ENV.fetch("TYCHO_AGENT_KEY")
          ruby = File.executable?(RbConfig.ruby) ? RbConfig.ruby : "ruby"
          system(ruby, executable, "agent", "finalize", agent_key, out: File::NULL, err: File::NULL)
        rescue StandardError
          nil
        end
        exit(status)
      RUBY
    end

    def monitor_agent_process(pid, status_path)
      thread = Thread.new do
        _waited_pid, status = Process.wait2(pid)
        begin
          # The runner publishes the harness status before finalization; only fill in when it could not.
          write_status_file(status_path, process_exit_code(status)) unless valid_status_file?(status_path)
        rescue StandardError
          nil
        end
      rescue Errno::ECHILD
        nil
      end
      (@process_monitors ||= {})[pid] = thread
      thread
    end

    def process_exit_code(status)
      return 1 unless status
      return 128 + status.termsig.to_i if status.signaled?

      status.exitstatus.to_i
    end

    def write_status_file(path, exit_code)
      temporary_path = "#{path}.tmp-#{Process.pid}-#{Thread.current.object_id}"
      File.write(temporary_path, Integer(exit_code).to_s)
      File.rename(temporary_path, path)
    ensure
      FileUtils.rm_f(temporary_path) if temporary_path
    end

    def external_process_environment(environment)
      HarnessExecution.environment(environment)
    end

    def last_message_file_path
      derived_log_path("last_message.json")
    end

    def invalid_structured_output_file_path
      derived_log_path("invalid_structured_output.json")
    end

    def legacy_last_message_file_path
      File.join(AGENT_LOGS_DIR, "#{@key}.last_message.json")
    end

    def read_exit_code
      if @pid && (monitor = @process_monitors&.delete(@pid))
        monitor.join(0.5)
      end
      path = status_file_paths.find { |candidate| valid_status_file?(candidate) }
      if !path && last_run && !last_run.run_scoped_status
        path = [unscoped_status_file_path, legacy_status_file_path].find do |candidate|
          valid_status_file?(candidate)
        end
      end
      return nil unless path

      Integer(File.read(path).strip, 10)
    rescue StandardError
      nil
    ensure
      FileUtils.rm_f(path) if path
    end

    def valid_status_file?(path)
      return false unless File.file?(path)

      Integer(File.read(path).strip, 10)
      true
    rescue ArgumentError, TypeError, SystemCallError
      false
    end

    def finalize_latest_run!
      run = @runs.last
      return unless run
      return unless run.status == "running"

      # A completed status file can make running? false while the wrapper process is still alive.
      @pid = nil
      run.finished_at = @finished_at
      run.exit_code = @last_exit_code
      run.status = status
      capture_session_id!
      run.session_id = @session_id unless @session_id.to_s.empty?
      build_summary!
      apply_sleep_circuit_breaker_result!(run)
      gate_successful_queue_work!(run)
      persist_memory_handoff!(run)
      capture_run_memory!(run)
      add_assistant_message!(@summary) if @summary
      HQ.hooks.publish("agent.run.finalized",
                       agent_key: @key,
                       project_key: @project_key,
                       status: run.status.to_s,
                       exit_code: run.exit_code,
                       summary: @summary.to_s,
                       structured_result: @structured_result)
    end

    def compute_summary_text(structured)
      summary = structured&.dig("summary").to_s.strip
      return summary unless summary.empty?

      fallback_summary_text
    end

    def fallback_summary_text(context: nil, context_label: "Last assistant message")
      context ||= safe_assistant_context_from_log
      if context.to_s.empty? && (operator_context = safe_operator_context_from_log)
        context = operator_context
        context_label = "Run context"
      end
      lines = [
        "## Summary unavailable",
        "",
        "This run returned without a usable structured summary."
      ]
      if context.to_s.empty?
        lines.concat(["", fallback_no_context_message])
      else
        lines.concat(["", "### #{context_label}", "", markdown_quote(context)])
      end
      lines.join("\n")
    end

    def fallback_no_context_message
      case status
      when "stopped"
        "The run was interrupted before it produced a usable assistant message."
      when "failed"
        "The run ended before it produced a usable assistant message."
      else
        "No usable assistant message is available."
      end
    end

    def gate_successful_queue_work!(run)
      return unless %w[success no_action_needed partial].include?(@structured_result&.fetch("status", nil).to_s)

      batch = active_queue_work || open_queue_work_batch!(opened_at: @finished_at || Time.now)
      return unless batch

      delivered = Array(run.metadata&.fetch("prompt_queue_entry_ids", nil)).map(&:to_s)
      unresolved = QueueWork.unresolved_ids(batch)
      unresolved &= delivered unless delivered.empty?
      return if unresolved.empty?

      if batch.fetch("delivery_count", 0).to_i.positive?
        dispositions = Array(batch["entries"]).filter_map do |entry|
          entry_id = entry["id"].to_s
          next unless unresolved.include?(entry_id)

          outcome = QueueWork.entry_kind(entry) == "delegated_report" ? "incorporated" : "completed"
          { "entry_id" => entry_id, "outcome" => outcome }
        end
        QueueWork.apply_dispositions!(batch, dispositions, completed_at: @finished_at || Time.now)
        @queue_work.delete("active_batch_id") if QueueWork.terminal?(batch)
        run.metadata = (run.metadata.is_a?(Hash) ? run.metadata.dup : {}).merge(
          "queue_work_auto_completed" => true,
          "queue_work_batch_id" => batch["id"],
          "queue_work_auto_disposition_entry_ids" => unresolved
        )
        return
      end

      resumed = QueueWork.request_automatic_continuation!(batch)
      run.metadata = (run.metadata.is_a?(Hash) ? run.metadata.dup : {}).merge(
        "queue_work_gate" => true,
        "queue_work_batch_id" => batch["id"],
        "queue_work_unresolved_entry_ids" => unresolved,
        "queue_work_auto_continuation" => resumed
      )
      @structured_result = @structured_result.merge(
        "status" => "partial",
        "summary" => "Queue work batch #{batch['id']} remains open; unresolved entries: #{unresolved.join(', ')}."
      )
      @summary = @structured_result.fetch("summary")
      run.status = "partial"
    end

    def persist_memory_handoff!(run)
      return unless run.status == "success"

      handoff = MemoryHandoff.normalize(@structured_result&.fetch("memory_handoff", nil))
      return unless handoff

      run.metadata = (run.metadata.is_a?(Hash) ? run.metadata.dup : {})
      run.metadata["memory_handoff"] = handoff
    end

    def normalize_structured_result(parsed)
      result_normalizer.normalize_structured_result(parsed)
    rescue StandardError => e
      HQ.logger.warn("Agent") { "Failed to normalize result for #{@key}: #{e.message}" }
      nil
    end

    def safe_assistant_context_from_log
      return nil unless File.exist?(@log_path)

      last_run_log_lines.last(120).reverse_each do |line|
        event = parse_json_line(line.to_s.strip)
        next unless event.is_a?(Hash)

        text = raw_assistant_text_from_event(event)
        next if text.to_s.empty?

        context = safe_assistant_context_text(text)
        return bounded_fallback_context(context) unless context.to_s.empty?
      end
      nil
    rescue StandardError
      nil
    end

    def safe_operator_context_from_log
      return nil unless File.exist?(@log_path)

      marker = last_run_log_lines.last(20).reverse.find do |line|
        line.to_s.match?(/\ATycho stopped this run after no structured agent output stayed idle for \d+ seconds\.\s*\z/)
      end
      bounded_fallback_context(marker)
    rescue StandardError
      nil
    end

    def raw_assistant_text_from_event(event)
      case event["type"]
      when "item.completed"
        item = event["item"]
        return "" unless item.is_a?(Hash) && item["type"] == "agent_message"

        item["text"].to_s.strip
      when "assistant"
        Array(event.dig("message", "content")).filter_map do |item|
          item["text"].to_s.strip if item.is_a?(Hash) && item["type"] == "text"
        end.join("\n").strip
      when "text"
        part = event["part"]
        return "" unless part.is_a?(Hash) && part["type"] == "text"

        part["text"].to_s.strip
      when "message_end"
        message = event["message"]
        return "" unless message.is_a?(Hash) && message["role"] == "assistant"

        Array(message["content"]).filter_map do |item|
          item["text"].to_s.strip if item.is_a?(Hash) && item["type"] == "text"
        end.join("\n").strip
      else
        ""
      end
    end

    def safe_assistant_context_text(text)
      original = text.to_s.strip
      return nil if original.empty?

      candidate, fenced = unwrap_fallback_fence(original)
      return nil if fenced && fallback_record_signature?(candidate, fenced: true)

      parsed = JSON.parse(candidate)
      return original unless parsed.is_a?(Hash) || parsed.is_a?(Array)
      return nil unless parsed.is_a?(Hash)
      return nil unless parsed.keys.any? { |key| structured_fallback_key?(key) }

      summary = parsed["summary"]
      return summary.strip if summary.is_a?(String) && !summary.strip.empty?

      inquiry = parsed["inquiry"]
      message = inquiry["message"] if inquiry.is_a?(Hash)
      message.is_a?(String) && !message.strip.empty? ? message.strip : nil
    rescue JSON::ParserError
      fallback_record_signature?(candidate || original, fenced:) ? nil : original
    end

    def unwrap_fallback_fence(text)
      value = text.to_s.strip
      return [value, false] unless value.start_with?("```")

      body = value.sub(/\A```[^\r\n]*[\r\n]?/, "").sub(/[\r\n]?```\s*\z/, "").strip
      [body, true]
    end

    def structured_fallback_key?(key)
      %w[status summary inquiry attachments summary_sections].include?(key.to_s)
    end

    def fallback_record_signature?(text, fenced: false)
      value = text.to_s.strip
      return false if value.empty?
      return true if value.start_with?("{", "[")
      return true if fenced && value.match?(/[\[{]/)
      return true if value.match?(/\A(?:prompt|analysis|reasoning|tool(?:_(?:use|call|result|payload))?|function_call|metadata)\s*[:=]/i)

      value.match?(/(?:\A|[\s{,])["']?(?:status|summary|inquiry|attachments|memory_handoff|summary_sections|type|role|tool|tool_use|tool_call|tool_result|tool_payload|function_call|prompt|analysis|reasoning|metadata)["']?\s*[:=]/i)
    end

    def bounded_fallback_context(text)
      redacted = redact_fallback_context(text)
      lines = redacted.lines(chomp: true).first(FALLBACK_SUMMARY_CONTEXT_MAX_LINES)
      value = lines.join("\n").strip
      return nil if value.empty?

      truncated = redacted.lines(chomp: true).length > FALLBACK_SUMMARY_CONTEXT_MAX_LINES
      if value.length > FALLBACK_SUMMARY_CONTEXT_MAX_CHARS
        value = value.each_char.take(FALLBACK_SUMMARY_CONTEXT_MAX_CHARS - 1).join.rstrip
        truncated = true
      end
      truncated ? "#{value}…" : value
    end

    def redact_fallback_context(text)
      value = text.to_s
      return "[REDACTED]" if value.match?(ProjectWorkspace::PRIVATE_KEY_MARKER)

      value = value
        .gsub(/github_pat_[A-Za-z0-9_]+|gh[pousr]_[A-Za-z0-9_]+/i, "[REDACTED]")
        .gsub(/(Bearer\s+)[^\s]+/i, "\\1[REDACTED]")
      ProjectWorkspace::SECRET_VALUE_PATTERNS.each { |pattern| value = value.gsub(pattern, "[REDACTED]") }
      value.gsub(/((?:api[_-]?key|access[_-]?token|auth[_-]?token|client[_-]?secret|password|secret|token)\s*[:=]\s*)\S+/i,
                 "\\1[REDACTED]")
    end

    def markdown_quote(text)
      text.to_s.lines(chomp: true).map { |line| "> #{line}" }.join("\n")
    end

    def parse_json_line(line)
      JSON.parse(line)
    rescue JSON::ParserError
      nil
    end

    def stopped_exit_code?
      return true if [128 + Signal.list["TERM"].to_i, 143].include?(@last_exit_code)

      @stop_requested_at && @last_exit_code.to_i.positive?
    end

    def recognize_sleep_circuit_breaker!
      return unless last_run&.run_id
      return unless File.file?(sleep_incident_file_path(last_run.run_id))

      @stop_requested_at ||= Time.now
    end

    def sleep_circuit_breaker_incident(run)
      return nil unless run&.run_id

      payload = JSON.parse(File.read(sleep_incident_file_path(run.run_id)))
      payload.is_a?(Hash) && payload["reason"] == "sleep_circuit_breaker" ? payload : nil
    rescue JSON::ParserError, SystemCallError
      nil
    end

    def apply_sleep_circuit_breaker_result!(run)
      incident = sleep_circuit_breaker_incident(run)
      return false unless incident

      metadata = run.metadata.is_a?(Hash) ? run.metadata.dup : {}
      already_recovering = !metadata["sleep_recovery_for_incident_id"].to_s.empty?
      incident = incident.merge("ownership_generation" => run.delegation_generation)
      metadata["stop_reason"] = "sleep_circuit_breaker"
      metadata["sleep_circuit_breaker_incident"] = incident
      metadata["sleep_recovery_pending"] = !already_recovering
      metadata["sleep_recovery_suppressed"] = "recovery_loop" if already_recovering
      run.metadata = metadata
      run.status = "stopped"
      @structured_result = nil
      @summary = "Stopped due to overusing sleep-like commands"
      true
    end

    def signal_process_group(signal)
      Process.kill(signal, -@pid)
    rescue Errno::ESRCH
      nil
    rescue Errno::EPERM
      clear_foreign_pid!
    end

    def wait_until_not_running(timeout)
      deadline = Time.now + timeout.to_f
      while running? && Time.now < deadline
        sleep 0.05
      end
    end

    def process_group_alive?(pid = @pid)
      return false unless pid

      Process.kill(0, -pid)
      true
    rescue Errno::ESRCH, Errno::EPERM
      false
    end

    def wait_until_process_group_stops(timeout)
      deadline = Time.now + timeout.to_f
      while process_group_alive? && Time.now < deadline
        sleep 0.05
      end
    end

    def stop_stale_direct_output_wait!(now: Time.now)
      reason = stale_direct_output_wait(now:)
      return false unless reason

      @stop_requested_at = now
      append_direct_output_stop_marker!(reason)
      terminate_process_group!(term_timeout: 1.0)
      true
    end

    def terminate_process_group!(term_timeout:, kill_timeout: 0.5)
      signal_process_group("TERM")
      wait_until_process_group_stops(term_timeout)
      return unless process_group_alive?

      signal_process_group("KILL")
      wait_until_process_group_stops(kill_timeout)
    end

    def stale_direct_output_wait(now:)
      return nil if awaiting_input? || latest_inquiry
      return nil unless File.file?(@log_path)

      idle_for = now - File.mtime(@log_path)
      return nil if idle_for < DIRECT_OUTPUT_IDLE_TIMEOUT_SECONDS

      direct_output_wait_reason
    rescue StandardError
      nil
    end

    def direct_output_wait_reason
      lines = process_output_lines
      return nil if lines.any? { |line| agent_json_event?(line) }

      "no structured agent output"
    end

    def process_output_lines
      lines = last_run_log_lines.last(120).map(&:to_s)
      marker_index = lines.rindex(PROCESS_OUTPUT_MARKER)
      marker_index ? lines[(marker_index + 1)..] : lines
    end

    def agent_json_event?(line)
      event = parse_json_line(line.to_s.strip)
      event.is_a?(Hash) && !event["type"].to_s.empty?
    end

    def append_direct_output_stop_marker!(reason)
      File.open(@log_path, "a") do |file|
        file.puts
        file.puts "Tycho stopped this run after #{reason} stayed idle for " \
                  "#{DIRECT_OUTPUT_IDLE_TIMEOUT_SECONDS} seconds."
      end
    rescue StandardError
      nil
    end

    def finalize_retired_run!
      @finished_at ||= Time.now if @started_at || @pid || last_run
      @last_exit_code = read_exit_code if @last_exit_code.nil?
      if last_run&.status == "running" || @stop_requested_at
        @stop_requested_at ||= Time.now
        @last_exit_code ||= 143
      end
      finalize_latest_run!
      @pid = nil
      @structured_result = nil if last_run&.status == "stopped"
      @summary ||= "Stopped by schedule resume" if last_run&.status == "stopped"
      self
    end

    def trim_runs!
      @runs = @runs.last(10)
    end

    def record_run!(run)
      @total_run_count = [@total_run_count, @runs.length].max + 1
      @runs << run
      trim_runs!
      run
    end

    def infer_total_run_count(value)
      unless value.nil?
        persisted = Integer(value)
        return [persisted, @runs.length].max if persisted >= 0
      end

      summaries = memory_store.events.select { |event| event["type"] == "run_summary" }
      numbered_count = summaries.filter_map { |event| event.dig("metadata", "run_number")&.to_i }.max.to_i
      completed_count = [summaries.length, numbered_count].max
      active_count = last_run&.status == "running" ? completed_count + 1 : completed_count
      snapshot_count = @cost_snapshot&.fetch("through_run_count", 0).to_i
      [@runs.length, active_count, snapshot_count].max
    rescue StandardError
      @runs.length
    end

    def trim_messages!
      @messages = @messages.last(12)
    end

    def structured_summary
      text = @structured_result&.dig("summary").to_s.strip
      text.empty? ? nil : text
    end

    def current_structured_inquiry
      inquiry = @structured_result&.dig("inquiry")
      inquiry.is_a?(Hash) ? inquiry : nil
    end

    def inquiry_message
      text = current_structured_inquiry&.dig("message").to_s.strip
      text.empty? ? nil : text
    end

    def current_structured_attachments
      attachments = normalize_attachments(@structured_result&.dig("attachments")) || []
      created_at = last_run&.finished_at || @finished_at
      return attachments unless created_at

      attachments.map do |attachment|
        attachment.merge("created_at" => attachment["created_at"] || created_at.iso8601)
      end
    end

    def delete_structured_attachment!(attachment)
      return false unless @structured_result.is_a?(Hash)

      target_key = attachment_dedupe_key(attachment)
      return false unless target_key

      attachments = current_structured_attachments
      filtered = attachments.reject { |item| attachment_dedupe_key(item) == target_key }
      return false if filtered.length == attachments.length

      @structured_result = @structured_result.dup
      filtered.empty? ? @structured_result.delete("attachments") : @structured_result["attachments"] = filtered
      true
    end

    def awaiting_input?
      effective_status == "input_required"
    end

    def dispatch_inquiry_hook!
      return unless awaiting_input?

      inquiry = latest_inquiry
      return unless inquiry.is_a?(Hash)

      response = HQ.hooks.publish_blocking("agent.inquiry.available",
                                           agent_key: @key,
                                           project_key: @project_key,
                                           inquiry_message: inquiry["message"],
                                           inquiry_fields: inquiry["fields"],
                                           inquiry_requested_schema: inquiry["requested_schema"])
      return unless response.is_a?(Hash)

      answer = response["answer"].to_s.strip
      add_user_message!(answer) unless answer.empty?
    rescue StandardError => e
      HQ.logger.error("Agent") { "Inquiry hook failed for #{@key}: #{e.message}" }
    end

    def blocked?
      effective_status == "blocked"
    end

    def normalize_inquiry(value)
      result_normalizer.normalize_inquiry(value)
    end

    def inquiry_identity(inquiry, run: last_run)
      return nil unless inquiry.is_a?(Hash)

      payload = {
        "agent_key" => @key.to_s,
        "session_id" => @session_id.to_s,
        "run_count" => run_count,
        "run_started_at" => run&.started_at&.iso8601 || @started_at&.iso8601,
        "run_finished_at" => run&.finished_at&.iso8601 || @finished_at&.iso8601,
        "inquiry" => canonical_json_value(inquiry)
      }
      Digest::SHA256.hexdigest(JSON.generate(payload))[0, 32]
    end

    def normalize_attachments(value)
      result_normalizer.normalize_attachments(value)
    end

    def normalize_prompt_queue(value)
      Array(value).filter_map { |entry| normalize_prompt_queue_entry(entry) }
    end

    def normalize_prompt_queue_claim(value)
      return nil unless value.is_a?(Hash)

      id = value["id"].to_s.strip
      entries = normalize_prompt_queue(value["entries"])
      return nil if id.empty? || entries.empty?

      {
        "id" => id,
        "entries" => entries,
        "claimed_at" => value["claimed_at"].to_s,
        "baseline_run_count" => value["baseline_run_count"].to_i,
        "message_appended" => value["message_appended"] == true
      }
    end

    def normalize_prompt_queue_dispatch_error(value)
      return nil unless value.is_a?(Hash)

      message = value["message"].to_s.strip
      return nil if message.empty?

      {
        "message" => message,
        "failed_at" => value["failed_at"].to_s,
        "retryable" => value["retryable"] != false
      }
    end

    def normalize_prompt_queue_entry(value)
      return nil unless value.is_a?(Hash)

      id = value["id"].to_s.strip
      prompt = value["prompt"].to_s.strip
      return nil if id.empty? || prompt.empty?

      result = {
        "id" => id,
        "prompt" => prompt,
        "attachments" => normalize_attachments(value["attachments"]) || [],
        "accepted_at" => value["accepted_at"].to_s,
        "not_before" => value["not_before"].to_s.empty? ? nil : value["not_before"].to_s,
        "updated_at" => value["updated_at"].to_s.empty? ? nil : value["updated_at"].to_s,
        "client_request_id" => value["client_request_id"].to_s.empty? ? nil : value["client_request_id"].to_s
      }.compact
      authority = normalize_prompt_queue_authority(value["authority"])
      result["authority"] = authority if authority
      result["message_metadata"] = value["message_metadata"] if value["message_metadata"].is_a?(Hash)
      result["source"] = value["source"].to_s unless value["source"].to_s.empty?
      result
    end

    def prompt_entry_due?(entry, at)
      value = entry["not_before"].to_s
      return true if value.empty?

      Time.parse(value) <= at
    rescue ArgumentError, TypeError
      true
    end

    def next_prompt_queue_entry
      Array(@prompt_queue_claim&.fetch("entries", nil)).first ||
        Array(active_queue_work&.fetch("entries", nil)).first || @prompt_queue.first
    end

    def normalize_prompt_queue_authority(value)
      return nil unless value.is_a?(Hash)

      owner = value["owner"].to_s
      generation = value["generation"]
      relationship_id = value["relationship_id"].to_s
      return nil unless %w[parent user].include?(owner)
      return nil unless generation.is_a?(Integer) && generation.positive?
      return nil if relationship_id.empty?

      {
        "relationship_id" => relationship_id,
        "owner" => owner,
        "generation" => generation
      }
    end

    def normalize_attachment(value)
      result_normalizer.normalize_attachment(value)
    end

    def dedupe_attachments(attachments)
      result_normalizer.dedupe_attachments(attachments)
    end

    def attachment_dedupe_key(attachment)
      result_normalizer.attachment_dedupe_key(attachment)
    end

    def merge_inquiries(primary, secondary)
      result_normalizer.merge_inquiries(primary, secondary)
    end

    def result_normalizer
      @result_normalizer ||= AgentResultNormalizer.new(workspace: @workspace)
    end

    def seed_memory_from_initial_messages!(messages)
      items = Array(messages)
      return if items.empty?
      return if memory_store.exists?

      base_system_index = items.rindex do |message|
        candidate = message.is_a?(AgentMessage) ? message : AgentMessage.from_hash(message)
        candidate.role.to_s == "system"
      end
      items.each_with_index do |message, index|
        message = message.is_a?(AgentMessage) ? message : AgentMessage.from_hash(message)
        text = message.content.to_s
        next if text.strip.empty?

        created_at = message.created_at || @created_at || Time.now
        case message.role.to_s
        when "system"
          prompt_role = index == base_system_index ? "base" : "project_context"
          memory_store.append_system_prompt!(text, created_at: created_at, prompt_role:)
        when "user"
          attachments = message.metadata.is_a?(Hash) ? message.metadata["attachments"] : nil
          memory_store.append_user_message!(text, created_at: created_at, attachments:, metadata: message.metadata)
        when "assistant"
          memory_store.append_assistant_message!(text, created_at: created_at)
        end
      end
    rescue StandardError
      nil
    end

    def normalize_messages(messages)
      items = Array(messages)
      if items.empty? && !@prompt.to_s.empty?
        return [AgentMessage.new(role: "system", content: @prompt.to_s,
                                 created_at: @created_at)]
      end

      items.map do |message|
        message.is_a?(AgentMessage) ? message : AgentMessage.from_hash(message)
      end
    end

    def reset_base_prompt!
      if @messages.empty?
        @messages << AgentMessage.new(role: "system", content: @prompt.to_s, created_at: Time.now)
      elsif (index = @messages.rindex { |message| message.role == "system" })
        @messages[index] =
          AgentMessage.new(role: "system", content: @prompt.to_s, created_at: @messages[index].created_at || Time.now)
      else
        @messages.unshift(AgentMessage.new(role: "system", content: @prompt.to_s, created_at: Time.now))
      end
      trim_messages!
    end

    def composed_prompt
      messages = memory_store.prompt_messages
      if messages.empty? && !@prompt.to_s.empty?
        messages << { role: "system", content: @prompt.to_s }
      end
      messages.map do |message|
        "#{message[:role].to_s.upcase}:\n#{prompt_message_content(message)}"
      end.join("\n\n")
    end

    def prompt_message_content(message)
      content = message[:content].to_s
      metadata = message[:metadata]
      attachments = metadata.is_a?(Hash) ? normalize_attachments(metadata["attachments"]) : nil
      attachments ||= []
      return content if attachments.empty?

      lines = [
        content,
        "",
        "Attachments are available as files or links. Use the targets below when you need to inspect them:"
      ]
      attachments.each do |attachment|
        title = attachment["title"].to_s.strip
        target = AttachmentNormalizer.attachment_target(attachment)
        title = target if title.empty?
        type = attachment["type"].to_s.strip
        type = AttachmentNormalizer.link_attachment?(attachment) ? "link" : "file" if type.empty?
        detail = [type, title].reject(&:empty?).join(" ")
        lines << "- #{detail}: #{target}"
      end
      lines.join("\n")
    end

    def prompt_for_execution(response_style: resolved_response_style, include_hidden_guidance: true)
      claimed_prompt = if @prompt_queue_claim&.fetch("message_appended", false)
                         memory_store.user_message_with_metadata(
                           "prompt_queue_claim_id" => @prompt_queue_claim["id"]
                         )
                       end
      threshold = last_run&.finished_at || @finished_at || @started_at
      threshold = Time.at(threshold.to_i) if threshold
      base_prompt = if !claimed_prompt.to_s.strip.empty?
                      claimed_prompt
                    elsif !native_resume?
                      composed_prompt
                    else
                      latest = memory_store.latest_user_message_after(
                        threshold,
                        inclusive: true,
                        ignored_metadata: { "queue_read" => true }
                      )
                      latest.to_s.strip.empty? ? "Continue from the current HQ managed-agent state." : latest.to_s
                    end
      if (batch = active_queue_work)
        contract = QueueWork.contract(batch, agent_key: @key)
        base_prompt = [contract, base_prompt].join("\n\n") unless base_prompt.include?("[TYCHO QUEUE WORK CONTRACT — REQUIRED]")
      end
      with_execution_guidance(base_prompt, response_style:, include_hidden_guidance:)
    end

    def current_agent_system_context
      AgentSystemContext.render(
        agent_key: @key,
        parent: @delegation_parent,
        tycho_skill_installed: tycho_skill_installed?
      )
    end

    def tycho_skill_installed?
      SkillInstaller.new.status(harness_adapter).fetch(:status, nil) == "installed"
    rescue StandardError
      false
    end

    def with_execution_guidance(prompt, response_style: resolved_response_style, include_hidden_guidance: true)
      text = prompt.to_s.rstrip
      unless response_style.to_s.empty? || text.include?(response_style.to_s)
        text = [text, "RESPONSE STYLE:\n#{response_style}"].reject(&:empty?).join("\n\n")
      end
      if include_hidden_guidance && prompt_only_structured_output_agent? && !native_resume?
        guidance = prompt_only_structured_output_guidance
        text = [guidance, text].reject(&:empty?).join("\n\n") unless guidance.empty?
      end
      with_final_output_checklist(text)
    end

    def resolved_response_style
      ResponseStylePolicy.resolve(@response_style)
    end

    def response_style_source_for(resolved_style)
      return "disabled" if resolved_style.to_s.empty?
      return "custom" unless @response_style.nil?

      "global"
    end

    def native_resume?
      return false if @session_id.to_s.empty?
      return false unless %w[codex claude opencode pi].include?(harness_adapter)

      claude_like_agent? ? @session_bootstrapped : @runs.any?
    end

    def missing_native_session_identity?
      return false unless HQ::BUILTIN_HARNESSES.include?(harness_adapter)
      return false unless @session_id.to_s.empty?

      @runs.any? { |run| !run.metadata.to_h["start_failure"] && !run.metadata.to_h["spawn_error"] }
    end

    public :missing_native_session_identity?

    def claude_like_agent?
      harness_adapter == "claude"
    end

    def codex_agent?
      harness_adapter == "codex"
    end

    def opencode_agent?
      harness_adapter == "opencode"
    end

    def pi_agent?
      harness_adapter == "pi"
    end

    def prompt_only_structured_output_agent?
      opencode_agent? || pi_agent?
    end

    def harness_adapter
      HQ.harness_adapter(@agent)
    end

    def with_final_output_checklist(prompt)
      self.class.with_final_output_checklist(prompt)
    end

    def normalize_sandbox_mode(mode)
      value = mode.to_s.strip
      return "danger-full-access" if value.empty? || value == "none"

      value
    end

    def normalize_model(value)
      text = value.to_s.strip
      text.empty? ? nil : text
    end

    def normalize_schedule_key(value)
      text = value.to_s.strip
      text.empty? ? nil : text
    end

    def normalize_reasoning_effort(value)
      text = value.to_s.strip.downcase
      text.empty? ? nil : text
    end

    def normalize_response_style(value)
      return false if value == false

      text = value.to_s.strip
      text.empty? ? nil : text
    end

    def normalize_skills(value)
      Array(value).filter_map do |entry|
        next unless entry.is_a?(Hash)

        name = entry["name"].to_s.strip
        next if name.empty?

        { "name" => name, "path" => entry["path"].to_s }
      end
    end

    def normalize_agent(agent)
      value = agent.to_s.strip.downcase
      return "codex" if value.empty?

      value
    end

    def normalize_session_id(value)
      value.to_s.strip
    end

    def read_structured_result_payload_from_log
      if codex_agent? && @last_exit_code.to_i.zero? && File.file?(last_message_file_path)
        parsed = JSON.parse(File.read(last_message_file_path))
        normalized = AgentStructuredResult.normalize_payload(parsed)
        return normalized if normalized
      end

      AgentStructuredResult.from_log_lines(last_run_log_lines)
    rescue JSON::ParserError
      AgentStructuredResult.from_log_lines(last_run_log_lines)
    end

    # Reads the latest run from its persisted byte offset. Legacy runs fall
    # back to the most recent `=== […] start ===` segment.
    def last_run_log_lines
      return [] unless File.exist?(@log_path)

      offset_lines = run_log_lines_from_offset(last_run)
      return offset_lines unless offset_lines.nil?

      lines = LogFileReader.read_lines(@log_path, chomp: true)
      start_index = lines.rindex { |line| line.start_with?("=== [") }
      return [] unless start_index

      lines[(start_index + 1)..] || []
    rescue StandardError
      []
    end

    def native_harness_executable
      ExecutableResolver.command_for_tool(harness_adapter)
    end

    def codex_executable
      ExecutableResolver.command_for_tool("codex")
    end

    def claude_executable
      ExecutableResolver.command_for_tool("claude")
    end

    def opencode_executable
      ExecutableResolver.command_for_tool("opencode")
    end

    def pi_executable
      ExecutableResolver.command_for_tool("pi")
    end

    def result_schema_path
      AGENT_RESULT_SCHEMA
    end

    def canonical_result_schema_json
      return nil unless File.exist?(result_schema_path)

      JSON.generate(JSON.parse(File.read(result_schema_path)))
    rescue StandardError
      nil
    end

    def prompt_only_structured_output_guidance
      schema = canonical_result_schema_json.to_s
      return "" if schema.empty?

      [
        "TYCHO STRUCTURED OUTPUT:",
        "Return exactly one JSON object matching the schema below as your final response.",
        "Do not wrap the object in Markdown fences or add text before or after it.",
        schema
      ].join("\n")
    end

    def current_run_log_lines
      return [] unless @started_at && File.exist?(@log_path)

      offset_lines = run_log_lines_from_offset(last_run)
      return offset_lines unless offset_lines.nil?

      file_size = File.size(@log_path)
      marker = "=== [#{@started_at.strftime("%Y-%m-%d %H:%M:%S")}] start ==="
      max_bytes = 512 * 1024

      loop do
        lines = read_log_tail_lines(max_bytes:)
        start_index = lines.rindex(marker)
        return lines[(start_index + 1)..] || [] if start_index
        return [] if max_bytes >= file_size

        max_bytes = [max_bytes * 2, file_size].min
      end
    rescue StandardError
      []
    end

    def run_log_lines_from_offset(run)
      return nil unless run

      offset = run.log_start_offset
      return nil unless offset.is_a?(Integer) && offset >= 0
      return nil unless run.log_path.to_s.empty? || File.expand_path(run.log_path) == File.expand_path(@log_path)
      return nil if offset > File.size(@log_path)

      LogFileReader.read_lines_from_offset(@log_path, offset, chomp: true)
    end

    def read_log_tail_lines(max_bytes: 512 * 1024)
      LogFileReader.read_tail_window_lines(@log_path, max_bytes:, chomp: true)
    end

    def capture_run_memory!(run)
      lines = current_run_log_lines
      persist_stream_events!(run, lines)
      _conversation, system = Parser.parse_stream(lines, agent_type: @agent)
      usage_entries = system.select { |entry| entry.type == :usage }
      @cost_snapshot = AgentCostSnapshot.advance(agent: self, run:, usage_entries:)
      if @usage_metrics_store
        UsageMetrics.record_run(
          agent: self,
          run:,
          usage_entries:,
          metrics_store: @usage_metrics_store
        )
      end

      inquiry = current_structured_inquiry
      if inquiry
        memory_store.append_inquiry_request!(
          inquiry,
          created_at: run.finished_at || @finished_at || Time.now,
          inquiry_id: inquiry_identity(inquiry, run:)
        )
      end
      current_structured_attachments.each do |attachment|
        memory_store.append_attachment!(attachment, created_at: run.finished_at || @finished_at || Time.now)
      end
      memory_store.append_run_summary!(
        summary: @summary,
        status: effective_status,
        created_at: run.finished_at || @finished_at || Time.now,
        metadata: run_summary_metadata(run).merge("run_id" => durable_run_id(run)),
        event_id: "#{durable_run_id(run)}:run-summary"
      )
      HQ.hooks.publish("agent.memory.captured",
                       agent_key: @key,
                       project_key: @project_key,
                       status: effective_status.to_s)
    rescue StandardError => e
      HQ.logger.error("Agent") { "Memory capture failed for #{@key}: #{e.message}" }
    end

    def persist_stream_events!(run, lines)
      output_lines = Array(lines)
      marker_index = output_lines.rindex(PROCESS_OUTPUT_MARKER)
      output_lines = output_lines[(marker_index + 1)..] || [] if marker_index
      projector = AgentStreamProjector.new(
        memory_path:,
        agent_type: @agent,
        run_id: durable_run_id(run)
      )
      output_lines.each_with_index do |line, source_sequence|
        projector.project_line(
          line,
          source_sequence:,
          occurred_at: run.finished_at || @finished_at || Time.now
        )
      end
    end

    def durable_run_id(run)
      value = run&.run_id.to_s
      return value unless value.empty?

      seed = [@key, run&.started_at&.iso8601, run&.log_start_offset].join(":")
      Digest::SHA256.hexdigest(seed)[0, 24]
    end

    def run_summary_metadata(run)
      metadata = @structured_result.is_a?(Hash) ? @structured_result.dup : {}
      metadata["summary_fallback"] = true unless @structured_result.is_a?(Hash)
      attachments = current_structured_attachments
      attachments.empty? ? metadata.delete("attachments") : metadata["attachments"] = attachments
      metadata["run_number"] = run_count
      metadata["_stream_sequence"] = current_run_log_lines.length + 1
      metadata["cost_snapshot"] = @cost_snapshot if @cost_snapshot.is_a?(Hash) && !@cost_snapshot.empty?
      if run&.delegation_owner == "parent"
        metadata["notification_suppressed"] = true
        metadata["unread_suppressed"] = true
      end
      metadata
    end

    def capture_session_id!
      discovered = session_id_from_current_run
      return if discovered.to_s.empty?

      if claude_like_agent? && !@session_id.to_s.empty? && discovered != @session_id
        HQ.logger.warn("Agent") do
          "Ignoring session_id drift for #{@key}: kept=#{@session_id} emitted=#{discovered}"
        end
        return
      end

      @session_id = discovered
      @session_bootstrapped = true
      HQ.hooks.publish("agent.session.captured",
                       agent_key: @key,
                       project_key: @project_key,
                       session_id: @session_id.to_s)
    end

    def session_id_from_current_run
      current_run_log_lines.each do |line|
        stripped = line.to_s.strip
        next unless stripped.start_with?("{")

        event = JSON.parse(stripped)
        next if claude_like_agent? && event["type"] == "result" && event["is_error"]

        id = if codex_agent?
               event["thread_id"] || event["session_id"] || event["id"]
             elsif opencode_agent?
               event["session_id"] || event["sessionID"] || event["sessionId"] ||
                 event.dig("session", "id") || event.dig("session", "session_id") ||
                 (event["id"] if event["type"].to_s.include?("session"))
             elsif pi_agent?
               event["id"] if event["type"] == "session"
             else
               event["session_id"]
             end
        normalized = normalize_session_id(id)
        return normalized unless normalized.empty?
      rescue JSON::ParserError
        next
      end

      nil
    end

    def compact_system_summary(entry)
      Parser.compact_memory_summary(entry)
    end

    def canonical_json_value(value)
      case value
      when Hash
        value.keys.map(&:to_s).sort.each_with_object({}) do |key, result|
          result[key] = canonical_json_value(value[key])
        end
      when Array
        value.map { |item| canonical_json_value(item) }
      else
        value
      end
    end

    def memory_store
      @memory_store ||= AgentMemory.new(self)
    end

    def normalize_delegation_parent(value)
      return nil unless value.is_a?(Hash)

      server_id = value["server_id"].to_s.strip
      agent_key = value["agent_key"].to_s.strip
      return nil if server_id.empty? || agent_key.empty?

      value.each_with_object({}) do |(key, item), result|
        name = key.to_s
        next unless %w[server_id server_name agent_key name project_key run_id run_number native_session_id].include?(name)
        next if item.nil? || item.to_s.empty?

        result[name] = item
      end
    end
  end
end
