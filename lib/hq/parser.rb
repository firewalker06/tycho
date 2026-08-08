# frozen_string_literal: true

require "json"
require "time"
require_relative "harness_registry"

module HQ
  # HQ::Parser is the entry point for turning raw agent log streams into
  # structured conversation/system entries and into chat blocks for the TUI.
  #
  # Each agent harness (Claude, Codex, ...) has its own parser class under
  # `HQ::Parser::<Name>` because the raw event shapes and tool taxonomies
  # differ per harness. Use `HQ::Parser.for(agent)` to get the right
  # parser for a given agent type string.
  #
  # The shared building blocks (entry Structs, chat composition, system
  # group summarization, prompt-header extraction, persisted chat.log
  # parsing) live here so individual parsers only need to emit
  # ConversationEntry / SystemEntry instances.
  module Parser
    ConversationEntry = Struct.new(:role, :content, :timestamp, :metadata, keyword_init: true)
    SystemEntry = Struct.new(:type, :content, :timestamp, :tool_name, :metadata, keyword_init: true)
    ChatBlock = Struct.new(:kind, :role, :content, :tool_name, :metadata, :created_at, keyword_init: true)

    HEADER_RE = /\A\[(?<role>[^\]]+)\](?:\s+\d{2}:\d{2}:\d{2})?\s*\z/
    SUMMARY_RE = /\A\(.*\)\s*\z/

    module_function

    # Return a parser instance for the given agent type string.
    def for(agent_type)
      case HQ.harness_adapter(agent_type)
      when "claude"
        Claude.new
      when "codex"
        Codex.new
      when "opencode"
        OpenCode.new
      else
        raise ArgumentError, "Unsupported agent parser #{agent_type.inspect}"
      end
    end

    # Convenience helpers so callers don't have to instantiate the parser
    # when they just want a one-shot parse.
    def parse_run(lines, agent_type:)
      self.for(agent_type).parse_run(lines)
    end

    def parse_stream(lines, agent_type:)
      self.for(agent_type).parse_stream(lines)
    end

    # Parse a chat.log file into ChatBlock entries. Two persisted block kinds:
    # - :message — role-tagged conversation entry like "[user] 12:00:00\n..."
    # - :summary — collapsed system summary like "(2 tool calls, last: Bash)"
    #
    # A new block starts only on a line that matches "[role] HH:MM:SS" or a
    # standalone "(...)" summary line — message bodies may contain blank
    # lines, so naive split-on-blank-lines doesn't work.
    def parse_chat_log(content)
      return [] if content.to_s.empty?

      blocks = []
      current_role = nil
      current_lines = []
      previous_blank = true

      flush_message = lambda do
        next if current_role.nil?

        body = current_lines.join("\n").sub(/\A\n+/, "").sub(/\n+\z/, "")
        blocks << ChatBlock.new(kind: :message, role: current_role, content: body)
        current_role = nil
        current_lines = []
      end

      content.to_s.lines(chomp: true).each do |line|
        if (match = line.match(HEADER_RE))
          flush_message.call
          current_role = match[:role]
          current_lines = []
          previous_blank = false
        elsif line.match?(SUMMARY_RE) && previous_blank
          flush_message.call
          blocks << ChatBlock.new(kind: :summary, role: nil, content: line.strip)
          previous_blank = false
        else
          current_lines << line
          previous_blank = line.strip.empty?
        end
      end

      flush_message.call
      blocks
    end

    def format_conversation(conversation_entries)
      conversation_entries.map do |entry|
        header = "[#{entry.role}]"
        header = "#{header} #{entry.timestamp.strftime("%H:%M:%S")}" if entry.timestamp
        "#{header}\n#{entry.content}"
      end.join("\n\n")
    end

    def format_system(system_entries)
      system_entries.map do |entry|
        header = "[#{entry.type}]"
        header = "#{header} #{entry.timestamp.strftime("%H:%M:%S")}" if entry.timestamp
        header = "#{header} #{entry.tool_name}" if entry.tool_name
        meta = format_system_metadata(entry)
        header = "#{header}  #{meta}" unless meta.empty?
        "#{header}\n#{entry.content}"
      end.join("\n\n")
    end

    def compose_chat(conversation_entries, system_entries)
      events = []
      conversation_entries.each_with_index { |e, index| events << [:conversation, e, index] }
      system_entries.each_with_index { |e, index| events << [:system, e, conversation_entries.length + index] }
      events.sort_by! { |_, e, index| event_sort_key(e, index) }

      lines = []
      system_group = []

      events.each do |(kind, entry, _)|
        if kind == :conversation
          unless system_group.empty?
            lines << summarize_system_group(system_group)
            system_group = []
          end
          header = "[#{entry.role}]"
          header = "#{header} #{entry.timestamp.strftime("%H:%M:%S")}" if entry.timestamp
          lines << "#{header}\n#{entry.content}"
        else
          system_group << entry
        end
      end

      lines << summarize_system_group(system_group) unless system_group.empty?

      lines.join("\n\n")
    end

    def compose_chat_blocks(conversation_entries, system_entries)
      events = []
      conversation_entries.each_with_index { |e, index| events << [:conversation, e, index] }
      system_entries.each_with_index { |e, index| events << [:system, e, conversation_entries.length + index] }
      events.sort_by! { |_, e, index| event_sort_key(e, index) }

      blocks = []
      system_group = []

      events.each do |(kind, entry, _)|
        if kind == :conversation
          blocks.concat(system_group_chat_blocks(system_group))
          system_group = []
          blocks << ChatBlock.new(kind: :message, role: entry.role, content: entry.content, metadata: entry.metadata, created_at: entry.timestamp&.iso8601)
        else
          system_group << entry
        end
      end

      blocks.concat(system_group_chat_blocks(system_group))

      blocks
    end

    def event_sort_key(entry, fallback_sequence)
      [
        entry.timestamp || Time.at(0),
        entry_sequence(entry, fallback_sequence)
      ]
    end

    def entry_sequence(entry, fallback_sequence)
      sequence = entry.metadata&.dig("_stream_sequence") || entry.metadata&.dig("_sequence")
      Integer(sequence)
    rescue StandardError
      fallback_sequence
    end

    def system_group_chat_blocks(entries)
      blocks = []
      summary_group = []

      flush_summary = lambda do
        next if summary_group.empty?

        blocks << ChatBlock.new(
          kind: :summary,
          role: nil,
          content: summarize_system_group(summary_group),
          metadata: system_summary_metadata(summary_group)
        )
        summary_group = []
      end

      entries.each do |entry|
        case entry.type
        when :tool_call, :tool_result
          flush_summary.call
          blocks << ChatBlock.new(
            kind: entry.type,
            role: nil,
            content: entry.content,
            tool_name: entry.tool_name,
            metadata: entry.metadata
          )
        when :usage
          flush_summary.call
          blocks << ChatBlock.new(
            kind: :summary,
            role: nil,
            content: summarize_system_group([entry]),
            metadata: system_summary_metadata([entry])
          )
        when :run_summary
          flush_summary.call
          blocks << ChatBlock.new(
            kind: :run_summary,
            role: nil,
            content: run_summary_chat_content(entry),
            tool_name: nil,
            metadata: entry.metadata,
            created_at: entry.timestamp&.iso8601
          )
        when :validation_retry
          flush_summary.call
          blocks << ChatBlock.new(
            kind: :validation_retry,
            role: nil,
            content: entry.content,
            tool_name: nil,
            metadata: entry.metadata,
            created_at: entry.timestamp&.iso8601
          )
        else
          summary_group << entry
        end
      end

      flush_summary.call
      blocks
    end

    def system_summary_metadata(entries)
      return nil if entries.empty?

      if entries.length == 1
        entry = entries.first
        metadata = entry.metadata.is_a?(Hash) ? entry.metadata.dup : {}
        metadata["summary_entry_type"] = entry.type.to_s
        return metadata
      end

      {
        "summary_entries" => entries.map do |entry|
          {
            "type" => entry.type.to_s,
            "content" => entry.content.to_s,
            "tool_name" => entry.tool_name,
            "metadata" => entry.metadata
          }.compact
        end
      }
    end

    def summarize_system_group(entries)
      tool_calls = entries.select { |e| e.type == :tool_call }
      tool_results = entries.select { |e| e.type == :tool_result }
      usage_entries = entries.select { |e| e.type == :usage }
      error_entries = entries.select { |e| e.type == :error }
      run_summaries = entries.select { |e| e.type == :run_summary }

      parts = []

      error_entries.each do |entry|
        message = summary_first_line(entry.content)
        parts << "error: #{message}" unless message.empty?
      end

      run_summaries.each do |entry|
        status = entry.metadata&.dig("status").to_s.strip
        next if status.empty? || status == "success"

        message = summary_first_line(entry.content)
        parts << [status, message].reject(&:empty?).join(": ")
      end

      if tool_calls.any?
        last_tool = tool_calls.last.tool_name || "unknown"
        count = tool_calls.length
        parts << "#{count} tool call#{"s" if count != 1}, last: #{last_tool}"
      end

      if tool_results.any? && tool_calls.empty?
        parts << "#{tool_results.length} tool result#{"s" if tool_results.length != 1}"
      end

      usage_entries.each do |entry|
        cost = entry.metadata&.dig("total_cost_usd")
        parts << "$#{format("%.2f", cost)}" if cost
        tokens = entry.metadata&.dig("output_tokens")
        parts << "#{tokens} output tokens" if tokens
      end

      parts.empty? ? "(#{entries.length} system events)" : "(#{parts.join(" · ")})"
    end

    def run_summary_chat_content(entry)
      content = entry.content.to_s
      status = entry.metadata&.dig("status").to_s.strip
      return content if status.empty? || %w[success succeeded].include?(status)

      message = summary_first_line(content)
      return status if message.empty? && content.empty?
      return "#{status}: #{message}" if content.empty?

      prefix = message.empty? ? status : "#{status}: #{message}"
      content.start_with?(prefix) ? content : "#{prefix}\n\n#{content}"
    end

    def summary_first_line(content)
      text = content.to_s.strip
      return "" if text.empty?

      begin
        parsed = JSON.parse(text)
        message = parsed["message"].to_s.strip if parsed.is_a?(Hash)
        return message unless message.to_s.empty?
      rescue JSON::ParserError
        if (match = text.match(/"message"\s*:\s*"([^"]*)/))
          return match[1].gsub('\\"', '"').strip
        end
      end

      text.lines.first.to_s.strip
    end

    def format_system_metadata(entry)
      return "" unless entry.metadata.is_a?(Hash)

      parts = []
      cost = entry.metadata["total_cost_usd"]
      parts << "$#{format("%.4f", cost)}" if cost
      tokens = entry.metadata["output_tokens"]
      parts << "#{tokens} tokens" if tokens
      parts.join(" · ")
    end

    # Shared utilities that individual parsers use ----------------------------

    # Codex/Claude structured-output runs emit the assistant message as a JSON
    # string matching config/schemas/agent_result.json. Unwrap it to the human
    # `summary` (falling back to the inquiry message) so the chat viewport
    # doesn't render the raw payload.
    def assistant_display_text(text)
      original = text
      text = text.to_s.strip
      fenced = text.match(/\A```(?:json)?\s*(?<json>.*?)\s*```\z/m)
      text = fenced[:json].strip if fenced
      parsed = JSON.parse(text)
      return text unless parsed.is_a?(Hash)
      return text unless parsed.key?("summary") || parsed.key?("inquiry") || parsed.key?("status")

      summary = parsed["summary"].to_s.strip
      return summary unless summary.empty?

      inquiry = parsed["inquiry"]
      inquiry.is_a?(Hash) ? inquiry["message"].to_s.strip : ""
    rescue JSON::ParserError
      original
    end

    # Both Claude and Codex raw logs prepend a `prompt=` block with
    # SYSTEM:/USER:/A: sections. Extract those as ConversationEntry rows so
    # the chat viewport reflects the initial state of the run.
    def extract_prompt_header_conversation(lines)
      prompt_lines = []
      inside_prompt = false

      lines.each do |line|
        if inside_prompt
          break if line.start_with?("{") || line.start_with?("=== [")

          prompt_lines << line
        elsif line.start_with?("prompt=")
          inside_prompt = true
          prompt_lines << line.sub(/\Aprompt=/, "")
        end
      end

      return [] if prompt_lines.empty?

      parse_prompt_blocks(prompt_lines)
    end

    def parse_prompt_blocks(prompt_lines)
      entries = []
      current_role = nil
      current_lines = []

      flush = lambda do
        next if current_role.nil?

        text = current_lines.join("\n").strip
        next if text.empty?

        entries << ConversationEntry.new(role: current_role, content: text, timestamp: Time.now)
      end

      prompt_lines.each do |line|
        case line
        when /\ASYSTEM:\s*\z/
          flush.call
          current_role = "system"
          current_lines = []
        when /\AUSER:\s*\z/
          flush.call
          current_role = "user"
          current_lines = []
        when /\AA:\s*\z/, /\AASSISTANT:\s*\z/
          flush.call
          current_role = "assistant"
          current_lines = []
        else
          current_lines << line
        end
      end

      flush.call
      if entries.empty?
        text = prompt_lines.join("\n").strip
        entries << ConversationEntry.new(role: "user", content: text, timestamp: Time.now) unless text.empty?
      end
      entries
    end

    # Base class for harness-specific parsers. Subclasses implement
    # `parse_event(event, conversation, system)`.
    class Base
      def parse_run(lines)
        parse_lines(lines, include_prompt_header: true)
      end

      def parse_stream(lines)
        parse_lines(lines, include_prompt_header: false)
      end

      private

      def parse_lines(lines, include_prompt_header:)
        conversation = include_prompt_header ? Parser.extract_prompt_header_conversation(lines) : []
        system = []

        lines.each_with_index do |line, stream_sequence|
          stripped = line.strip
          next unless stripped.start_with?("{")

          event = JSON.parse(stripped)
          conversation_start = conversation.length
          system_start = system.length
          if parse_tycho_event(event, system)
            tag_stream_sequence(system, system_start, stream_sequence)
            next
          end
          parse_event(event, conversation, system)
          tag_stream_sequence(conversation, conversation_start, stream_sequence)
          tag_stream_sequence(system, system_start, stream_sequence)
        rescue JSON::ParserError
          next
        end

        [conversation, system]
      end

      def tag_stream_sequence(entries, start_index, stream_sequence)
        Array(entries[start_index..]).each do |entry|
          metadata = entry.metadata.is_a?(Hash) ? entry.metadata.dup : {}
          metadata["_stream_sequence"] = stream_sequence
          entry.metadata = metadata
        end
      end

      def parse_tycho_event(event, system)
        return false unless event["type"] == "tycho.structured_output.validation_failed"

        will_retry = event["will_retry"] == true
        attempt = event["next_correction_attempt"].to_i
        limit = event["correction_limit"].to_i
        content = if will_retry
                    "Structured output failed validation. Retrying in the same native session (#{attempt} of #{limit})."
                  else
                    "Structured output failed validation. The correction retry limit is exhausted."
                  end
        system << SystemEntry.new(
          type: :validation_retry,
          content: content,
          timestamp: Time.now,
          tool_name: nil,
          metadata: {
            "event_type" => event["type"],
            "response_attempt" => event["response_attempt"],
            "next_correction_attempt" => event["next_correction_attempt"],
            "correction_limit" => event["correction_limit"],
            "will_retry" => will_retry,
            "errors" => Array(event["errors"])
          }
        )
        true
      end
    end
  end
end

require_relative "parser/claude"
require_relative "parser/codex"
require_relative "parser/opencode"
