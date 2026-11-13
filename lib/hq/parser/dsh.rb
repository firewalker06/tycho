# frozen_string_literal: true

require "json"
require "time"

module HQ
  module Parser
    # Native dsh headless NDJSON, based on DeepSeek Harness 0.2.2-rc.1.
    class Dsh < Base
      private

      def parse_event(event, conversation, system)
        return unless event.is_a?(Hash)

        case event["type"]
        when "session"
          system << entry(:status, "DeepSeek Harness session initialized", event,
                          "session_id" => event["sessionId"], "cwd" => event["cwd"])
        when "final"
          if event.dig("reason", "kind") == "completed"
            text = Parser.assistant_display_text(event["text"].to_s)
            conversation << ConversationEntry.new(role: "assistant", content: text, timestamp: Time.now) unless text.empty?
          else
            system << entry(:error, "DeepSeek Harness run did not complete", event, "reason" => event["reason"])
          end
        when "tool_call", "tool_result"
          starting = event["type"] == "tool_call"
          value = starting ? event["input"] : event["result"]
          text = value.is_a?(String) ? value : JSON.generate(value)
          tool = SystemEntry.new(type: starting ? :tool_call : :tool_result, content: text,
                                timestamp: Time.now, tool_name: event["tool"],
                                metadata: { "tool_call_id" => event["callId"], "truncated" => event["truncated"] == true,
                                            "is_error" => event["status"] == "error" })
          system << tool
        when "status"
          system << entry(:status, "DeepSeek Harness #{event["phase"]}", event)
          parse_usage(event, system) if event["phase"] == "step_end"
        when "text", "thinking"
          # Intermediate strings can be truncated by dsh. The final event is
          # the complete answer; retain progress without duplicating that answer.
          system << entry(:status, event["text"].to_s, event, "truncated" => event["truncated"] == true)
        when "error"
          system << entry(:error, event["message"].to_s, event)
        end
      end

      def entry(type, content, event, metadata = {})
        SystemEntry.new(type: type, content: content, timestamp: Time.now,
                        metadata: metadata.merge("event_type" => event["type"]))
      end

      def parse_usage(event, system)
        raw = event["usage"]
        return unless raw.is_a?(Hash)

        usage = { "input_tokens" => raw["inputTokens"], "output_tokens" => raw["outputTokens"],
                  "cache_read_input_tokens" => raw["cacheReadTokens"],
                  "cache_creation_input_tokens" => raw["cacheWriteTokens"] }.compact
        system << SystemEntry.new(type: :usage, content: "DeepSeek Harness token usage", timestamp: Time.now,
                                  metadata: { "usage" => usage })
      end
    end
  end
end
