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
        options = archive_available? ? [KEEP, ARCHIVE] : [KEEP]
        @picker = OptionPicker.new(options: options, width: picker_width)
        @picker.value = KEEP
        @picker.focus
      end

      def summary
        lines = [
          "New agent: #{new_agent.name}",
          "Fresh logs: #{new_agent.raw_log_path}",
          "Old agent: #{old_agent.name}"
        ]
        lines << "Archive unavailable: unresolved work must stay active." unless archive_available?
        lines.join("\n")
      end

      def update(message)
        @picker.update(message)
        [self, nil]
      end

      def archive_old?
        @picker.value == ARCHIVE
      end

      def archive_available?
        safe_queue = !old_agent.pending_prompts? || old_agent.delegation_callback_prompts_only?
        !old_agent.running? && safe_queue && !old_agent.inquiry_blocking_prompt_queue?
      end
    end
  end
end
