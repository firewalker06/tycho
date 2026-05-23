# frozen_string_literal: true

require_relative "option_picker"

module HQ
  module UI
    class MultiOptionPicker < OptionPicker
      CHECKED = "[x]"
      UNCHECKED = "[ ]"

      def initialize(options:, width: 40)
        super
        @selected_indices = []
      end

      def value
        @selected_indices.sort.map { |index| @options[index] }
      end

      def value=(new_value)
        selected = Array(new_value).map(&:to_s)
        @selected_indices = @options.each_index.select { |index| selected.include?(@options[index]) }
      end

      def update(message)
        return [self, nil] unless message.is_a?(Bubbletea::KeyMessage)

        key = message.to_s
        case key
        when "up", "k"
          move(-1)
        when "down", "j"
          move(1)
        when "home"
          @selected_index = 0 if @options.any?
        when "end"
          @selected_index = @options.length - 1 if @options.any?
        when " ", "space", "x"
          toggle_selected_index
        else
          if key =~ /\A[1-9]\z/ && key.to_i <= @options.length
            @selected_index = key.to_i - 1
            toggle_selected_index
          end
        end

        [self, nil]
      end

      def view
        return "" if @options.empty?

        @options.map.with_index do |option, index|
          marker = index == @selected_index ? MARKER : " "
          checkbox = @selected_indices.include?(index) ? CHECKED : UNCHECKED
          "#{marker} #{checkbox} #{option}"
        end.join("\n")
      end

      private

      def toggle_selected_index
        return if @options.empty?

        @selected_index = 0 if @selected_index.nil?
        if @selected_indices.include?(@selected_index)
          @selected_indices.delete(@selected_index)
        else
          @selected_indices << @selected_index
          @selected_indices.sort!
        end
      end
    end
  end
end
