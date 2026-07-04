# frozen_string_literal: true

require "bubbles"
require_relative "../../harness_registry"

module HQ
  module UI
    class ProjectEditor
      VISIBLE_SUGGESTIONS = 5

      attr_reader :key_input, :name_input, :path_input, :group_input, :field_index
      attr_accessor :error_message

      def initialize(existing_groups:)
        @existing_groups = existing_groups.uniq.sort
        @selected_agent = agent_options.first
        @field_index = 0
        @error_message = nil

        @key_input = build_input("Key: ", 54)
        @name_input = build_input("Name: ", 54)
        @group_input = build_input("Group: ", 54)
        @path_input = build_input("Path: ", 54)

        @suggestions = []
        @suggestion_index = -1
        @suggestion_offset = 0
        @last_completed_path = nil

        focus_current!
      end

      def title
        "New Project"
      end

      def agent_options
        HQ.harness_keys
      end

      def agent
        @selected_agent
      end

      def agent_index
        agent_options.index(@selected_agent) || 0
      end

      def existing_groups
        @existing_groups
      end

      def current_input
        case @field_index
        when key_field_index then @key_input
        when name_field_index then @name_input
        when group_field_index then @group_input
        when path_field_index then @path_input
        end
      end

      def cycle_agent(delta)
        options = agent_options
        @selected_agent = options[(agent_index + delta) % options.length]
      end

      def next_field
        clear_suggestions!
        blur_current!
        @field_index = (@field_index + 1) % field_count
        focus_current!
        @error_message = nil
      end

      def previous_field
        clear_suggestions!
        blur_current!
        @field_index = (@field_index - 1) % field_count
        focus_current!
        @error_message = nil
      end

      def suggestions
        @suggestions
      end

      def suggestion_index
        @suggestion_index
      end

      def suggestions_visible?
        (path_focused? || group_focused?) && @suggestions.any?
      end

      def group_focused?
        @field_index == group_field_index
      end

      def refresh_suggestions!
        if path_focused?
          refresh_path_suggestions!
        elsif group_focused?
          refresh_group_suggestions!
        end
      end

      def move_suggestion(delta)
        return if @suggestions.empty?

        @suggestion_index = (@suggestion_index + delta) % @suggestions.length
        update_suggestion_offset!
      end

      def visible_suggestions
        @suggestions[@suggestion_offset, VISIBLE_SUGGESTIONS] || []
      end

      def visible_suggestion_selected?(index)
        @suggestion_offset + index == @suggestion_index
      end

      def accept_suggestion!
        return false if @suggestions.empty? || @suggestion_index < 0

        value = @suggestions[@suggestion_index]
        if path_focused?
          apply_path(value)
        elsif group_focused?
          @group_input.value = value
          @group_input.cursor_end
        end
        clear_suggestions!
        true
      end

      def clear_suggestions!
        @suggestions = []
        @suggestion_index = -1
        @suggestion_offset = 0
      end

      def apply_path(path)
        expanded = File.expand_path(path)
        @path_input.value = expanded
        @path_input.cursor_end
        @last_completed_path = expanded
      end

      def prefill_from_path!
        path = @path_input.value.strip
        return if path.empty?

        basename = File.basename(File.expand_path(path))
        @key_input.value = basename.downcase.gsub(/[^a-z0-9_-]/, "-") if @key_input.value.strip.empty?
        @name_input.value = basename if @name_input.value.strip.empty?
      end

      def path_changed_since_completion?
        @path_input.value.strip != @last_completed_path
      end

      def attributes
        {
          key: @key_input.value.strip,
          name: @name_input.value.strip,
          group: @group_input.value.strip,
          path: @path_input.value.strip,
          agent: @selected_agent
        }
      end

      def path_field_index
        0
      end

      def key_field_index
        1
      end

      def name_field_index
        2
      end

      def group_field_index
        3
      end

      def agent_field_index
        4
      end

      def submit_field_index
        5
      end

      def path_focused?
        @field_index == path_field_index
      end

      def agent_focused?
        @field_index == agent_field_index
      end

      def submit_focused?
        @field_index == submit_field_index
      end

      def validate
        attrs = attributes
        return "Path is required" if attrs[:path].empty?
        return "Path does not exist" unless File.directory?(attrs[:path])
        return "Key is required" if attrs[:key].empty?
        return "Name is required" if attrs[:name].empty?

        nil
      end

      def resize(width:)
        input_width = [width - 8, 18].max
        @key_input.width = input_width
        @name_input.width = input_width
        @group_input.width = input_width
        @path_input.width = input_width
      end

      private

      def refresh_path_suggestions!
        raw = @path_input.value.strip
        return clear_suggestions! if raw.empty?

        expanded = File.expand_path(raw)
        resolved = resolve_real_parent(expanded, raw)
        return clear_suggestions! unless resolved

        parent, prefix = resolved

        entries = Dir.children(parent)
                     .select { |name| !name.start_with?(".") }
                     .select { |name| File.directory?(File.join(parent, name)) }
                     .select { |name| prefix.empty? || name.downcase.start_with?(prefix) }
                     .sort
                     .map { |name| File.join(parent, name) }

        @suggestions = entries
        @suggestion_index = @suggestions.empty? ? -1 : 0
        @suggestion_offset = 0
      end

      def refresh_group_suggestions!
        typed = @group_input.value.strip.downcase
        matches = @existing_groups.select { |g| typed.empty? || g.downcase.start_with?(typed) }
        @suggestions = matches
        @suggestion_index = @suggestions.empty? ? -1 : 0
        @suggestion_offset = 0
      end

      def update_suggestion_offset!
        if @suggestion_index < @suggestion_offset
          @suggestion_offset = @suggestion_index
        elsif @suggestion_index >= @suggestion_offset + VISIBLE_SUGGESTIONS
          @suggestion_offset = @suggestion_index - VISIBLE_SUGGESTIONS + 1
        end
        max_offset = [@suggestions.length - VISIBLE_SUGGESTIONS, 0].max
        @suggestion_offset = @suggestion_offset.clamp(0, max_offset)
      end

      def resolve_real_parent(expanded, raw)
        if File.directory?(expanded)
          real = begin
            File.realpath(expanded)
          rescue SystemCallError
            return nil
          end
          return [real, ""] if raw.end_with?("/") || expanded == @last_completed_path
        end

        parent = File.dirname(expanded)
        return nil unless File.directory?(parent)

        real_parent = begin
          File.realpath(parent)
        rescue SystemCallError
          return nil
        end
        [real_parent, File.basename(expanded).downcase]
      end

      def build_input(prompt, width)
        input = Bubbles::TextInput.new
        input.prompt = prompt
        input.width = width
        input
      end

      def focus_current!
        current_input&.focus
      end

      def blur_current!
        current_input&.blur
      end

      def field_count
        submit_field_index + 1
      end
    end
  end
end
