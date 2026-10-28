# frozen_string_literal: true

require "json"
require "time"

module HQ
  module Parser
    # agy has its own event/result envelopes, not Claude's stream protocol.
    class Agy < Base
      def initialize
        super
        @finish_seen = false
      end

      private

      def parse_event(event, conversation, system)
        case event["event"]
        when "init"
          @finish_seen = false
          system << SystemEntry.new(type: :status, content: "agy session initialized", timestamp: Time.now,
                                    metadata: { "session_id" => event["conversation_id"], "permission_mode" => event.dig("init", "permission_mode") })
        when "step_update"
          parse_tool(event["step_update"], system)
        when "result"
          parse_result(event, conversation, system)
        end
      end

      def parse_tool(step, system)
        return unless step.is_a?(Hash) && %w[ACTIVE DONE].include?(step["state"])

        if step["step_type"] == "finish"
          # Only a DONE finish proves a fresh structured result; otherwise the
          # envelope may echo the previous run's payload (print timeout).
          @finish_seen = true if step["state"] == "DONE"
          return
        end

        return unless step["step_type"] == "tool"

        info = step["tool_info"].is_a?(Hash) ? step["tool_info"] : {}
        starting = step["state"] == "ACTIVE"
        value = starting ? info["parameters"] : info["output"]
        text = value.is_a?(String) ? value : JSON.generate(value)
        system << SystemEntry.new(type: starting ? :tool_call : :tool_result, content: text, timestamp: Time.now,
                                  tool_name: step["tool_name"], metadata: { "tool_call_id" => "agy-step-#{step["step_index"]}" })
      end

      def parse_result(event, conversation, system)
        result = event.is_a?(Hash) ? event["result"] : nil
        return unless result.is_a?(Hash)
        # Only the terminal result is a complete response; project_line carries
        # the cross-line finish state because parse_stream sees one line at a time.
        success = result["status"] == "SUCCESS"
        fresh = success && (
          event.key?("agy_finish_seen") ? event["agy_finish_seen"] == true : @finish_seen
        )
        structured = result["structured_output"]
        structured = nil unless fresh && structured.is_a?(Hash)
        text = if structured.is_a?(Hash)
                 Parser.assistant_display_text(JSON.generate(structured))
               else
                 Parser.assistant_display_text(result["response"].to_s)
               end
        if text.strip.empty?
          system << SystemEntry.new(type: :error,
                                    content: "agy returned no final answer for this run (no finish step and empty response; possible CLI print timeout)",
                                    timestamp: Time.now, metadata: { "status" => "incomplete" })
        elsif !fresh
          # A SUCCESS envelope without a DONE finish step is a partial or
          # echoed result; do not present its response as the final answer.
          system << SystemEntry.new(type: :error,
                                    content: "agy run ended without a finish step; response text may be incomplete (possible CLI print timeout)",
                                    timestamp: Time.now, metadata: { "status" => "incomplete" })
        else
          conversation << ConversationEntry.new(role: "assistant", content: text, timestamp: Time.now)
        end
        if fresh && structured
          system << SystemEntry.new(type: :status,
                                    content: "agy run completed",
                                    timestamp: Time.now,
                                    metadata: { "status" => "completed" })
        elsif fresh
          system << SystemEntry.new(type: :error,
                                    content: "agy run finished but produced no structured output",
                                    timestamp: Time.now,
                                    metadata: { "status" => "failed" })
        else
          # A SUCCESS envelope without a DONE finish step is a partial or echoed
          # result; mark it incomplete without echoing its response text.
          system << SystemEntry.new(type: :error,
                                    content: "agy run ended without a finish step; result may be incomplete (possible CLI print timeout)",
                                    timestamp: Time.now, metadata: { "status" => "incomplete" })
        end
        raw = result["usage"]
        return unless raw.is_a?(Hash)

        usage = { "input_tokens" => raw["input_tokens"], "output_tokens" => raw["output_tokens"],
                  "cache_read_input_tokens" => raw["cache_read_tokens"] }.compact
        system << SystemEntry.new(type: :usage,
                                  content: "#{usage["input_tokens"]} input, #{usage["output_tokens"]} output, #{usage["cache_read_input_tokens"]} cache read",
                                  timestamp: Time.now, metadata: { "usage" => usage })
      end
    end
  end
end
