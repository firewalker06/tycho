# frozen_string_literal: true

require "bubbles"
require_relative "../../harness_registry"

module HQ
  module UI
    class AgentEditor
      attr_reader :mode, :project, :agent, :name_input, :workspace_input, :prompt_input, :field_index,
                  :template_index, :model_input, :reasoning_effort_input
      attr_accessor :error_message

      def initialize(mode:, project:, agent: nil)
        @mode = mode
        @project = project
        @agent = agent
        @template_index = template_index_for(agent&.template_key)
        @selected_harness = normalize_harness(agent&.agent || template.agent)
        @field_index = 0

        @name_input = build_input("Name: ", 54)
        @workspace_input = build_input("Workspace: ", 54)
        @model_input = build_input("Model: ", 54)
        @reasoning_effort_input = build_input("Effort: ", 54)
        @prompt_input = build_text_area
        @error_message = nil
        @model_dirty = false
        @reasoning_effort_dirty = false

        if agent
          @name_input.value = agent.name
          @workspace_input.value = agent.workspace
          @model_input.value = agent.model.to_s
          @reasoning_effort_input.value = agent.reasoning_effort.to_s
          @prompt_input.value = wrap_prompt(agent.prompt)
        else
          apply_template_defaults!(preserve_name: false, preserve_model_settings: false)
          @workspace_input.value = project.path
        end

        focus_current!
      end

      def title
        mode == :create ? "Create Agent" : "Edit Agent"
      end

      def template
        @project.agent_templates[@template_index]
      end

      def template_choices
        @project.agent_templates
      end

      def template_label
        template.name.to_s
      end

      def harness_options
        HQ.harness_keys
      end

      def harness
        @selected_harness
      end

      def harness_index
        harness_options.index(@selected_harness) || 0
      end

      def current_input
        case @field_index
        when name_field_index then @name_input
        when workspace_field_index then @workspace_input
        when model_field_index then @model_input
        when reasoning_effort_field_index then @reasoning_effort_input
        when prompt_field_index then @prompt_input
        end
      end

      def cycle_template(delta)
        return if @project.agent_templates.empty?

        @template_index = (@template_index + delta) % @project.agent_templates.length
        apply_template_defaults!(preserve_name: mode == :edit, preserve_model_settings: mode == :edit)
      end

      def cycle_harness(delta)
        options = harness_options
        @selected_harness = options[(harness_index + delta) % options.length]
      end

      def next_field
        blur_current!
        @field_index = (@field_index + 1) % field_count
        focus_current!
        @error_message = nil
      end

      def previous_field
        blur_current!
        @field_index = (@field_index - 1) % field_count
        focus_current!
        @error_message = nil
      end

      def attributes
        {
          name: @name_input.value.strip,
          template_key: template.key,
          workspace: show_workspace? ? @workspace_input.value.strip : @project.path,
          prompt: @prompt_input.value.strip,
          sandbox_mode: template.sandbox_mode,
          agent: @selected_harness,
          model: empty_to_nil(@model_input.value),
          reasoning_effort: empty_to_nil(@reasoning_effort_input.value&.downcase),
          response_style: template.response_style
        }
      end

      def show_workspace?
        mode == :edit
      end

      def submit_focused?
        submit_field_indexes.include?(@field_index)
      end

      def template_focused?
        @field_index == template_field_index
      end

      def harness_focused?
        @field_index == harness_field_index
      end

      def prompt_field_index
        show_workspace? ? 6 : 5
      end

      def template_field_index
        0
      end

      def harness_field_index
        1
      end

      def name_field_index
        4
      end

      def workspace_field_index
        show_workspace? ? 5 : nil
      end

      def model_field_index
        2
      end

      def reasoning_effort_field_index
        3
      end

      def create_button_index
        prompt_field_index + 1
      end

      def create_and_run_button_index
        mode == :create ? create_button_index + 1 : nil
      end

      def submit_field_indexes
        [create_button_index, create_and_run_button_index].compact
      end

      def submit_field_index
        submit_field_indexes.last
      end

      def create_button_focused?
        @field_index == create_button_index
      end

      def create_and_run_button_focused?
        create_and_run_button_index && @field_index == create_and_run_button_index
      end

      def run_on_submit?
        mode == :create && create_and_run_button_focused?
      end

      def button_labels
        if mode == :create
          ["Create Agent", "Create and Run Agent"]
        else
          ["Save Agent"]
        end
      end

      def submit_label
        if mode == :edit
          "Save Agent"
        elsif create_and_run_button_focused?
          "Create and Run Agent"
        else
          "Create Agent"
        end
      end

      def validate
        return "Name is required" if @name_input.value.strip.empty?
        return "Prompt is required" if @prompt_input.value.strip.empty?
        return "Workspace is required" if show_workspace? && @workspace_input.value.strip.empty?

        nil
      end

      def resize(width:)
        input_width = [width - 8, 18].max
        prompt_width = [width, 24].max
        @name_input.width = input_width
        @workspace_input.width = input_width
        @model_input.width = input_width
        @reasoning_effort_input.width = input_width
        @prompt_input.width = prompt_width
      end

      def mark_model_dirty!
        @model_dirty = true
      end

      def mark_reasoning_effort_dirty!
        @reasoning_effort_dirty = true
      end

      private

      def template_index_for(key)
        index = @project.agent_templates.index { |template_config| template_config.key == key }
        index || 0
      end

      def build_input(prompt, width)
        input = Bubbles::TextInput.new
        input.prompt = prompt
        input.width = width
        input
      end

      def build_text_area
        input = Bubbles::TextArea.new(width: 76, height: 5)
        input.cursor.set_mode(Bubbles::Cursor::MODE_STATIC)
        input.prompt = ""
        input
      end

      def apply_template_defaults!(preserve_name:, preserve_model_settings:)
        @prompt_input.value = wrap_prompt(template.prompt)
        @name_input.value = default_name unless preserve_name
        @selected_harness = normalize_harness(template.agent)
        @model_input.value = template.model.to_s unless preserve_model_settings || @model_dirty
        unless preserve_model_settings || @reasoning_effort_dirty
          @reasoning_effort_input.value = template.reasoning_effort.to_s
        end
      end

      def default_name
        "#{@project.name} #{template.name.downcase}"
      end

      def normalize_harness(value)
        normalized = value.to_s.strip.downcase
        options = harness_options
        options.include?(normalized) ? normalized : options.first
      end

      def wrap_prompt(text)
        width = 64

        text.to_s.split("\n").map do |line|
          words = line.strip.split(/\s+/)
          next "" if words.empty?

          lines = [words.shift]
          words.each do |word|
            if "#{lines.last} #{word}".length <= width
              lines[-1] = "#{lines.last} #{word}"
            else
              lines << word
            end
          end
          lines.join("\n")
        end.join("\n")
      end

      def empty_to_nil(value)
        text = value.to_s.strip
        text.empty? ? nil : text
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

      public

      def cycle_submit_button(delta)
        return unless submit_focused?
        return if submit_field_indexes.length < 2

        indexes = submit_field_indexes
        current = indexes.index(@field_index) || 0
        @field_index = indexes[(current + delta) % indexes.length]
      end
    end
  end
end
