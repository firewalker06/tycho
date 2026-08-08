# frozen_string_literal: true

require "json"
require "time"

module HQ
  module Parser
    # Parser for Codex `--json` raw logs.
    #
    # Codex emits a stream of JSON events interleaved with the
    # `=== [...] start ===` / `workspace=` / `prompt=` header lines.
    # Relevant event shapes:
    #   {"type":"thread.started", ...}
    #   {"type":"turn.started"}
    #   {"type":"turn.completed","usage":{...}}
    #   {"type":"item.started","item":{"id":..,"type":"command_execution",...}}
    #   {"type":"item.completed","item":{"id":..,"type":"command_execution",...,
    #     "aggregated_output":..,"exit_code":..}}
    #   {"type":"item.completed","item":{"type":"agent_message","text":"..."}}
    #   {"type":"item.completed","item":{"type":"file_change","changes":[...]}}
    #   {"type":"item.*","item":{"type":"todo_list","items":[...]}}
    #
    # Codex tools are different from Claude's: exec, file_change, todo_list.
    class Codex < Base
      private

      def parse_event(event, conversation, system)
        case event["type"]
        when "item.completed"
          parse_item_completed(event, conversation, system)
        when "turn.completed"
          parse_turn_completed(event, system)
        when "error"
          parse_error(event, system)
        when "turn.failed"
          parse_turn_failed(event, system)
        end
      end

      def parse_item_completed(event, conversation, system)
        item = event["item"]
        return unless item.is_a?(Hash)

        case item["type"]
        when "agent_message"
          parse_agent_message(item, conversation)
        when "command_execution"
          parse_command_execution(item, system)
        when "file_change"
          parse_file_change(item, system)
        when "todo_list"
          parse_todo_list(item, system)
        end
      end

      def parse_agent_message(item, conversation)
        text = item["text"].to_s.strip
        return if text.empty?

        display = Parser.assistant_display_text(text)
        return if display.empty?

        conversation << ConversationEntry.new(role: "assistant", content: display, timestamp: Time.now)
      end

      # -- Per-tool formatters --

      def parse_command_execution(item, system)
        command = item["command"].to_s
        output = item["aggregated_output"].to_s
        exit_code = item["exit_code"]
        status = item["status"].to_s

        header = command.empty? ? "(no command)" : command
        body_parts = [header]
        body_parts << "exit=#{exit_code}" unless exit_code.nil?
        body_parts << "status=#{status}" unless status.empty?
        body = body_parts.join("  ")
        body = "#{body}\n#{output}" unless output.empty?

        system << SystemEntry.new(
          type: :tool_call,
          content: body,
          timestamp: Time.now,
          tool_name: "exec",
          metadata: { "exit_code" => exit_code, "status" => status }
        )
      end

      def parse_file_change(item, system)
        changes = Array(item["changes"])
        body = changes.map { |c| "#{c["kind"]} #{c["path"]}" }.join("\n")
        body = "(no changes)" if body.empty?

        system << SystemEntry.new(
          type: :tool_call,
          content: body,
          timestamp: Time.now,
          tool_name: "file_change",
          metadata: { "changes" => changes }
        )
      end

      def parse_todo_list(item, system)
        items = Array(item["items"])
        body = items.map { |entry| "[#{entry["completed"] ? "x" : " "}] #{entry["text"]}" }.join("\n")
        body = "(empty)" if body.empty?

        system << SystemEntry.new(
          type: :tool_call,
          content: body,
          timestamp: Time.now,
          tool_name: "todo_list",
          metadata: nil
        )
      end

      def parse_turn_completed(event, system)
        usage = event["usage"]
        return unless usage.is_a?(Hash)

        input_tokens = usage["input_tokens"]
        cached_tokens = usage["cached_input_tokens"]
        output_tokens = usage["output_tokens"]
        reasoning_tokens = usage["reasoning_output_tokens"]

        parts = []
        parts << "#{input_tokens} input" if input_tokens
        parts << "#{cached_tokens} cached" if cached_tokens
        parts << "#{output_tokens} output" if output_tokens
        parts << "#{reasoning_tokens} reasoning output" if reasoning_tokens

        system << SystemEntry.new(
          type: :usage,
          content: "tokens: #{parts.join(", ")}",
          timestamp: Time.now,
          tool_name: nil,
          metadata: {
            "event_type" => "turn.completed",
            "usage" => usage,
            "output_tokens" => output_tokens,
            "input_tokens" => input_tokens,
            "cached_input_tokens" => cached_tokens,
            "reasoning_output_tokens" => reasoning_tokens
          }
        )
        system.last.metadata["model"] = event["model"] if event["model"]
      end

      def parse_error(event, system)
        message = event["message"].to_s.strip
        return if message.empty?

        system << SystemEntry.new(
          type: :error,
          content: message,
          timestamp: Time.now,
          tool_name: nil,
          metadata: { "type" => event["type"] }
        )
      end

      def parse_turn_failed(event, system)
        error = event["error"]
        message = error.is_a?(Hash) ? error["message"].to_s.strip : error.to_s.strip
        return if message.empty?

        system << SystemEntry.new(
          type: :error,
          content: message,
          timestamp: Time.now,
          tool_name: nil,
          metadata: { "type" => event["type"] }
        )
      end
    end
  end
end
