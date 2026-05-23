# frozen_string_literal: true

require_relative "option_picker"

module HQ
  module UI
    class ProjectArchiveConfirm
      ABORT = "Abort"
      CONFIRM = "Archive"

      attr_reader :project, :agents, :picker

      def initialize(project, agents:, picker_width: 40)
        @project = project
        @agents = agents
        @picker = OptionPicker.new(options: [ABORT, CONFIRM], width: picker_width)
        @picker.value = ABORT
        @picker.focus
      end

      def summary
        lines = [
          "Config: move to config/hq.archived.yml",
          "Project logs: #{project.log_dir}",
          "Agents: #{agents.length}"
        ]
        lines.join("\n")
      end

      def update(message)
        @picker.update(message)
        [self, nil]
      end

      def confirm?
        @picker.value == CONFIRM
      end
    end
  end
end
