# frozen_string_literal: true

require "json"

module HQ
  class AgentStructuredResult
    class << self
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

        result_event_payload(parsed)
      end

      private

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
        result.delete("inquiry_json")
        result.delete("attachments_json")
        result
      end

      def structured_json_field(value, expected_class)
        parsed = parse_json_string(value)
        return nil if parsed.nil?

        parsed.is_a?(expected_class) ? parsed : nil
      end

      def parse_json_string(value)
        return nil unless value.is_a?(String)

        JSON.parse(value)
      rescue JSON::ParserError
        nil
      end
    end
  end
end
