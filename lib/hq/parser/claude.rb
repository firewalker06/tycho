# frozen_string_literal: true

require "json"
require "time"

module HQ
  module Parser
    # Parser for Claude-compatible `--output-format stream-json` raw logs.
    #
    # Stream events seen in the wild:
    #   {"type":"assistant","message":{"role":"assistant","content":[...]}}
    #     - content[*].type == "text" → assistant message
    #     - content[*].type == "tool_use" → tool call
    #   {"type":"user","message":{"role":"user","content":[...]}}
    #     - content[*].type == "tool_result" → tool result (string or array)
    #   {"type":"item.completed","item":{"type":"agent_message","text":...}}
    #   {"type":"result", ... usage/cost/duration ...}
    #
    # Tool taxonomy (see docs/research/tool_log_shapes.md):
    #   Bash, Read, Write, Grep, Glob, Agent, Skill, StructuredOutput
    class Claude < Base
      private

      def parse_event(event, conversation, system)
        case event["type"]
        when "item.completed"
          parse_item_completed(event, conversation)
        when "assistant"
          parse_assistant(event, conversation, system)
        when "user"
          parse_user(event, system)
        when "result"
          parse_result(event, system)
        end
      end

      def parse_item_completed(event, conversation)
        item = event["item"]
        return unless item.is_a?(Hash) && item["type"] == "agent_message"

        text = item["text"].to_s.strip
        return if text.empty?

        display = Parser.assistant_display_text(text)
        return if display.empty?

        conversation << ConversationEntry.new(role: "assistant", content: display, timestamp: Time.now)
      end

      def parse_assistant(event, conversation, system)
        content = event.dig("message", "content")
        Array(content).each do |item|
          next unless item.is_a?(Hash)

          case item["type"]
          when "text"
            text = item["text"].to_s.strip
            next if text.empty?

            conversation << ConversationEntry.new(role: "assistant", content: text, timestamp: Time.now)
          when "tool_use"
            tool_name = item["name"].to_s.strip
            input = item["input"].is_a?(Hash) ? item["input"] : {}
            body = render_tool_call_body(tool_name, input)

            system << SystemEntry.new(
              type: :tool_call,
              content: body,
              timestamp: Time.now,
              tool_name: tool_name,
              metadata: { "tool_use_id" => item["id"].to_s, "input" => input }
            )
          end
        end
      end

      def parse_user(event, system)
        content = event.dig("message", "content")
        Array(content).each do |item|
          next unless item.is_a?(Hash) && item["type"] == "tool_result"

          body = stringify_tool_result_content(item["content"]).strip
          next if body.empty?

          tool_use_id = item["tool_use_id"].to_s
          tool_name = lookup_tool_name(system, tool_use_id)
          preview = render_tool_result_body(tool_name, body)

          system << SystemEntry.new(
            type: :tool_result,
            content: preview,
            timestamp: Time.now,
            tool_name: tool_name,
            metadata: { "tool_use_id" => tool_use_id, "raw" => body }
          )
        end
      end

      def parse_result(event, system)
        usage = event["usage"]
        cost = event["total_cost_usd"]
        output_tokens = usage.is_a?(Hash) ? usage["output_tokens"] : nil

        meta = { "event_type" => "result" }
        meta["subtype"] = event["subtype"] if event["subtype"]
        meta["is_error"] = event["is_error"] unless event["is_error"].nil?
        meta["api_error_status"] = event["api_error_status"] if event["api_error_status"]
        meta["total_cost_usd"] = cost if cost
        meta["usage"] = usage if usage.is_a?(Hash)
        meta["input_tokens"] = usage["input_tokens"] if usage.is_a?(Hash) && usage["input_tokens"]
        meta["cache_creation_input_tokens"] = usage["cache_creation_input_tokens"] if usage.is_a?(Hash) && usage["cache_creation_input_tokens"]
        meta["cache_read_input_tokens"] = usage["cache_read_input_tokens"] if usage.is_a?(Hash) && usage["cache_read_input_tokens"]
        meta["output_tokens"] = output_tokens if output_tokens
        meta["num_turns"] = event["num_turns"] if event["num_turns"]
        meta["duration_ms"] = event["duration_ms"] if event["duration_ms"]
        meta["duration_api_ms"] = event["duration_api_ms"] if event["duration_api_ms"]
        meta["ttft_ms"] = event["ttft_ms"] if event["ttft_ms"]
        meta["ttft_stream_ms"] = event["ttft_stream_ms"] if event["ttft_stream_ms"]
        meta["time_to_request_ms"] = event["time_to_request_ms"] if event["time_to_request_ms"]
        meta["terminal_reason"] = event["terminal_reason"] if event["terminal_reason"]
        meta["stop_reason"] = event["stop_reason"] if event["stop_reason"]
        meta["session_id"] = event["session_id"] if event["session_id"]
        model_usage = event["modelUsage"] || event["model_usage"]
        meta["model_usage"] = model_usage if model_usage.is_a?(Hash)
        meta["model"] = event["model"] if event["model"]

        summary_parts = []
        summary_parts << "$#{format("%.4f", cost)}" if cost
        summary_parts << "#{output_tokens} output tokens" if output_tokens
        summary_parts << "#{event["num_turns"]} turns" if event["num_turns"]
        summary_parts << "#{event["duration_ms"]}ms" if event["duration_ms"]

        system << SystemEntry.new(
          type: :usage,
          content: summary_parts.join(", "),
          timestamp: Time.now,
          tool_name: nil,
          metadata: meta
        )
      end

      # -- Per-tool formatters --

      def render_tool_call_body(tool_name, input)
        case tool_name
        when "Bash"             then bash_body(input)
        when "Read"             then read_body(input)
        when "Write"            then write_body(input)
        when "Edit"             then edit_body(input)
        when "Grep"             then grep_body(input)
        when "Glob"             then glob_body(input)
        when "Agent"            then agent_body(input)
        when "Skill"            then skill_body(input)
        when "StructuredOutput" then structured_output_body(input)
        else default_body(input)
        end
      end

      def bash_body(input)
        description = input["description"].to_s.strip
        command = input["command"].to_s.strip
        body = [description, command].reject(&:empty?).join("\n")
        body.empty? ? default_body(input) : body
      end

      def read_body(input)
        path = basename_or_path(input["file_path"])
        offset = input["offset"]
        limit = input["limit"]
        suffix = if offset || limit
                   range = "#{offset || 0}-#{(offset || 0).to_i + limit.to_i}" if limit
                   range ? ":#{range}" : ":#{offset}"
                 else
                   ""
                 end
        return default_body(input) if path.empty?

        "#{path}#{suffix}"
      end

      def write_body(input)
        path = basename_or_path(input["file_path"])
        path.empty? ? default_body(input) : path
      end

      def edit_body(input)
        path = basename_or_path(input["file_path"])
        path.empty? ? default_body(input) : path
      end

      def grep_body(input)
        pattern = input["pattern"].to_s.strip
        return default_body(input) if pattern.empty?

        scope = input["glob"].to_s.strip
        scope = input["path"].to_s.strip if scope.empty?
        scope.empty? ? pattern : "#{pattern}  in #{scope}"
      end

      def glob_body(input)
        pattern = input["pattern"].to_s.strip
        return default_body(input) if pattern.empty?

        path = input["path"].to_s.strip
        path.empty? ? pattern : "#{pattern}  in #{path}"
      end

      def agent_body(input)
        description = input["description"].to_s.strip
        subagent = input["subagent_type"].to_s.strip
        return description unless description.empty?
        return subagent unless subagent.empty?

        default_body(input)
      end

      def skill_body(input)
        skill = input["skill"].to_s.strip
        args = input["args"].to_s.strip
        return default_body(input) if skill.empty?

        args.empty? ? "/#{skill}" : "/#{skill} #{args}"
      end

      def structured_output_body(input)
        status = input["status"].to_s.strip
        summary_first = first_nonempty_line(input["summary"])
        return status if summary_first.empty? && !status.empty?
        return summary_first if status.empty?

        "#{status} — #{summary_first}"
      end

      def default_body(input)
        return "(no input)" if input.nil? || input.empty?

        # Pick the first scalar value as a one-line label; otherwise dump JSON.
        scalar = input.values.find { |v| v.is_a?(String) && !v.strip.empty? }
        return scalar.strip.lines.first.to_s.strip if scalar

        JSON.pretty_generate(input)
      rescue StandardError
        input.to_s
      end

      # -- Tool result rendering --

      def render_tool_result_body(_tool_name, body)
        # Keep results compact — surface the first non-empty line as the
        # preview. The full body is preserved in metadata["raw"] so detail
        # views can show it.
        preview = first_nonempty_line(body)
        preview.empty? ? body : preview
      end

      # tool_result.content can be a plain string OR an array of
      # {type: "text", text: "..."} parts (notably for the Agent tool).
      def stringify_tool_result_content(content)
        return content.to_s unless content.is_a?(Array)

        content.map do |part|
          if part.is_a?(Hash) && part["type"] == "text"
            part["text"].to_s
          else
            part.to_s
          end
        end.join("\n")
      end

      def lookup_tool_name(system, tool_use_id)
        return nil if tool_use_id.empty?

        match = system.reverse.find do |entry|
          entry.type == :tool_call && entry.metadata.is_a?(Hash) && entry.metadata["tool_use_id"] == tool_use_id
        end
        match&.tool_name
      end

      def basename_or_path(path)
        path = path.to_s.strip
        return "" if path.empty?

        File.basename(path)
      end

      def first_nonempty_line(text)
        text.to_s.lines.map(&:strip).find { |l| !l.empty? }.to_s
      end
    end
  end
end
