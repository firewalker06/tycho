# frozen_string_literal: true

require_relative "attachment_normalizer"

module HQ
  class AgentResultNormalizer
    NO_ACTION_COMPLETED_WORK_PATTERN = /(?:\A|^\s*(?:[-*]\s+)?)(?:implemented|committed|created|generated|fixed|updated|changed|added|removed|wrote|answered|delivered|published|deployed)\b/i

    def initialize(workspace:)
      @workspace = workspace
    end

    def normalize_structured_result(parsed)
      return nil unless parsed.is_a?(Hash)

      status = parsed["status"].to_s
      summary = parsed["summary"].to_s.strip
      return nil if status.empty? || summary.empty?

      inquiry = normalize_inquiry(parsed["inquiry"])
      status = normalize_status(status, summary:, inquiry:)
      result = { "status" => status, "summary" => summary }
      result["inquiry"] = inquiry if inquiry
      attachments = normalize_attachments(parsed["attachments"])
      result["attachments"] = attachments if attachments
      result
    end

    def normalize_inquiry(value)
      return nil unless value.is_a?(Hash)

      message = value["message"].to_s.strip
      return nil if message.empty?

      normalized_fields = normalize_inquiry_fields(value["fields"])
      normalized_schema = inquiry_requested_schema_from_fields(normalized_fields) ||
                          normalize_inquiry_requested_schema(value["requested_schema"])

      result = {
        "message" => message,
        "requested_schema" => normalized_schema
      }
      result["fields"] = normalized_fields if normalized_fields
      result.compact
    end

    def normalize_attachments(value)
      normalized = AttachmentNormalizer.normalize(value, workspace: @workspace)
      normalized.empty? ? nil : normalized
    end

    def normalize_attachment(value)
      AttachmentNormalizer.normalize(value, workspace: @workspace).first
    end

    def dedupe_attachments(attachments)
      AttachmentNormalizer.normalize(attachments, workspace: @workspace)
    end

    def attachment_dedupe_key(attachment)
      normalized = normalize_attachments([attachment])&.first
      return nil unless normalized.is_a?(Hash)

      [
        normalized["type"],
        normalized["type"] == "link" ? normalized["url"] : normalized["path"]
      ].map(&:to_s)
    end

    def merge_inquiries(primary, secondary)
      return secondary unless primary.is_a?(Hash)
      return primary unless secondary.is_a?(Hash)
      return primary if primary["message"].to_s.strip != secondary["message"].to_s.strip

      merged = primary.dup
      merged["fields"] ||= secondary["fields"] if secondary["fields"].is_a?(Array)
      merged["requested_schema"] ||= secondary["requested_schema"] if secondary["requested_schema"].is_a?(Hash)
      if richer_inquiry?(secondary, primary)
        merged["fields"] = secondary["fields"] if secondary["fields"].is_a?(Array)
        merged["requested_schema"] = secondary["requested_schema"] if secondary["requested_schema"].is_a?(Hash)
      end
      merged
    end

    private

    def normalize_status(status, summary:, inquiry:)
      return status unless status == "no_action_needed"
      return "input_required" if inquiry
      return "success" if summary.match?(NO_ACTION_COMPLETED_WORK_PATTERN)

      status
    end

    def normalize_inquiry_fields(fields)
      items = Array(fields)
      return nil if items.empty?

      normalized_fields = items.filter_map do |field|
        next unless field.is_a?(Hash)

        key = field["key"].to_s.strip
        next if key.empty?

        input_type = field["input_type"].to_s.strip
        label = field["label"].to_s.strip
        description = field["description"].to_s.strip
        options = Array(field["options"]).map(&:to_s).reject(&:empty?)
        {
          "key" => key,
          "label" => label.empty? ? key : label,
          "description" => description,
          "input_type" => input_type.empty? ? "text" : input_type,
          "required" => field["required"] == true,
          "options" => options.empty? ? nil : options
        }
      end
      return nil if normalized_fields.empty?

      normalized_fields
    end

    def inquiry_requested_schema_from_fields(fields)
      items = Array(fields)
      return nil if items.empty?

      properties = {}
      required = []

      items.each do |field|
        key = field["key"].to_s
        next if key.empty?

        input_type = field["input_type"].to_s
        options = Array(field["options"]).map(&:to_s).reject(&:empty?)
        normalized = case input_type
                     when "number"
                       { "type" => "number" }
                     when "integer"
                       { "type" => "integer" }
                     when "boolean"
                       { "type" => "boolean" }
                     when "multi_select"
                       {
                         "type" => "array",
                         "items" => {
                           "type" => "string",
                           "enum" => options
                         }
                       }
                     else
                       definition = { "type" => "string" }
                       definition["enum"] = options if options.any?
                       definition["x-input-type"] = "multiline" if input_type == "multiline"
                       definition
                     end
        label = field["label"].to_s.strip
        description = field["description"].to_s.strip
        normalized["title"] = label unless label.empty?
        normalized["description"] = description unless description.empty?
        properties[key] = normalized
        required << key if field["required"] == true
      end
      return nil if properties.empty?

      result = {
        "type" => "object",
        "properties" => properties
      }
      result["required"] = required if required.any?
      result
    end

    def normalize_inquiry_requested_schema(schema)
      return nil unless schema.is_a?(Hash) && schema_type(schema["type"]) == "object"

      properties = schema["properties"]
      return nil unless properties.is_a?(Hash) && !properties.empty?

      normalized_properties = properties.each_with_object({}) do |(key, definition), result|
        next if key.to_s.strip.empty?
        next unless definition.is_a?(Hash)

        type = schema_type(definition["type"])
        type = "string" if type.empty?

        normalized = { "type" => type }
        title = definition["title"].to_s.strip
        description = definition["description"].to_s.strip
        normalized["title"] = title unless title.empty?
        normalized["description"] = description unless description.empty?
        options = Array(definition["enum"]).map(&:to_s).reject(&:empty?)
        normalized["enum"] = options if options.any?
        normalized["items"] = normalize_schema_items(definition["items"]) if type == "array" && definition["items"].is_a?(Hash)
        input_type = definition["x-input-type"].to_s.strip
        normalized["x-input-type"] = input_type unless input_type.empty?
        result[key.to_s] = normalized
      end
      return nil if normalized_properties.empty?

      result = {
        "type" => "object",
        "properties" => normalized_properties
      }
      required = Array(schema["required"]).map(&:to_s).reject(&:empty?)
      result["required"] = required if required.any?
      result
    end

    def normalize_schema_items(items)
      normalized = { "type" => schema_type(items["type"]).yield_self { |type| type.empty? ? "string" : type } }
      options = Array(items["enum"]).map(&:to_s).reject(&:empty?)
      normalized["enum"] = options if options.any?
      normalized
    end

    def schema_type(value)
      case value
      when Array
        value.find { |item| item.to_s != "null" }.to_s
      else
        value.to_s.strip
      end
    end

    def richer_inquiry?(candidate, current)
      return false unless candidate.is_a?(Hash)
      return true unless current.is_a?(Hash)

      candidate_fields = Array(candidate["fields"])
      current_fields = Array(current["fields"])
      return true if candidate_fields.any? && current_fields.empty?

      candidate_types = candidate_fields.map { |field| field["input_type"].to_s }
      current_types = current_fields.map { |field| field["input_type"].to_s }
      richer_input_types = %w[multiline multi_select]

      richer_input_types.any? { |type| candidate_types.include?(type) && !current_types.include?(type) }
    end
  end
end
