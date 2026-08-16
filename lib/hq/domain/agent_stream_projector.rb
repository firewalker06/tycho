# frozen_string_literal: true

require "json"
require "time"

require_relative "agent_event_journal"
require_relative "../parser"

module HQ
  class AgentStreamProjector
    def initialize(memory_path:, agent_type:, run_id:)
      @journal = AgentEventJournal.new(memory_path)
      @agent_type = agent_type
      @adapter = HQ.harness_adapter(agent_type)
      @run_id = run_id.to_s
      @claude_tool_names = {}
    end

    def project_line(line, source_sequence:, raw_offset: nil, occurred_at: Time.now)
      text = line.to_s.encode("UTF-8", invalid: :replace, undef: :replace)
      remember_claude_tools(text)
      conversation, system = Parser.parse_stream([text], agent_type: @agent_type)
      restore_claude_tool_names(system)
      normalized = normalize(conversation, system, source_sequence:, raw_offset:, occurred_at:)
      normalized.map do |event|
        @journal.append(event, event_id: event.fetch("event_id"))
      end
    end

    private

    def normalize(conversation, system, source_sequence:, raw_offset:, occurred_at:)
      source = {
        "kind" => "#{@adapter}_stream",
        "sequence" => source_sequence,
        "raw_offset" => raw_offset
      }.compact
      timestamp = occurred_at.iso8601(6)
      events = []

      conversation.each_with_index do |entry, index|
        next unless entry.role == "assistant"

        events << envelope(
          type: "assistant_message",
          content: entry.content,
          semantic_key: "assistant-#{index}",
          source_sequence:,
          source:,
          timestamp:,
          metadata: normalized_metadata(entry.metadata, source_sequence)
        )
      end

      system.each_with_index do |entry, index|
        event = normalize_system_entry(entry, index:, source_sequence:, source:, timestamp:)
        events << event if event
      end
      events
    end

    def normalize_system_entry(entry, index:, source_sequence:, source:, timestamp:)
      case entry.type
      when :validation_retry
        envelope(
          type: "validation_retry",
          content: entry.content,
          semantic_key: "validation-retry-#{index}",
          source_sequence:,
          source:,
          timestamp:,
          metadata: normalized_metadata(entry.metadata, source_sequence)
        )
      when :usage
        envelope(
          type: "token_usage",
          content: entry.content,
          semantic_key: "usage-#{index}",
          source_sequence:,
          source:,
          timestamp:,
          metadata: normalized_metadata(entry.metadata, source_sequence)
        )
      when :tool_call, :tool_result
        summary = Parser.compact_memory_summary(entry)
        return nil unless summary

        details = normalized_metadata(entry.metadata, source_sequence).merge("type" => entry.type.to_s)
        envelope(
          type: "tool_summary",
          content: summary,
          semantic_key: "#{entry.type}-#{index}",
          source_sequence:,
          source:,
          timestamp:,
          metadata: { "tool_name" => entry.tool_name.to_s, "details" => details }
        )
      end
    end

    def envelope(type:, content:, semantic_key:, source_sequence:, source:, timestamp:, metadata: nil)
      {
        "event_id" => event_id(source_sequence, semantic_key),
        "run_id" => @run_id,
        "type" => type,
        "content" => content.to_s,
        "occurred_at" => timestamp,
        "created_at" => timestamp,
        "source" => source,
        "metadata" => metadata.is_a?(Hash) && !metadata.empty? ? metadata : nil
      }.compact
    end

    def event_id(source_sequence, semantic_key)
      [@run_id, @adapter, source_sequence, semantic_key].join(":")
    end

    def normalized_metadata(metadata, source_sequence)
      result = metadata.is_a?(Hash) ? metadata.dup : {}
      result["_stream_sequence"] = source_sequence
      result
    end

    def remember_claude_tools(line)
      return unless @adapter == "claude"

      event = JSON.parse(line)
      return unless event["type"] == "assistant"

      Array(event.dig("message", "content")).each do |item|
        next unless item.is_a?(Hash) && item["type"] == "tool_use"

        id = item["id"].to_s
        @claude_tool_names[id] = item["name"].to_s unless id.empty?
      end
    rescue JSON::ParserError
      nil
    end

    def restore_claude_tool_names(system)
      return unless @adapter == "claude"

      system.each do |entry|
        next unless entry.type == :tool_result && entry.tool_name.to_s.empty?

        id = entry.metadata&.dig("tool_use_id").to_s
        entry.tool_name = @claude_tool_names[id] unless id.empty?
      end
    end
  end
end
