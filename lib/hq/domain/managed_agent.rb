# frozen_string_literal: true

require_relative "constants"
require_relative "log_paths"
require_relative "attachment_normalizer"
require_relative "agent_command_builder"
require_relative "agent_memory"
require_relative "agent_result_normalizer"
require_relative "agent_structured_result"
require_relative "executable_resolver"
require_relative "harness_version"
require_relative "../harness_registry"
require_relative "../parser"
require_relative "agent_chat_log"
require_relative "process_liveness"
require "digest"
require "securerandom"
require "shellwords"

module HQ
  class ManagedAgent
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
      :started_at, :finished_at, :exit_code, :status, :log_path, :command,
      :harness, :harness_adapter, :harness_version, :harness_raw_version, :harness_version_checked_at,
      :harness_version_command, :harness_executable_path, :harness_executable_source,
      keyword_init: true
    ) do
      def self.from_hash(hash)
        new(
          started_at: ManagedAgent.parse_time(hash["started_at"]),
          finished_at: ManagedAgent.parse_time(hash["finished_at"]),
          exit_code: hash["exit_code"],
          status: hash["status"],
          log_path: hash["log_path"],
          command: hash["command"],
          harness: hash["harness"],
          harness_adapter: hash["harness_adapter"],
          harness_version: hash["harness_version"],
          harness_raw_version: hash["harness_raw_version"],
          harness_version_checked_at: ManagedAgent.parse_time(hash["harness_version_checked_at"]),
          harness_version_command: hash["harness_version_command"],
          harness_executable_path: hash["harness_executable_path"],
          harness_executable_source: hash["harness_executable_source"]
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
        result["harness"] = harness unless harness.to_s.empty?
        result["harness_adapter"] = harness_adapter unless harness_adapter.to_s.empty?
        result["harness_version"] = harness_version unless harness_version.to_s.empty?
        result["harness_raw_version"] = harness_raw_version unless harness_raw_version.to_s.empty?
        unless harness_version_checked_at.nil?
          result["harness_version_checked_at"] = harness_version_checked_at.iso8601
        end
        result["harness_version_command"] = harness_version_command unless harness_version_command.to_s.empty?
        result["harness_executable_path"] = harness_executable_path unless harness_executable_path.to_s.empty?
        result["harness_executable_source"] = harness_executable_source unless harness_executable_source.to_s.empty?
        result
      end
    end

    FINAL_OUTPUT_CHECKLIST = "For `summary`, write a concise operator-facing Markdown summary of the outcome, " \
                             "key changes or findings, blockers, and next steps in 1-3 short paragraphs or bullets. " \
                             "Before final structured output, check whether this run created or referenced a PR, " \
                             "plan, review, report, markdown file, image, or other durable artifact. " \
                             "If yes, include it in `attachments`: use `type: file` with `path` for local files, " \
                             "or `type: link` with an http(s) `url` for web links."

    def self.with_final_output_checklist(prompt)
      text = prompt.to_s.rstrip
      return FINAL_OUTPUT_CHECKLIST if text.empty?
      return text if text.include?(FINAL_OUTPUT_CHECKLIST)

      "#{text}\n\n#{FINAL_OUTPUT_CHECKLIST}"
    end

    attr_reader :key, :name, :project_key, :template_key, :workspace, :prompt, :created_at, :started_at,
                :finished_at, :pid, :last_exit_code, :log_path, :runs, :sandbox_mode, :agent, :messages, :skills,
                :model, :reasoning_effort, :session_id, :session_bootstrapped, :color_index, :summary,
                :structured_result
    attr_writer :summary, :structured_result

    def initialize(key:, name:, project_key:, template_key:, workspace:, prompt:, created_at: nil, started_at: nil,
                   finished_at: nil, pid: nil, last_exit_code: nil, log_path: nil, runs: nil,
                   stop_requested_at: nil, sandbox_mode: "danger-full-access", agent: "codex", messages: nil,
                   model: nil, reasoning_effort: nil, skills: nil, unread: false, session_id: nil,
                   session_bootstrapped: nil, color_index: nil, summary: nil, structured_result: nil)
      @key = key
      @name = name
      @project_key = project_key
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
      @messages = normalize_messages(messages)
      seed_memory_from_initial_messages!(messages)
      @skills = normalize_skills(skills)
      @unread = unread ? true : false
      @session_id = normalize_session_id(session_id)
      @session_bootstrapped = !@session_id.empty? && session_bootstrapped != false
      @color_index = color_index.is_a?(Integer) ? color_index : nil
      @structured_result = structured_result.is_a?(Hash) ? structured_result : nil
      @summary = summary.is_a?(String) && !summary.empty? ? summary : nil
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
      memory_store.prepend_system_prompt_once!(text, created_at:)
      true
    end

    def self.from_hash(hash)
      runs = Array(hash["runs"]).map { |run| AgentRun.from_hash(run) }
      launch_settings = launch_settings_from_runs(runs)
      model = hash["model"].to_s.strip.empty? ? launch_settings[:model] : hash["model"]
      reasoning_effort = if hash["reasoning_effort"].to_s.strip.empty?
                           launch_settings[:reasoning_effort]
                         else
                           hash["reasoning_effort"]
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
        skills: hash["skills"],
        unread: hash["unread"],
        session_id: hash["session_id"],
        session_bootstrapped: hash["session_bootstrapped"],
        color_index: hash["color_index"],
        summary: hash["summary"],
        structured_result: hash["structured_result"]
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
        "stop_requested_at" => @stop_requested_at&.iso8601,
        "sandbox_mode" => @sandbox_mode,
        "agent" => @agent,
        "skills" => @skills,
        "unread" => @unread
      }
      result["model"] = @model unless @model.to_s.empty?
      result["reasoning_effort"] = @reasoning_effort unless @reasoning_effort.to_s.empty?
      unless @session_id.to_s.empty?
        result["session_id"] = @session_id
        result["session_bootstrapped"] = @session_bootstrapped
      end
      result["color_index"] = @color_index unless @color_index.nil?
      result["summary"] = @summary unless @summary.to_s.empty?
      result["structured_result"] = @structured_result if @structured_result.is_a?(Hash) && !@structured_result.empty?
      result
    end

    def unread?
      @unread
    end

    def mark_unread!
      @unread = true
    end

    def mark_read!
      @unread = false
    end

    def start!
      return if running?

      finalize_previous_run!
      reconcile_session_bootstrap!
      if claude_like_agent? && @session_id.to_s.empty?
        @session_id = SecureRandom.uuid
        @session_bootstrapped = false
      end
      execution = build_command
      command = execution.fetch(:command)
      environment = execution.fetch(:env, {})
      version_snapshot = harness_version_snapshot
      if (missing = missing_executable_for(command))
        return record_start_failure!(
          "Agent harness #{@agent.inspect} executable not found: #{missing}",
          command,
          version_snapshot
        )
      end

      @started_at = Time.now
      @finished_at = nil
      @last_exit_code = nil
      @stop_requested_at = nil
      mark_read!
      status_path = status_file_path
      FileUtils.rm_f(status_path)
      FileUtils.rm_f(last_message_file_path)
      invalidate_derived_logs!
      prompt_text = prompt_for_execution

      File.open(@log_path, "a") do |file|
        file.puts
        file.puts "=== [#{@started_at.strftime("%Y-%m-%d %H:%M:%S")}] start ==="
        file.puts "workspace=#{@workspace}"
        file.puts "session_id=#{@session_id}" unless @session_id.to_s.empty?
        file.puts "prompt=#{prompt_text}"
        file.puts
      end

      log_file = File.open(@log_path, "a")
      @pid = spawn(
        environment.merge("TYCHO_STATUS_PATH" => status_path),
        RbConfig.ruby, "-e", agent_runner_script, *command,
        chdir: @workspace, out: log_file, err: %i[child out], pgroup: true
      )
      log_file.close
      Process.detach(@pid)
      HQ.logger.info("Agent") { "Started #{@key} (pid=#{@pid})" }
      @runs << AgentRun.new(
        started_at: @started_at,
        status: "running",
        log_path: @log_path,
        command: Shellwords.join(command),
        **version_snapshot.run_fields.transform_keys(&:to_sym)
      )
      @structured_result = nil
      @summary = nil
      trim_runs!
      HQ.hooks.publish("agent.run.started",
                       agent_key: @key,
                       project_key: @project_key,
                       workspace: @workspace,
                       session_id: @session_id.to_s,
                       pid: @pid)
      true
    end

    def stop!
      return unless running?

      @stop_requested_at = Time.now
      Process.kill("TERM", -@pid)
      HQ.logger.info("Agent") { "Stopped #{@key}" }
    rescue Errno::ESRCH, Errno::EPERM
      HQ.logger.warn("Agent") { "Failed to stop #{@key}: process not found or permission denied" }
      clear_foreign_pid!
    end

    def retire_for_archive!(timeout: 1.0)
      if running?
        @stop_requested_at ||= Time.now
        signal_process_group("TERM")
        wait_until_not_running(timeout)
        if running?
          signal_process_group("KILL")
          wait_until_not_running(0.5)
        end
      end

      finalize_retired_run!
    end

    def poll!
      return unless @pid
      return if running?

      @finished_at ||= Time.now
      @last_exit_code = read_exit_code
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
      return false unless ProcessLiveness.alive?(@pid)

      own_process_group?(@pid)
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
      return "succeeded" if @last_exit_code.zero?
      return "stopped" if stopped_exit_code?

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
        status_file_path,
        last_message_file_path,
        legacy_status_file_path,
        legacy_last_message_file_path
      ].uniq
    end

    def archive_logs!(root = AGENT_ARCHIVE_DIR)
      present = log_files.select { |path| File.exist?(path) }
      return nil if present.empty?

      destination = LogPaths.agent_archive_destination(root, @key)
      FileUtils.mkdir_p(destination)
      present.each do |path|
        FileUtils.mv(path, File.join(destination, File.basename(path)))
      end
      destination
    end

    def interactive_command
      command_builder.interactive
    end

    def claude_command_prefix
      custom = HQ.custom_harness(@agent)
      return custom.resolved_command_parts if custom

      [claude_executable]
    end

    def update!(name:, template_key:, workspace:, prompt:, sandbox_mode: @sandbox_mode, agent: @agent,
                model: @model, reasoning_effort: @reasoning_effort)
      @name = name
      @template_key = template_key
      @workspace = workspace
      @prompt = prompt
      @sandbox_mode = normalize_sandbox_mode(sandbox_mode)
      @agent = normalize_agent(agent)
      @model = normalize_model(model)
      @reasoning_effort = normalize_reasoning_effort(reasoning_effort)
      reset_base_prompt!
      memory_store.append_system_prompt!(@prompt, created_at: Time.now)
      HQ.hooks.publish("agent.updated",
                       agent_key: @key,
                       project_key: @project_key,
                       name: @name,
                       template_key: @template_key,
                       workspace: @workspace,
                       agent: @agent,
                       model: @model,
                       reasoning_effort: @reasoning_effort)
    end

    def add_user_message!(content, inquiry_id: nil, attachments: nil, metadata: nil)
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
                                        metadata: memory_metadata)
      memory_store.append_inquiry_response!(text, created_at:, inquiry_id: resolved_inquiry_id) if inquiry
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
      @runs.length
    end

    def last_run
      @runs.last
    end

    def last_result_label
      return "never run" unless last_run

      case effective_status
      when "running" then "in progress"
      when "success", "succeeded" then "success"
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
      return "No runs yet" unless last_run

      structured_summary || inquiry_message || @summary || "No runs yet"
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

    def derived_log_path(suffix)
      LogPaths.derived_agent_log_path(@log_path, suffix)
    end

    def command_builder(prompt: prompt_for_execution)
      AgentCommandBuilder.new(
        agent: @agent,
        harness_adapter: harness_adapter,
        workspace: @workspace,
        sandbox_mode: @sandbox_mode,
        model: @model,
        reasoning_effort: @reasoning_effort,
        session_id: @session_id,
        session_bootstrapped: @session_bootstrapped,
        prompt: prompt,
        codex_executable: codex_executable,
        claude_command_prefix: claude_command_prefix,
        last_message_file_path: last_message_file_path,
        result_schema_path: AGENT_RESULT_SCHEMA,
        claude_result_schema: compact_claude_result_schema
      )
    end

    def build_command
      command_builder.build
    end

    def harness_version_snapshot
      HarnessVersion.for_agent(@agent)
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

    def record_start_failure!(message, command, version_snapshot)
      @started_at = Time.now
      @finished_at = @started_at
      @last_exit_code = 127
      @stop_requested_at = nil
      @pid = nil
      mark_read!
      FileUtils.rm_f(status_file_path)
      FileUtils.rm_f(last_message_file_path)
      invalidate_derived_logs!

      File.open(@log_path, "a") do |file|
        file.puts
        file.puts "=== [#{@started_at.strftime("%Y-%m-%d %H:%M:%S")}] start failed ==="
        file.puts "workspace=#{@workspace}"
        file.puts "session_id=#{@session_id}" unless @session_id.to_s.empty?
        file.puts "command=#{Shellwords.join(command)}"
        file.puts "error=#{message}"
        file.puts
      end

      @runs << AgentRun.new(
        started_at: @started_at,
        finished_at: @finished_at,
        exit_code: @last_exit_code,
        status: "failed",
        log_path: @log_path,
        command: Shellwords.join(command),
        **version_snapshot.run_fields.transform_keys(&:to_sym)
      )
      @structured_result = nil
      @summary = message
      trim_runs!
      HQ.logger.warn("Agent") { "Failed to start #{@key}: #{message}" }
      false
    end

    def claude_session_arguments
      command_builder(prompt: "").claude_session_arguments
    end

    def status_file_path
      derived_log_path("status")
    end

    def status_file_paths
      [status_file_path, legacy_status_file_path].uniq
    end

    def legacy_status_file_path
      File.join(AGENT_LOGS_DIR, "#{@key}.status")
    end

    def agent_runner_script
      <<~RUBY
        status = begin
          result = system(*ARGV)
          child = $?
          if result.nil?
            warn "failed to execute \#{ARGV.first.inspect} (exit 127)"
            127
          else
            child ? child.exitstatus.to_i : (result ? 0 : 1)
          end
        rescue SystemCallError => e
          warn e.message
          127
        rescue StandardError => e
          warn e.message
          1
        end
        begin
          File.write(ENV.fetch("TYCHO_STATUS_PATH"), status.to_s)
        rescue StandardError
          nil
        end
        exit(status)
      RUBY
    end

    def last_message_file_path
      derived_log_path("last_message.json")
    end

    def legacy_last_message_file_path
      File.join(AGENT_LOGS_DIR, "#{@key}.last_message.json")
    end

    def read_exit_code
      path = status_file_paths.find { |candidate| File.exist?(candidate) }
      return nil unless path

      File.read(path).strip.to_i
    rescue StandardError
      nil
    ensure
      FileUtils.rm_f(path) if path
    end

    def finalize_latest_run!
      run = @runs.last
      return unless run
      return unless run.status == "running"

      run.finished_at = @finished_at
      run.exit_code = @last_exit_code
      run.status = status
      capture_session_id!
      build_summary!
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

      log_summary = summarize_from_log
      return log_summary unless log_summary.to_s.empty?

      case status
      when "succeeded" then "Completed successfully"
      when "stopped" then "Stopped by user"
      when "failed"
        code = @last_exit_code.nil? ? "unknown" : @last_exit_code
        "Exited with code #{code}"
      else
        "Run finished"
      end
    end

    def normalize_structured_result(parsed)
      result_normalizer.normalize_structured_result(parsed)
    rescue StandardError => e
      HQ.logger.warn("Agent") { "Failed to normalize result for #{@key}: #{e.message}" }
      nil
    end

    def summarize_from_log
      return nil unless File.exist?(@log_path)

      tail = File.readlines(@log_path).last(60).map(&:strip)
      relevant = tail.reject do |line|
        line.empty? ||
          line.start_with?("===") ||
          line.start_with?("workspace=") ||
          line.start_with?("prompt=")
      end
      return nil if relevant.empty?

      relevant.reverse_each do |line|
        event = parse_json_line(line)
        next unless event.is_a?(Hash)

        message = error_summary_from_event(event)
        return truncate_log_summary(message) unless message.to_s.empty?
      end

      relevant.reverse_each do |line|
        event = parse_json_line(line)
        if event.is_a?(Hash)
          message = assistant_summary_from_event(event)
          return truncate_log_summary(message) unless message.to_s.empty?
        elsif !line.start_with?("{")
          return truncate_log_summary(line)
        end
      end

      nil
    rescue StandardError
      nil
    end

    def parse_json_line(line)
      JSON.parse(line)
    rescue JSON::ParserError
      nil
    end

    def error_summary_from_event(event)
      case event["type"]
      when "error"
        event["message"].to_s.strip
      when "turn.failed"
        error = event["error"]
        error.is_a?(Hash) ? error["message"].to_s.strip : error.to_s.strip
      else
        ""
      end
    end

    def assistant_summary_from_event(event)
      case event["type"]
      when "item.completed"
        item = event["item"]
        return "" unless item.is_a?(Hash) && item["type"] == "agent_message"

        Parser.assistant_display_text(item["text"].to_s.strip).to_s.strip
      when "assistant"
        Array(event.dig("message", "content")).filter_map do |item|
          next unless item.is_a?(Hash) && item["type"] == "text"

          item["text"].to_s.strip
        end.join("\n").strip
      else
        ""
      end
    end

    def truncate_log_summary(text, limit = 180)
      value = text.to_s.gsub(/\s+/, " ").strip
      return nil if value.empty?

      value.length > limit ? "#{value[0, limit - 3]}..." : value
    end

    def stopped_exit_code?
      return true if [128 + Signal.list["TERM"].to_i, 143].include?(@last_exit_code)

      @stop_requested_at && @last_exit_code.to_i.positive?
    end

    def signal_process_group(signal)
      Process.kill(signal, -@pid)
    rescue Errno::ESRCH, Errno::EPERM
      clear_foreign_pid!
    end

    def wait_until_not_running(timeout)
      deadline = Time.now + timeout.to_f
      while running? && Time.now < deadline
        sleep 0.05
      end
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
      normalize_attachments(@structured_result&.dig("attachments")) || []
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

      items.each do |message|
        message = message.is_a?(AgentMessage) ? message : AgentMessage.from_hash(message)
        text = message.content.to_s
        next if text.strip.empty?

        created_at = message.created_at || @created_at || Time.now
        case message.role.to_s
        when "system"
          memory_store.append_system_prompt!(text, created_at: created_at)
        when "user"
          attachments = message.metadata.is_a?(Hash) ? message.metadata["attachments"] : nil
          memory_store.append_user_message!(text, created_at: created_at, attachments:)
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

    def prompt_for_execution
      return with_final_output_checklist(composed_prompt) unless native_resume?

      threshold = last_run&.finished_at || @finished_at || @started_at
      latest = memory_store.latest_user_message_after(threshold)
      prompt = latest.to_s.strip.empty? ? "Continue from the current HQ managed-agent state." : latest.to_s
      with_final_output_checklist(prompt)
    end

    def native_resume?
      return false if @session_id.to_s.empty?
      return false unless %w[codex claude].include?(harness_adapter)

      claude_like_agent? ? @session_bootstrapped : @runs.any?
    end

    def claude_like_agent?
      harness_adapter == "claude"
    end

    def codex_agent?
      harness_adapter == "codex"
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

    def normalize_reasoning_effort(value)
      text = value.to_s.strip.downcase
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
      AgentStructuredResult.from_log_lines(last_run_log_lines)
    end

    # Walks raw.log to extract the lines belonging to the most recent
    # `=== […] start ===` segment. Independent of @started_at so it works
    # for agents loaded from disk after a restart.
    def last_run_log_lines
      return [] unless File.exist?(@log_path)

      lines = File.readlines(@log_path, chomp: true)
      start_index = lines.rindex { |line| line.start_with?("=== [") }
      return [] unless start_index

      lines[(start_index + 1)..] || []
    rescue StandardError
      []
    end

    def codex_executable
      ExecutableResolver.command_for_tool("codex")
    end

    def claude_executable
      ExecutableResolver.command_for_tool("claude")
    end

    def compact_claude_result_schema
      return nil unless File.exist?(AGENT_RESULT_SCHEMA)

      JSON.generate(claude_result_schema(JSON.parse(File.read(AGENT_RESULT_SCHEMA))))
    rescue StandardError
      nil
    end

    def claude_result_schema(canonical_schema)
      properties = canonical_schema.fetch("properties", {})
      {
        "type" => "object",
        "additionalProperties" => false,
        "properties" => {
          "status" => properties.fetch("status", { "type" => "string" }),
          "summary" => properties.fetch("summary", { "type" => "string" }),
          "inquiry_json" => {
            "type" => "string",
            "description" => "JSON-encoded inquiry object, or the literal string null when no inquiry is needed."
          },
          "attachments_json" => {
            "type" => "string",
            "description" => "JSON-encoded attachments array, or the literal string null when no attachments are needed."
          }
        },
        "required" => ["status", "summary", "inquiry_json", "attachments_json"]
      }
    end

    def current_run_log_lines
      return [] unless @started_at && File.exist?(@log_path)

      marker = "=== [#{@started_at.strftime("%Y-%m-%d %H:%M:%S")}] start ==="
      lines = read_log_tail_lines
      start_index = lines.rindex(marker)
      return [] unless start_index

      lines[(start_index + 1)..] || []
    rescue StandardError
      []
    end

    def read_log_tail_lines
      File.open(@log_path, "r") do |file|
        window = [file.size, 512 * 1024].min
        file.seek(-window, IO::SEEK_END) if window.positive?
        file.read.to_s.lines(chomp: true)
      end
    end

    def capture_run_memory!(run)
      conversation, system = Parser.parse_stream(current_run_log_lines, agent_type: @agent)

      conversation.each do |entry|
        next unless entry.role == "assistant"

        memory_store.append_assistant_message!(entry.content, created_at: entry.timestamp || @finished_at || Time.now)
      end

      system.each do |entry|
        if entry.type == :usage
          memory_store.append_token_usage!(
            entry.content,
            created_at: entry.timestamp || @finished_at || Time.now,
            metadata: entry.metadata
          )
          next
        end

        summary = compact_system_summary(entry)
        next if summary.nil?

        metadata = if entry.metadata.is_a?(Hash)
                     entry.metadata.merge("type" => entry.type.to_s)
                   else
                     { "type" => entry.type.to_s }
                   end
        memory_store.append_tool_summary!(
          summary,
          tool_name: entry.tool_name,
          created_at: entry.timestamp || @finished_at || Time.now,
          metadata:
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
        metadata: @structured_result
      )
      HQ.hooks.publish("agent.memory.captured",
                       agent_key: @key,
                       project_key: @project_key,
                       status: effective_status.to_s)
    rescue StandardError => e
      HQ.logger.error("Agent") { "Memory capture failed for #{@key}: #{e.message}" }
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
      case entry.type
      when :tool_call
        first_line = entry.content.to_s.lines.map(&:strip).find { |line| !line.empty? }
        label = entry.tool_name.to_s.strip
        summary = if label.empty?
                    first_line
                  elsif first_line && first_line != label
                    "#{label}: #{first_line}"
                  else
                    label
                  end
        truncate_memory_text(summary)
      when :tool_result
        first_line = entry.content.to_s.lines.map(&:strip).find { |line| !line.empty? }
        truncate_memory_text(first_line ? "tool result: #{first_line}" : nil)
      end
    end

    def truncate_memory_text(text, limit = 200)
      value = text.to_s.strip
      return nil if value.empty?

      value.length > limit ? "#{value[0, limit - 3]}..." : value
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
  end
end
