# frozen_string_literal: true

require "bubbletea"

require_relative "../rendering/styles"

module HQ
  module UI
    class OptionPicker
      MARKER = Rendering::Styles::MARKERS[:cursor]

      attr_accessor :width, :prompt
      attr_reader :options, :height, :selected_index

      def initialize(options:, width: 40)
        @options = Array(options).map(&:to_s)
        @width = width
        @prompt = ""
        @selected_index = nil
        @focused = false
        @height = @options.length
      end

      def height=(value)
        @height = [value.to_i, @options.length].min
        @height = @options.length if @height <= 0
      end

      def value
        return "" if @selected_index.nil?

        @options[@selected_index].to_s
      end

      def value=(new_value)
        index = @options.index(new_value.to_s)
        @selected_index = index
      end

      def focus
        @focused = true
      end

      def blur
        @focused = false
      end

      def focused?
        @focused
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
        else
          @selected_index = key.to_i - 1 if key =~ /\A[1-9]\z/ && key.to_i <= @options.length
        end

        [self, nil]
      end

      def view
        return "" if @options.empty?

        @options.map.with_index do |option, index|
          marker = index == @selected_index ? MARKER : " "
          "#{marker} #{option}"
        end.join("\n")
      end

      private

      def move(delta)
        return if @options.empty?

        if @selected_index.nil?
          @selected_index = delta.positive? ? 0 : @options.length - 1
          return
        end

        @selected_index = (@selected_index + delta) % @options.length
      end
    end
  end
end
