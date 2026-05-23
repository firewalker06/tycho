# frozen_string_literal: true

module HQ
  module UI
    class SkillPicker
      WINDOW = 3

      attr_reader :trigger, :query, :highlight_index, :scroll_offset

      def initialize(skills: [])
        @skills = Array(skills)
        @open = false
        @trigger = "/"
        @query = ""
        @highlight_index = 0
        @scroll_offset = 0
      end

      def skills=(list)
        @skills = Array(list)
      end

      def open(trigger:)
        @open = true
        @trigger = trigger
        @query = ""
        @highlight_index = 0
        @scroll_offset = 0
      end

      def close
        @open = false
        @query = ""
        @highlight_index = 0
        @scroll_offset = 0
      end

      def open?
        @open
      end

      def matches?
        !filtered.empty?
      end

      def update_query(text)
        @query = text.to_s
        @highlight_index = 0
        @scroll_offset = 0
      end

      def filtered
        return [] if @skills.empty?
        return @skills if @query.empty?

        needle = @query.downcase
        @skills.select { |skill| skill["name"].to_s.downcase.include?(needle) }
      end

      def move(delta)
        list = filtered
        return if list.empty?

        @highlight_index = (@highlight_index + delta) % list.length
        adjust_scroll
      end

      def visible_window
        list = filtered
        return [] if list.empty?

        list[@scroll_offset, WINDOW] || []
      end

      def highlighted
        filtered[@highlight_index]
      end

      def autocomplete_text
        skill = highlighted
        return nil unless skill

        "#{@trigger}#{skill["name"]} "
      end

      private

      def adjust_scroll
        list_length = filtered.length
        return if list_length <= WINDOW

        if @highlight_index < @scroll_offset
          @scroll_offset = @highlight_index
        elsif @highlight_index >= @scroll_offset + WINDOW
          @scroll_offset = @highlight_index - WINDOW + 1
        end
        @scroll_offset = [[list_length - WINDOW, 0].max, @scroll_offset].min
      end
    end
  end
end
