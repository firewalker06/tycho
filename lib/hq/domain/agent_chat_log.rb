# frozen_string_literal: true

require "json"
require "time"

require_relative "agent_memory"
require_relative "agent_cost_snapshot"
require_relative "../log_file_reader"
require_relative "../parser"

module HQ
  class AgentChatLog
    RebuildCostRun = Struct.new(:session_id, :finished_at, :agent, :model, keyword_init: true)
    RebuildCostAgent = Struct.new(:agent, :key, :model, :cost_snapshot, :runs, :finished_at, keyword_init: true) do
      def run_count
        runs.length
      end
    end

    def initialize(agent)
      @agent = agent
    end

    def chat_blocks
      memory = memory_chat_blocks
      live = live_run_chat_blocks
      memory + live
    rescue StandardError
      []
    end

    def chat_text
      conversation, chat_system, = projection_entries
      Parser.compose_chat(conversation, chat_system)
    rescue StandardError
      ""
    end

    def ensure_generated
      conversation, chat_system, system_log = projection_entries
      File.write(@agent.conversation_log_path, Parser.format_conversation(conversation))
      File.write(@agent.system_log_path, Parser.format_system(system_log))
    rescue StandardError
      nil
    end

    # Rebuild memory.jsonl from raw.log by re-parsing every
    # `=== [...] start ===` segment with the current per-tool formatters.
    # Returns the number of events written (or nil on failure).
    def rebuild_memory_from_raw_log!
      raw_path = @agent.raw_log_path
      return nil unless File.exist?(raw_path)

      runs = split_raw_log_into_runs(raw_path)
      return nil if runs.empty?

      events, cost_snapshot = build_events_from_runs(runs)
      memory = AgentMemory.new(@agent)
      existing_attachments = memory.attachments
      memory.write_events!(events)
      existing_attachments.each do |attachment|
        memory.append_attachment!(
          attachment,
          created_at: parse_time(attachment["created_at"]) || Time.now
        )
      end
      @agent.cost_snapshot = cost_snapshot if cost_snapshot
      @agent.reconcile_run_count!(runs.length)
      events.length
    rescue StandardError => e
      HQ.logger.error("AgentChatLog") { "Rebuild failed for #{@agent.key}: #{e.message}" } if defined?(HQ.logger)
      nil
    end

    def memory_missing_with_raw_log?
      !AgentMemory.new(@agent).exists? && File.exist?(@agent.raw_log_path)
    end

    private

    def memory_chat_blocks
      conversation, chat_system, = projection_entries_from_memory
      Parser.compose_chat_blocks(conversation, chat_system)
    rescue StandardError
      []
    end

    def live_run_chat_blocks
      return [] unless @agent.pid && !@agent.finished_at
      return [] if current_run_projected?

      raw_path = @agent.raw_log_path
      return [] unless File.exist?(raw_path)

      run_lines = current_run_lines(raw_path)
      return [] if run_lines.empty?

      conversation, system = Parser.parse_stream(run_lines, agent_type: @agent.agent)
      Parser.compose_chat_blocks(conversation, system)
    rescue StandardError
      []
    end

    def current_run_projected?
      run_id = @agent.runs.last&.run_id.to_s
      return false if run_id.empty?

      AgentMemory.new(@agent).events.any? { |event| event["run_id"].to_s == run_id }
    end

    def projection_entries
      memory = AgentMemory.new(@agent)
      if memory.exists?
        return projection_entries_from_memory
      end

      raw_path = @agent.raw_log_path
      return [[], [], []] unless File.exist?(raw_path)

      projection_entries_from_raw(raw_path)
    end

    def projection_entries_from_memory
      memory = AgentMemory.new(@agent)
      events = memory.events

      conversation = []
      chat_system = []
      system_log = []
      inquiry_responses = inquiry_response_metadata_by_signature(events)
      run_summary_number = 0

      events.each_with_index do |event, sequence|
        sequence = event["sequence"] || sequence
        timestamp = parse_time(event["created_at"])

        case event["type"]
        when "system_prompt"
          conversation << Parser::ConversationEntry.new(
            role: "system",
            content: event["content"].to_s,
            timestamp:,
            metadata: sequence_metadata(sequence)
          )
        when "user_message"
          metadata = message_metadata_for(event, sequence:)
          if (response_metadata = inquiry_responses[inquiry_response_signature(event)]&.shift)
            metadata = (metadata || {}).merge(response_metadata)
          end
          conversation << Parser::ConversationEntry.new(
            role: "user",
            content: event["content"].to_s,
            timestamp:,
            metadata:
          )
        when "assistant_message"
          conversation << Parser::ConversationEntry.new(
            role: "assistant",
            content: event["content"].to_s,
            timestamp:,
            metadata: message_metadata_for(event, sequence:)
          )
        when "tool_summary"
          entry = Parser::SystemEntry.new(
            type: :tool_call,
            content: event["content"].to_s,
            timestamp:,
            tool_name: tool_name_for(event),
            metadata: system_metadata_for(event, sequence:)
          )
          chat_system << entry
          system_log << entry
        when "token_usage"
          entry = Parser::SystemEntry.new(
            type: :usage,
            content: event["content"].to_s,
            timestamp:,
            tool_name: nil,
            metadata: merge_sequence_metadata(event["metadata"], sequence)
          )
          chat_system << entry
          system_log << entry
        when "validation_retry"
          entry = Parser::SystemEntry.new(
            type: :validation_retry,
            content: event["content"].to_s,
            timestamp:,
            tool_name: nil,
            metadata: merge_sequence_metadata(event["metadata"], sequence)
          )
          chat_system << entry
          system_log << entry
        when "delegation_event"
          entry = Parser::SystemEntry.new(
            type: :delegation_event,
            content: event["content"].to_s,
            timestamp:,
            tool_name: nil,
            metadata: merge_sequence_metadata(event["metadata"], sequence)
          )
          chat_system << entry
          system_log << entry
        when "run_summary"
          run_summary_number += 1
          entry = Parser::SystemEntry.new(
            type: :run_summary,
            content: event["content"].to_s,
            timestamp:,
            tool_name: nil,
            metadata: run_summary_metadata_for(event, sequence:, run_number: run_summary_number)
          )
          chat_system << entry
          system_log << entry
        when "inquiry_request"
          system_log << Parser::SystemEntry.new(
            type: :inquiry,
            content: event["content"].to_s,
            timestamp:,
            tool_name: nil,
            metadata: inquiry_metadata_for(event)
          )
        when "inquiry_response"
          system_log << Parser::SystemEntry.new(
            type: :inquiry_response,
            content: event["content"].to_s,
            timestamp:,
            tool_name: nil,
            metadata: response_metadata_for(event)
          )
        end
      end

      [conversation, chat_system, system_log]
    end

    def projection_entries_from_raw(raw_path)
      run_lines = current_run_lines(raw_path)
      conversation, system = Parser.parse_run(run_lines, agent_type: @agent.agent)
      [conversation, system, system]
    end

    def current_run_lines(raw_path)
      lines = LogFileReader.read_lines(raw_path, chomp: true)
      start_index = lines.rindex { |line| line.start_with?("=== [") }
      return lines unless start_index

      lines[(start_index + 1)..] || []
    end

    def tool_name_for(event)
      metadata = event["metadata"]
      return nil unless metadata.is_a?(Hash)

      metadata["tool_name"].to_s.empty? ? metadata.dig("details", "tool_name") : metadata["tool_name"]
    end

    def system_metadata_for(event, sequence: nil)
      metadata = event["metadata"]
      return sequence_metadata(sequence) unless metadata.is_a?(Hash)

      details = metadata["details"]
      selected = details.is_a?(Hash) && !details.empty? ? details : metadata
      merge_sequence_metadata(selected, sequence)
    end

    def inquiry_metadata_for(event)
      metadata = event["metadata"]
      inquiry = metadata.is_a?(Hash) ? metadata["inquiry"] : nil
      return nil unless inquiry.is_a?(Hash)

      fields = inquiry.dig("requested_schema", "properties")
      field_names = fields.is_a?(Hash) ? fields.keys : nil
      field_names&.any? ? { "fields" => field_names } : nil
    end

    def response_metadata_for(event)
      metadata = event["metadata"]
      response = metadata.is_a?(Hash) ? metadata["response"] : nil
      return nil unless response.is_a?(Hash)

      result = { "inquiry_response" => true, "fields" => response.keys }
      id = inquiry_id_for_event(event)
      result["inquiry_id"] = id if id
      result
    end

    def inquiry_response_metadata_by_signature(events)
      events.each_with_object({}) do |event, result|
        next unless event["type"] == "inquiry_response"

        metadata = response_metadata_for(event)
        next unless metadata

        key = inquiry_response_signature(event)
        result[key] ||= []
        result[key] << metadata
      end
    end

    def inquiry_response_signature(event)
      [event["created_at"].to_s, event["content"].to_s]
    end

    def inquiry_id_for_event(event)
      metadata = event["metadata"]
      return nil unless metadata.is_a?(Hash)

      id = metadata["inquiry_id"].to_s.strip
      id.empty? ? nil : id
    end

    def run_summary_metadata_for(event, sequence: nil, run_number: nil)
      metadata = event["metadata"].is_a?(Hash) ? event["metadata"].dup : {}
      status = event["status"].to_s.strip
      metadata["status"] = status unless status.empty?
      metadata["run_number"] ||= run_number unless run_number.nil?
      metadata["summary_id"] ||= summary_id_for(event, sequence)
      merge_sequence_metadata(metadata, sequence)
    end

    def message_metadata_for(event, sequence: nil)
      metadata = event["metadata"]
      return sequence_metadata(sequence) unless metadata.is_a?(Hash) && !metadata.empty?

      merge_sequence_metadata(metadata, sequence)
    end

    def summary_id_for(event, sequence)
      base = [
        "summary",
        event["created_at"].to_s.gsub(/[^0-9A-Za-z]+/, "-").sub(/\A-+|-+\z/, ""),
        sequence
      ].compact.join("-")
      base.empty? ? "summary-#{sequence}" : base
    end

    def merge_sequence_metadata(metadata, sequence)
      result = metadata.is_a?(Hash) ? metadata.dup : {}
      return nil if result.empty? && sequence.nil?

      result["_sequence"] = sequence unless sequence.nil?
      result
    end

    def sequence_metadata(sequence)
      merge_sequence_metadata(nil, sequence)
    end

    def parse_time(value)
      return nil if value.to_s.empty?

      Time.parse(value.to_s)
    rescue StandardError
      nil
    end

    REBUILD_START_RE = /\A=== \[(?<ts>\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})\] start ===/

    def split_raw_log_into_runs(raw_path)
      runs = []
      current = nil
      LogFileReader.foreach_line(raw_path) do |line|
        if (match = line.match(REBUILD_START_RE))
          runs << current if current
          current = { started_at: Time.parse(match[:ts]), lines: [] }
        elsif current
          current[:lines] << line
        end
      end
      runs << current if current
      runs
    end

    def build_events_from_runs(runs)
      events = []
      seen_system_prompts = {}
      cost_agent = RebuildCostAgent.new(
        agent: @agent.agent,
        key: @agent.key,
        model: @agent.model,
        cost_snapshot: nil,
        runs: [],
        finished_at: @agent.finished_at
      )

      runs.each_with_index do |run, run_index|
        stored_run = stored_run_for_rebuild(run_index, runs.length)
        cursor = run[:started_at]
        conversation, system = Parser.parse_run(run[:lines], agent_type: @agent.agent)

        conversation.each do |entry|
          cursor += 1
          case entry.role.to_s
          when "system"
            next if seen_system_prompts[entry.content]

            seen_system_prompts[entry.content] = true
            events << {
              "type" => "system_prompt",
              "content" => entry.content.to_s,
              "created_at" => cursor.iso8601,
              "pinned" => true
            }
          when "user"
            events << {
              "type" => "user_message",
              "content" => entry.content.to_s,
              "created_at" => cursor.iso8601
            }
          when "assistant"
            events << {
              "type" => "assistant_message",
              "content" => entry.content.to_s,
              "created_at" => cursor.iso8601,
              "metadata" => entry.metadata.is_a?(Hash) ? entry.metadata : nil
            }.compact
          end
        end

        usage_entries = system.select { |entry| entry.type == :usage }
        system.each do |entry|
          cursor += 1
          if entry.type == :validation_retry
            events << {
              "type" => "validation_retry",
              "content" => entry.content.to_s,
              "created_at" => cursor.iso8601,
              "metadata" => entry.metadata.is_a?(Hash) ? entry.metadata : nil
            }.compact
            next
          end

          if entry.type == :usage
            events << {
              "type" => "token_usage",
              "content" => entry.content.to_s,
              "created_at" => cursor.iso8601,
              "metadata" => entry.metadata.is_a?(Hash) ? entry.metadata : nil
            }.compact
            next
          end

          summary = compact_rebuild_summary(entry)
          next if summary.nil?

          metadata = if entry.metadata.is_a?(Hash)
                       entry.metadata.merge("type" => entry.type.to_s)
                     else
                       { "type" => entry.type.to_s }
                     end

          events << {
            "type" => "tool_summary",
            "content" => summary,
            "created_at" => cursor.iso8601,
            "metadata" => { "tool_name" => entry.tool_name.to_s, "details" => metadata }
          }
        end

        completed_at = cursor + 1
        cost_run = RebuildCostRun.new(
          session_id: rebuild_session_id(run[:lines]),
          finished_at: completed_at,
          agent: stored_run&.agent || @agent.agent,
          model: stored_run&.model
        )
        cost_agent.runs << cost_run
        cost_agent.finished_at = completed_at
        cost_agent.cost_snapshot = AgentCostSnapshot.advance(
          agent: cost_agent,
          run: cost_run,
          usage_entries: usage_entries
        )

        events << {
          "type" => "run_summary",
          "content" => "(rebuilt from raw.log run ##{run_index + 1})",
          "status" => "success",
          "created_at" => completed_at.iso8601,
          "metadata" => {
            "run_number" => run_index + 1,
            "cost_snapshot" => cost_agent.cost_snapshot
          }
        }
      end

      [events, cost_agent.cost_snapshot]
    end

    def stored_run_for_rebuild(index, raw_run_count)
      offset = raw_run_count - @agent.runs.length
      stored_index = index - offset
      return nil if stored_index.negative?

      @agent.runs[stored_index]
    end

    def rebuild_session_id(lines)
      Array(lines).each do |line|
        value = line.to_s[/\Asession_id=(.+)\z/, 1].to_s.strip
        return value unless value.empty?

        stripped = line.to_s.strip
        next unless stripped.start_with?("{")

        event = JSON.parse(stripped)
        id = event["thread_id"] || event["session_id"] || event["sessionID"] || event["sessionId"] ||
             event.dig("session", "id")
        return id.to_s unless id.to_s.empty?
      rescue JSON::ParserError
        next
      end
      ""
    end

    def compact_rebuild_summary(entry)
      Parser.compact_memory_summary(entry)
    end
  end
end
