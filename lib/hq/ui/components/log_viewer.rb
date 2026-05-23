# frozen_string_literal: true

require "bubbletea"

module HQ
  module UI
    class LogViewer
      attr_reader :width, :height
      attr_reader :content, :y_offset, :x_offset

      HORIZONTAL_STEP = 16

      def initialize(width:, height:)
        @width = width
        @height = height
        @content = ""
        @lines = []
        @y_offset = 0
        @x_offset = 0
      end

      def width=(value)
        @width = value
      end

      def height=(value)
        @height = value
        clamp_offsets!
      end

      def content=(value)
        @content = value.to_s
        @lines = @content.lines(chomp: true)
        @lines = [""] if @content.empty?
        clamp_offsets!
      end

      def view
        visible = @lines[@y_offset, visible_line_count] || []
        visible.map { |line| visible_slice(line) }.join("\n")
      end

      def update(message)
        return unless message.is_a?(Bubbletea::KeyMessage)

        case message.to_s
        when "up", "k" then scroll_vertical(-1)
        when "down", "j" then scroll_vertical(1)
        when "pgup" then scroll_vertical(-page_step)
        when "pgdown" then scroll_vertical(page_step)
        when "g", "home" then goto_top
        when "G", "end" then goto_bottom
        when "left", "h" then scroll_horizontal(-HORIZONTAL_STEP)
        when "right", "l" then scroll_horizontal(HORIZONTAL_STEP)
        when "0" then @x_offset = 0
        end
      end

      def total_line_count
        @lines.length
      end

      def visible_line_count
        [@height.to_i, 0].max
      end

      def at_bottom?
        @y_offset >= max_y_offset
      end

      def goto_top
        @y_offset = 0
      end

      def goto_bottom
        @y_offset = max_y_offset
      end

      private

      def visible_slice(line)
        line.to_s[@x_offset, @width.to_i] || ""
      end

      def page_step
        [visible_line_count - 1, 1].max
      end

      def scroll_vertical(delta)
        @y_offset = [[@y_offset + delta, 0].max, max_y_offset].min
      end

      def scroll_horizontal(delta)
        @x_offset = [@x_offset + delta, 0].max
      end

      def clamp_offsets!
        @y_offset = [[@y_offset, 0].max, max_y_offset].min
        @x_offset = [@x_offset, 0].max
      end

      def max_y_offset
        [total_line_count - visible_line_count, 0].max
      end
    end
  end
end
