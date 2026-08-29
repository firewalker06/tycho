# frozen_string_literal: true

require "json"

module HQ
  class AgentStructuredResult
    class << self
      def candidate_from_log_lines(lines)
        Array(lines).reverse_each do |line|
          parsed = JSON.parse(line.to_s.strip)
          candidate = structured_candidate_from_event(parsed)
          return candidate unless candidate.nil?
        rescue JSON::ParserError
          next
        end

        Array(lines).reverse_each do |line|
          parsed = JSON.parse(line.to_s.strip)
          candidate = text_candidate_from_event(parsed)
          return candidate unless candidate.nil?
        rescue JSON::ParserError
          next
        end

        nil
      end

      def from_log_lines(lines)
        Array(lines).reverse_each do |line|
          stripped = line.to_s.strip
          next unless stripped.start_with?("{") && stripped.end_with?("}")

          parsed = JSON.parse(stripped)
          normalized = normalize_payload(parsed)
          return normalized if normalized
        rescue JSON::ParserError
          next
        end

        nil
      rescue StandardError
        nil
      end

      def normalize_payload(parsed)
        return nil unless parsed.is_a?(Hash)

        canonical = canonical_payload(parsed)
        return canonical if canonical

        structured = canonical_payload(parsed["structured_output"])
        return structured if structured

        assistant_structured = assistant_event_payload(parsed)
        return assistant_structured if assistant_structured

        codex_structured = codex_agent_message_payload(parsed)
        return codex_structured if codex_structured

        assistant_text_structured = assistant_text_payload(parsed)
        return assistant_text_structured if assistant_text_structured

        result_event_payload(parsed)
      end

      private

      def structured_candidate_from_event(parsed)
        return nil unless parsed.is_a?(Hash)
        return parsed["structured_output"] if parsed.key?("structured_output")

        if parsed["type"] == "assistant"
          Array(parsed.dig("message", "content")).reverse_each do |item|
            next unless item.is_a?(Hash)
            if item["type"] == "tool_use" && item["name"].to_s.downcase == "structuredoutput"
              return item["input"]
            end
          end
        end

        if parsed["type"] == "message_end" && parsed.dig("message", "role") == "assistant"
          return stringify_text(parsed.dig("message", "content"))
        end

        nil
      end

      def text_candidate_from_event(parsed)
        return nil unless parsed.is_a?(Hash)

        if parsed["type"] == "assistant"
          Array(parsed.dig("message", "content")).reverse_each do |item|
            next unless item.is_a?(Hash)
            return item["text"] if item["type"] == "text" && !item["text"].to_s.empty?
          end
        end

        item = parsed["item"]
        if parsed["type"] == "item.completed" && item.is_a?(Hash) && item["type"] == "agent_message"
          return item["text"]
        end
        return parsed["result"] if parsed["type"] == "result" && parsed.key?("result")

        nil
      end

      def assistant_event_payload(parsed)
        return nil unless parsed["type"] == "assistant"

        Array(parsed.dig("message", "content")).reverse_each do |item|
          next unless item.is_a?(Hash)
          next unless item["type"] == "tool_use"
          next unless item["name"].to_s.downcase == "structuredoutput"

          canonical = canonical_payload(item["input"])
          return canonical if canonical
        end

        nil
      end

      def codex_agent_message_payload(parsed)
        return nil unless parsed["type"] == "item.completed"

        item = parsed["item"]
        return nil unless item.is_a?(Hash) && item["type"] == "agent_message"

        inner = parse_json_string(item["text"])
        normalize_payload(inner) if inner
      end

      def assistant_text_payload(parsed)
        text = assistant_text(parsed)
        inner = parse_json_string(text)
        normalize_payload(inner) if inner
      end

      def assistant_text(parsed)
        return "" unless parsed.is_a?(Hash)

        message = parsed["message"].is_a?(Hash) ? parsed["message"] : {}
        item = parsed["item"].is_a?(Hash) ? parsed["item"] : {}
        part = parsed["part"].is_a?(Hash) ? parsed["part"] : {}
        role = parsed["role"].to_s
        role = message["role"].to_s if role.empty?
        type = parsed["type"].to_s
        return "" unless role == "assistant" || message["role"] == "assistant" || type.match?(/assistant|message|result/i) ||
                         (type == "text" && part["type"].to_s == "text") ||
                         item["type"].to_s.match?(/agent_message|assistant|message/i)

        [
          parsed["text"],
          parsed["content"],
          parsed["result"],
          message["text"],
          message["content"],
          item["text"],
          item["content"],
          part["text"],
          part["content"]
        ].each do |value|
          text = stringify_text(value).strip
          return text unless text.empty?
        end
        ""
      end

      def result_event_payload(parsed)
        return nil unless parsed["type"] == "result"

        prose = parsed["result"].to_s.strip
        return nil if prose.empty?

        status = parsed["is_error"] == true ? "failed" : "success"
        { "status" => status, "summary" => prose }
      end

      def canonical_payload(input)
        return nil unless input.is_a?(Hash) && input["status"].is_a?(String) && input["summary"].is_a?(String)

        result = input.dup
        if result.key?("inquiry_json") && !result.key?("inquiry")
          result["inquiry"] = structured_json_field(result["inquiry_json"], Hash)
        end
        if result.key?("attachments_json") && !result.key?("attachments")
          result["attachments"] = structured_json_field(result["attachments_json"], Array)
        end
        if result.key?("summary_sections_json") && !result.key?("summary_sections")
          result["summary_sections"] = structured_json_field(result["summary_sections_json"], Array)
        end
        result.delete("inquiry_json")
        result.delete("attachments_json")
        result.delete("summary_sections_json")
        result
      end

      def structured_json_field(value, expected_class)
        parsed = parse_json_string(value)
        return nil if parsed.nil?

        parsed.is_a?(expected_class) ? parsed : nil
      end

      def parse_json_string(value)
        return nil unless value.is_a?(String)

        text = value.strip
        JSON.parse(text)
      rescue JSON::ParserError
        fenced = text.match(/\A```(?:json)?\s*(?<json>.*?)\s*```\z/m)
        return parse_json_string(fenced[:json]) if fenced

        object = text.match(/(?<json>\{.*\})/m)
        return nil if object && object[:json] == text

        object ? parse_json_string(object[:json]) : nil
      end

      def stringify_text(value)
        case value
        when String
          value
        when Array
          value.map { |entry| stringify_text(entry) }.reject(&:empty?).join("\n")
        when Hash
          stringify_text(value["text"] || value["content"])
        else
          ""
        end
      end
    end
  end
end
