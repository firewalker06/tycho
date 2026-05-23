# frozen_string_literal: true

require_relative "option_picker"

module HQ
  module UI
    class CloneAgentConfirm
      KEEP = "Keep Old"
      ARCHIVE = "Archive Old"

      attr_reader :old_agent, :new_agent, :picker

      def initialize(old_agent:, new_agent:, picker_width: 44)
        @old_agent = old_agent
        @new_agent = new_agent
        @picker = OptionPicker.new(options: [KEEP, ARCHIVE], width: picker_width)
        @picker.value = ARCHIVE
        @picker.focus
      end

      def summary
        lines = [
          "New agent: #{new_agent.name}",
          "Fresh logs: #{new_agent.raw_log_path}",
          "Old agent: #{old_agent.name}"
        ]
        lines.join("\n")
      end

      def update(message)
        @picker.update(message)
        [self, nil]
      end

      def archive_old?
        @picker.value == ARCHIVE
      end
    end
  end
end
