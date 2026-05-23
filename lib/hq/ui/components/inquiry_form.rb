# frozen_string_literal: true

require "bubbles"

require_relative "option_picker"
require_relative "multi_option_picker"
require_relative "text_paste"
require_relative "text_area_wrapping"

module HQ
  module UI
    class InquiryForm
      DEFAULT_TEXT_HEIGHT = 1
      DEFAULT_MULTILINE_HEIGHT = 1
      MAX_MULTILINE_HEIGHT = 12

      Field = Struct.new(:key, :label, :description, :input_type, :required, :options, :input, keyword_init: true)

      REVIEW_KEY = "__review__"
      REVIEW_SUBMIT = "Submit"
      REVIEW_EDIT = "Keep editing"

      attr_accessor :error_message
      attr_reader :fields, :answer_fields, :field_index, :message

      def initialize(inquiry, width:)
        @message = inquiry["message"].to_s
        inner = [width - 6, 10].max
        definitions = field_definitions_from(inquiry)
        @answer_fields = build_fields(definitions, inner)
        @fields = @answer_fields + [build_review_field(inner)]
        @field_index = 0
        @error_message = nil
        focus_input
      end

      def width=(width)
        inner = [width - 6, 10].max
        @fields.each do |field|
          field.input.width = inner
        end
      end

      def height=(height)
        return unless current_field

        if multiline?
          current_field.input.height = [height - fixed_overhead, 1].max
        elsif picker?
          current_field.input.height = [height - fixed_overhead, current_field.options.length].min
        end
      end

      def height
        desired_height
      end

      def desired_height(available_height = nil)
        desired = fixed_overhead + current_input_height
        return desired unless available_height

        [[desired, available_height].min, fixed_overhead + 1].max
      end

      def focus_input
        current_field&.input&.focus
      end

      def blur_input
        current_field&.input&.blur
      end

      def update_input(message)
        input = current_field.input
        input.update(TextPaste.normalize_message(input, message))
      end

      def insert_newline
        return unless multiline?

        current_field.input.send(:insert_newline)
      end

      def next_field
        blur_input
        @field_index = (@field_index + 1) % @fields.length
        @error_message = nil
        focus_input
      end

      def previous_field
        blur_input
        @field_index = (@field_index - 1) % @fields.length
        @error_message = nil
        focus_input
      end

      def current_field
        @fields[@field_index]
      end

      def content
        values = @answer_fields.each_with_object({}) do |field, result|
          result[field.key] = serialize_value(field, raw_value_for(field))
        end
        JSON.pretty_generate(values)
      end

      def validate
        missing = @answer_fields.find { |field| field.required && !value_present?(field) }
        return nil unless missing

        @field_index = @answer_fields.index(missing) || 0
        focus_input
        "#{missing.label} is required"
      end

      def review?
        current_field&.input_type == "review"
      end

      def submit_ready?
        review? && current_field.input.value == REVIEW_SUBMIT && missing_required_labels.empty?
      end

      def missing_required_labels
        @answer_fields.each_with_object([]) do |field, list|
          list << field.label if field.required && !value_present?(field)
        end
      end

      def review_rows
        @answer_fields.map do |field|
          [field.label, display_value_for(field)]
        end
      end

      def current_input_view
        return current_field.input.view unless multiline?

        height = current_input_height
        TextAreaWrapping.visible_wrapped_lines(current_field.input, height).join("\n")
      end

      def multiline?
        current_field.input.is_a?(Bubbles::TextArea)
      end

      def picker?
        current_field.input.is_a?(OptionPicker)
      end

      def value_present?(field = current_field)
        value = raw_value_for(field)
        case value
        when Array
          value.any?
        else
          !value.to_s.strip.empty?
        end
      end

      private

      def field_definitions_from(inquiry)
        raw_fields = Array(inquiry["fields"])
        return raw_fields if raw_fields.any?

        schema = inquiry["requested_schema"]
        return [] unless schema.is_a?(Hash)

        properties = schema["properties"]
        return [] unless properties.is_a?(Hash)

        required_keys = Array(schema["required"]).map(&:to_s)
        properties.map do |key, definition|
          next nil unless definition.is_a?(Hash)

          {
            "key" => key.to_s,
            "label" => definition["title"].to_s.strip.empty? ? key.to_s : definition["title"].to_s,
            "description" => definition["description"].to_s,
            "input_type" => schema_input_type(definition),
            "required" => required_keys.include?(key.to_s),
            "options" => schema_options(definition)
          }
        end.compact
      end

      def schema_input_type(definition)
        explicit = definition["x-input-type"].to_s.strip
        return explicit unless explicit.empty?

        return "multi_select" if definition["type"].to_s == "array" && schema_options(definition).any?
        return "select" if Array(definition["enum"]).any?

        case definition["type"].to_s
        when "boolean" then "boolean"
        when "number" then "number"
        when "integer" then "integer"
        else "text"
        end
      end

      def build_fields(definitions, width)
        items = definitions.filter_map do |definition|
          next unless definition.is_a?(Hash)

          key = definition["key"].to_s.strip
          label = definition["label"].to_s.strip
          next if key.empty? || label.empty?

          input_type = definition["input_type"].to_s
          options = Array(definition["options"]).map(&:to_s).reject(&:empty?)
          options = %w[Yes No] if input_type == "boolean" && options.empty?

          input = build_input(input_type, options, width)

          Field.new(
            key: key,
            label: label,
            description: definition["description"].to_s,
            input_type: input_type,
            required: definition["required"] == true,
            options: options,
            input: input
          )
        end

        items.empty? ? [fallback_field(width)] : items
      end

      def build_input(input_type, options, width)
        case input_type
        when "select", "boolean"
          OptionPicker.new(options: options, width: width)
        when "multi_select"
          MultiOptionPicker.new(options: options, width: width)
        else
          Bubbles::TextArea.new(width: width, height: DEFAULT_MULTILINE_HEIGHT).tap { |item| item.prompt = "" }
        end
      end

      def build_review_field(width)
        picker = OptionPicker.new(options: [REVIEW_SUBMIT, REVIEW_EDIT], width: width)
        Field.new(
          key: REVIEW_KEY,
          label: "Review & submit",
          description: "Confirm your answers before sending them to the agent.",
          input_type: "review",
          required: false,
          options: [REVIEW_SUBMIT, REVIEW_EDIT],
          input: picker
        )
      end

      def fallback_field(width)
        input = Bubbles::TextArea.new(width: width, height: DEFAULT_MULTILINE_HEIGHT)
        input.prompt = ""
        Field.new(
          key: "response",
          label: "Response",
          description: @message,
          input_type: "multiline",
          required: true,
          options: [],
          input: input
        )
      end

      def fixed_overhead
        6
      end

      def current_input_height
        return review_input_height if review?

        if multiline?
          lines = TextAreaWrapping.wrapped_line_count(current_field.input)
          return [[lines, DEFAULT_MULTILINE_HEIGHT].max, MAX_MULTILINE_HEIGHT].min
        end
        return [current_field.options.length, 1].max if picker?

        DEFAULT_TEXT_HEIGHT
      end

      def review_input_height
        answer_rows = @answer_fields.length
        missing_rows = missing_required_labels.any? ? 3 : 0
        picker_rows = current_field.options.length
        answer_rows + missing_rows + picker_rows + 2
      end

      def schema_options(definition)
        direct = Array(definition["enum"]).map(&:to_s).reject(&:empty?)
        return direct if direct.any?

        items = definition["items"]
        return [] unless items.is_a?(Hash)

        Array(items["enum"]).map(&:to_s).reject(&:empty?)
      end

      def raw_value_for(field)
        field.input.value
      end

      def display_value_for(field)
        value = raw_value_for(field)
        case value
        when Array
          value.empty? ? "—" : value.join(", ")
        else
          text = value.to_s.strip
          text.empty? ? "—" : text
        end
      end

      def serialize_value(field, value)
        return nil unless value_present?(field)

        case field.input_type
        when "boolean" then value.to_s.casecmp("yes").zero?
        when "multi_select" then Array(value)
        else value.to_s.strip
        end
      end
    end
  end
end
