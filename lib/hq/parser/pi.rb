# frozen_string_literal: true

require "json"
require "time"

module HQ
  module Parser
    # Parser for pi `--mode json` JSONL events. The event contract is documented
    # by @mariozechner/pi-coding-agent 0.73.1 in docs/json.md.
    class Pi < Base
      private

      def parse_event(event, conversation, system)
        parse_assistant_message(event, conversation)
        parse_tool_event(event, system)
        parse_usage(event, system)
        parse_error(event, system)
      end

      def parse_assistant_message(event, conversation)
        return unless event["type"] == "message_end"

        message = event["message"]
        return unless message.is_a?(Hash) && message["role"] == "assistant"

        text = content_text(message["content"])
        display = Parser.assistant_display_text(text)
        return if display.empty?

        conversation << ConversationEntry.new(
          role: "assistant",
          content: display,
          timestamp: Time.now,
          metadata: event_metadata(event).merge(
            "model" => message["model"],
            "provider" => message["provider"],
            "stop_reason" => message["stopReason"]
          ).compact
        )
      end

      def parse_tool_event(event, system)
        type = event["type"].to_s
        return unless %w[tool_execution_start tool_execution_end].include?(type)

        tool_name = event["toolName"].to_s
        metadata = event_metadata(event).merge(
          "tool_call_id" => event["toolCallId"],
          "is_error" => event["isError"] == true
        )
        if type == "tool_execution_start"
          system << SystemEntry.new(
            type: :tool_call,
            content: compact_value(event["args"], fallback: tool_name),
            timestamp: Time.now,
            tool_name: tool_name.empty? ? nil : tool_name,
            metadata: metadata.merge("tool" => { "args" => event["args"] })
          )
        else
          result = event["result"]
          system << SystemEntry.new(
            type: :tool_result,
            content: compact_value(result, fallback: event["isError"] == true ? "Tool execution failed" : "Tool completed"),
            timestamp: Time.now,
            tool_name: tool_name.empty? ? nil : tool_name,
            metadata: metadata.merge("tool" => { "result" => result })
          )
        end
      end

      def parse_usage(event, system)
        return unless event["type"] == "message_end"

        message = event["message"]
        return unless message.is_a?(Hash) && message["role"] == "assistant" && message["usage"].is_a?(Hash)

        raw = message["usage"]
        cost = raw["cost"].is_a?(Hash) ? raw["cost"]["total"] : nil
        usage = {
          "input_tokens" => raw["input"],
          "output_tokens" => raw["output"],
          "cache_read_input_tokens" => raw["cacheRead"],
          "cache_creation_input_tokens" => raw["cacheWrite"]
        }.compact
        total = raw["totalTokens"]
        parts = []
        parts << "$#{format('%.4f', cost)}" unless cost.nil?
        parts << "#{total} total" unless total.nil?
        parts << "#{usage['input_tokens']} input" unless usage["input_tokens"].nil?
        parts << "#{usage['cache_creation_input_tokens']} cache write" unless usage["cache_creation_input_tokens"].nil?
        parts << "#{usage['cache_read_input_tokens']} cache read" unless usage["cache_read_input_tokens"].nil?
        parts << "#{usage['output_tokens']} output" unless usage["output_tokens"].nil?
        return if parts.empty?

        system << SystemEntry.new(
          type: :usage,
          content: parts.join(", "),
          timestamp: Time.now,
          metadata: event_metadata(event).merge(
            "event_type" => "message_end",
            "usage" => usage,
            "total_tokens" => total,
            "total_cost_usd" => cost,
            "model" => message["model"],
            "provider" => message["provider"]
          ).compact
        )
      end

      def parse_error(event, system)
        message = event["message"]
        assistant_failure = event["type"] == "message_end" && message.is_a?(Hash) &&
                            message["role"] == "assistant" && %w[error aborted].include?(message["stopReason"])
        tool_failure = event["type"] == "tool_execution_end" && event["isError"] == true
        retry_failure = event["type"] == "auto_retry_end" && event["success"] == false
        return unless assistant_failure || tool_failure || retry_failure

        content = if assistant_failure
                    message["errorMessage"].to_s
                  elsif retry_failure
                    event["finalError"].to_s
                  else
                    compact_value(event["result"], fallback: "Tool execution failed")
                  end
        content = "Pi run was aborted" if content.empty? && message&.dig("stopReason") == "aborted"
        system << SystemEntry.new(
          type: :error,
          content: content.empty? ? "Pi reported an unknown error" : content,
          timestamp: Time.now,
          metadata: event_metadata(event)
        )
      end

      def content_text(value)
        Array(value).filter_map do |block|
          next block if block.is_a?(String)
          next unless block.is_a?(Hash) && block["type"] == "text"

          block["text"].to_s
        end.join("\n").strip
      end

      def compact_value(value, fallback: "")
        text = if value.is_a?(Hash) && !content_text(value["content"]).empty?
                 content_text(value["content"])
               elsif value.is_a?(Hash) || value.is_a?(Array)
                 JSON.generate(value)
               else
                 value.to_s
               end
        text = fallback if text.strip.empty?
        text.strip
      rescue StandardError
        fallback
      end

      def event_metadata(event)
        metadata = { "event_type" => event["type"] }
        metadata["session_id"] = event["id"] if event["type"] == "session"
        metadata
      end
    end
  end
end
