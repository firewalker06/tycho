# frozen_string_literal: true

require "bubbles"

require_relative "skill_picker"
require_relative "text_paste"
require_relative "text_area_wrapping"

module HQ
  module UI
    class ChatComposer
      DEFAULT_MIN_HEIGHT = 1
      DEFAULT_MAX_HEIGHT = 8

      attr_reader :input, :skill_picker

      def initialize(width: 76, height: DEFAULT_MIN_HEIGHT, max_height: DEFAULT_MAX_HEIGHT)
        @min_height = [height, 1].max
        @max_height = [max_height, @min_height].max
        @input = build_input(width, height)
        @skill_picker = SkillPicker.new
        focus_input
      end

      def content
        @input.value.to_s.strip
      end

      def value
        @input.value.to_s
      end

      def value=(text)
        @input.value = text.to_s
      end

      def width=(width)
        @input.width = width
      end

      def width
        @input.width
      end

      def placeholder=(value)
        @input.placeholder = value.to_s
      end

      def height=(height)
        @input.height = [height, 1].max
      end

      def height
        @input.height
      end

      def line_count
        [rendered_wrapped_lines.first.length, 1].max
      end

      def desired_height(available_height = nil)
        desired = [line_count, @min_height].max
        desired = [desired, @max_height].min
        return desired unless available_height

        [[desired, available_height].min, 1].max
      end

      def input_view
        return @input.view if value.empty?

        visible_wrapped_lines.join("\n")
      end

      def update_input(message)
        @input.update(TextPaste.normalize_message(@input, message))
      end

      def focus_input
        @input.focus
      end

      def blur_input
        @input.blur
      end

      def clear
        @input.reset
        @skill_picker.close
        self.height = @min_height
      end

      def insert_newline
        @input.send(:insert_newline)
      end

      private

      def visible_wrapped_lines
        TextAreaWrapping.visible_wrapped_lines(@input, @input.height)
      end

      def rendered_wrapped_lines
        TextAreaWrapping.rendered_wrapped_lines(@input)
      end

      def build_input(width, height)
        input = Bubbles::TextArea.new(width: width, height: height)
        input.cursor.set_mode(Bubbles::Cursor::MODE_STATIC)
        input.prompt = ""
        input.placeholder = "Send a message..."
        input
      end
    end
  end
end
