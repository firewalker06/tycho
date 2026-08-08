# frozen_string_literal: true

require "json"

module HQ
  class AgentStructuredOutputValidator
    Result = Struct.new(:valid?, :payload, :errors, :raw_text, keyword_init: true)

    def initialize(schema:)
      @schema = schema
    end

    def validate(candidate)
      payload, raw_text, parse_errors = parse_candidate(candidate)
      return Result.new(valid?: false, errors: parse_errors, raw_text:) if parse_errors.any?

      payload, compatibility_errors = canonicalize_compatibility_fields(payload)
      errors = compatibility_errors + validate_value(payload, @schema, "$")
      Result.new(valid?: errors.empty?, payload:, errors:, raw_text:)
    end

    private

    def parse_candidate(candidate)
      return [candidate, JSON.generate(candidate), []] if candidate.is_a?(Hash)

      raw_text = candidate.to_s
      text = raw_text.strip
      fenced = text.match(/\A```(?:json)?\s*(?<json>.*?)\s*```\z/m)
      text = fenced[:json] if fenced
      [JSON.parse(text), raw_text, []]
    rescue JSON::ParserError, TypeError
      [nil, raw_text, [error("parse_error", "$", "Malformed JSON")]]
    end

    def canonicalize_compatibility_fields(payload)
      return [payload, []] unless payload.is_a?(Hash)

      result = payload.dup
      errors = []
      decode_compatibility_field(result, "inquiry_json", "inquiry", errors)
      decode_compatibility_field(result, "attachments_json", "attachments", errors)
      [result, errors]
    end

    def decode_compatibility_field(result, encoded_key, canonical_key, errors)
      return unless result.key?(encoded_key) && !result.key?(canonical_key)

      value = result.delete(encoded_key)
      unless value.is_a?(String)
        errors << error("wrong_type", "$.#{canonical_key}", "Expected JSON-encoded string", expected: ["string"])
        return
      end

      result[canonical_key] = JSON.parse(value)
    rescue JSON::ParserError
      errors << error("parse_error", "$.#{canonical_key}", "Malformed JSON in #{encoded_key}")
    end

    def validate_value(value, schema, path)
      return [] unless schema.is_a?(Hash)

      expected_types = Array(schema["type"])
      unless expected_types.empty? || expected_types.any? { |type| type_matches?(value, type) }
        return [error("wrong_type", path, "Value has the wrong type", expected: expected_types)]
      end

      errors = []
      if schema["enum"].is_a?(Array) && !schema["enum"].include?(value)
        errors << error("invalid_enum", path, "Value is not an allowed enum member", allowed: schema["enum"])
      end
      errors.concat(validate_object(value, schema, path)) if value.is_a?(Hash)
      errors.concat(validate_array(value, schema, path)) if value.is_a?(Array)
      errors
    end

    def validate_object(value, schema, path)
      properties = schema["properties"].is_a?(Hash) ? schema["properties"] : {}
      errors = Array(schema["required"]).filter_map do |field|
        next if value.key?(field)

        error("missing_field", join_path(path, field), "Required field is missing")
      end
      if schema["additionalProperties"] == false
        (value.keys - properties.keys).sort.each do |field|
          errors << error("unexpected_field", join_path(path, field), "Field is not allowed")
        end
      end
      properties.each do |field, definition|
        next unless value.key?(field)

        errors.concat(validate_value(value[field], definition, join_path(path, field)))
      end
      errors
    end

    def validate_array(value, schema, path)
      return [] unless schema["items"].is_a?(Hash)

      value.each_with_index.flat_map do |item, index|
        validate_value(item, schema["items"], "#{path}[#{index}]")
      end
    end

    def type_matches?(value, type)
      case type
      when "null" then value.nil?
      when "object" then value.is_a?(Hash)
      when "array" then value.is_a?(Array)
      when "string" then value.is_a?(String)
      when "boolean" then value == true || value == false
      when "integer" then value.is_a?(Integer)
      when "number" then value.is_a?(Numeric)
      else true
      end
    end

    def join_path(path, field)
      field.to_s.match?(/\A[A-Za-z_][A-Za-z0-9_]*\z/) ? "#{path}.#{field}" : "#{path}[#{field.to_json}]"
    end

    def error(code, path, message, **metadata)
      { "code" => code, "path" => path, "message" => message }.merge(metadata.transform_keys(&:to_s))
    end
  end
end
