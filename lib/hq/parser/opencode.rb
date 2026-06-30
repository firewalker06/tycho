# frozen_string_literal: true

require "json"
require "time"

module HQ
  module Parser
    # Parser for OpenCode `opencode run --format json` raw logs.
    #
    # OpenCode's raw JSON event stream is adapter-specific and may evolve, so
    # this parser intentionally accepts several common event shapes:
    # assistant/message/result text, tool call/result payloads, usage hashes,
    # and error/failure records. Real-run fixtures should tighten these cases
    # as Tycho sees more OpenCode versions in the wild.
    class OpenCode < Base
      private

      def parse_event(event, conversation, system)
        parse_error(event, system)
        parse_usage(event, system)
        parse_tool_event(event, system)
        parse_assistant_event(event, conversation)
      end

      def parse_assistant_event(event, conversation)
        return if delta_event?(event)

        text = assistant_text(event)
        return if text.empty?

        display = Parser.assistant_display_text(text)
        return if display.empty?

        conversation << ConversationEntry.new(
          role: "assistant",
          content: display,
          timestamp: Time.now,
          metadata: event_metadata(event)
        )
      end

      def parse_tool_event(event, system)
        payload = tool_payload(event)
        return unless payload

        tool_name = tool_name(payload, event)
        body = tool_call_body(payload)
        return if tool_name.empty? && body.empty?

        system << SystemEntry.new(
          type: :tool_call,
          content: body.empty? ? tool_name : body,
          timestamp: Time.now,
          tool_name: tool_name.empty? ? nil : tool_name,
          metadata: event_metadata(event).merge("tool" => payload)
        )

        result = tool_result_body(payload)
        return if result.empty?

        system << SystemEntry.new(
          type: :tool_result,
          content: result,
          timestamp: Time.now,
          tool_name: tool_name.empty? ? nil : tool_name,
          metadata: event_metadata(event).merge("tool" => payload)
        )
      end

      def parse_usage(event, system)
        part = event["part"].is_a?(Hash) ? event["part"] : {}
        usage = event["usage"].is_a?(Hash) ? event["usage"] : event.dig("message", "usage")
        usage = part["tokens"] if usage.nil? && part["tokens"].is_a?(Hash)
        return unless usage.is_a?(Hash) || event.key?("total_cost_usd") || event.key?("cost") || part.key?("cost")

        input_tokens = usage&.dig("input_tokens") || usage&.dig("input") || usage&.dig("prompt_tokens")
        output_tokens = usage&.dig("output_tokens") || usage&.dig("output") || usage&.dig("completion_tokens")
        cost = event["total_cost_usd"] || event["cost"] || part["cost"] || usage&.dig("cost")
        turns = event["num_turns"] || event["turns"]
        duration = event["duration_ms"] || event["duration"]

        parts = []
        parts << "$#{format("%.4f", cost)}" if cost
        parts << "#{input_tokens} input" if input_tokens
        parts << "#{output_tokens} output" if output_tokens
        parts << "#{turns} turns" if turns
        parts << "#{duration}ms" if duration
        return if parts.empty?

        metadata = event_metadata(event)
        metadata["input_tokens"] = input_tokens if input_tokens
        metadata["output_tokens"] = output_tokens if output_tokens
        metadata["total_cost_usd"] = cost if cost
        metadata["num_turns"] = turns if turns
        metadata["duration_ms"] = duration if duration

        system << SystemEntry.new(
          type: :usage,
          content: parts.join(", "),
          timestamp: Time.now,
          tool_name: nil,
          metadata: metadata
        )
      end

      def parse_error(event, system)
        type = event["type"].to_s
        error = event["error"]
        message = if error.is_a?(Hash)
                    error["message"].to_s
                  else
                    error.to_s
                  end
        message = event["message"].to_s if message.strip.empty? && type.match?(/error|fail/i)
        return if message.strip.empty?
        return unless type.match?(/error|fail/i) || event["is_error"] == true

        system << SystemEntry.new(
          type: :error,
          content: message.strip,
          timestamp: Time.now,
          tool_name: nil,
          metadata: event_metadata(event)
        )
      end

      def assistant_text(event)
        nested = nested_message(event)
        part = event["part"].is_a?(Hash) ? event["part"] : {}
        role = event["role"].to_s
        role = nested["role"].to_s if role.empty? && nested.is_a?(Hash)
        type = event["type"].to_s
        item = event["item"].is_a?(Hash) ? event["item"] : {}

        return "" unless role == "assistant" ||
                         type.match?(/assistant|message|result/i) ||
                         (type == "text" && part["type"].to_s == "text") ||
                         item["type"].to_s.match?(/agent_message|assistant|message/i)

        text = text_from_value(event["text"])
        text = text_from_value(event["content"]) if text.empty?
        text = text_from_value(event["result"]) if text.empty?
        text = text_from_value(nested["content"]) if text.empty? && nested.is_a?(Hash)
        text = text_from_value(nested["text"]) if text.empty? && nested.is_a?(Hash)
        text = text_from_value(item["text"]) if text.empty?
        text = text_from_value(item["content"]) if text.empty?
        text = text_from_value(part["text"]) if text.empty?
        text = text_from_value(part["content"]) if text.empty?
        text.strip
      end

      def nested_message(event)
        message = event["message"]
        message.is_a?(Hash) ? message : {}
      end

      def text_from_value(value)
        case value
        when String
          value
        when Array
          value.filter_map { |part| text_part(part) }.join("\n")
        when Hash
          text_part(value)
        else
          ""
        end.to_s
      end

      def text_part(part)
        return part if part.is_a?(String)
        return nil unless part.is_a?(Hash)

        if part.key?("text")
          part["text"].to_s
        elsif part.key?("content")
          text_from_value(part["content"])
        end
      end

      def tool_payload(event)
        return event["tool"] if event["tool"].is_a?(Hash)
        return event["tool_call"] if event["tool_call"].is_a?(Hash)
        return event["toolCall"] if event["toolCall"].is_a?(Hash)
        return event["call"] if event["call"].is_a?(Hash) && event["type"].to_s.match?(/tool/i)

        part = event["part"]
        return part if part.is_a?(Hash) && part["type"].to_s == "tool"

        item = event["item"]
        return item if item.is_a?(Hash) && item["type"].to_s.match?(/tool/i)

        nil
      end

      def tool_name(payload, event)
        [
          payload["tool"],
          payload["name"],
          payload["tool_name"],
          payload["toolName"],
          event["tool_name"],
          event["toolName"]
        ].map { |value| value.to_s.strip }.find { |value| !value.empty? }.to_s
      end

      def tool_call_body(payload)
        state = payload["state"].is_a?(Hash) ? payload["state"] : {}
        scalar = %w[title description command path file filePath query pattern].filter_map do |key|
          payload[key] || state[key]
        end.find { |value| !value.to_s.strip.empty? }
        return scalar.to_s.strip.lines.first.to_s.strip if scalar

        input = payload["input"] || payload["arguments"] || payload["args"] || state["input"]
        if input.is_a?(Hash)
          nested_scalar = %w[title description command path file filePath query pattern result output].map { |key| input[key] }
                                                                            .find { |value| !value.to_s.strip.empty? }
          return nested_scalar.to_s.strip.lines.first.to_s.strip if nested_scalar
        end
        return "" if input.nil? || input == {}

        input.is_a?(String) ? input.strip : JSON.pretty_generate(input)
      rescue StandardError
        input.to_s
      end

      def tool_result_body(payload)
        state = payload["state"].is_a?(Hash) ? payload["state"] : {}
        output = state.dig("metadata", "preview") || state.dig("metadata", "output") ||
                 state["output"] || payload["result"] || payload["output"]
        return "" if output.to_s.strip.empty?

        output.to_s.strip.lines.first.to_s.strip
      end

      def delta_event?(event)
        event["partial"] == true || event["delta"] || event["type"].to_s.match?(/delta|part\.|updated/i)
      end

      def event_metadata(event)
        metadata = {}
        %w[type id session_id sessionID sessionId message_id messageID].each do |key|
          value = event[key]
          metadata[key] = value unless value.nil? || value.to_s.empty?
        end
        metadata
      end
    end
  end
end
