# frozen_string_literal: true

require "bubbletea"

require_relative "../../domain/agent_chat_log"
require_relative "option_picker"

module HQ
  module UI
    class DeleteAgentConfirm
      ABORT = "Abort"
      CONFIRM = "Confirm"

      attr_reader :agent, :picker

      def initialize(agent, excerpt_lines: 8, picker_width: 40)
        @agent = agent
        @excerpt_lines = excerpt_lines
        @picker = OptionPicker.new(options: [ABORT, CONFIRM], width: picker_width)
        @picker.value = ABORT
        @picker.focus
      end

      def excerpt
        blocks = AgentChatLog.new(@agent).chat_blocks
        return "(no chat history yet)" if blocks.empty?

        lines = blocks.last(@excerpt_lines).map do |block|
          case block.kind
          when :message then "[#{block.role}] #{block.content.lines.first&.chomp}"
          when :summary then block.content
          when :run_summary then "[summary] #{block.content.lines.first&.chomp}"
          when :tool_call
            tool_name = block.tool_name.to_s.strip
            label = tool_name.empty? ? "tool" : tool_name
            "[tool #{label}] #{block.content.lines.first&.chomp}"
          when :tool_result then "[tool result] #{block.content.lines.first&.chomp}"
          end
        end.compact
        lines.empty? ? "(no chat history yet)" : lines.join("\n")
      rescue StandardError
        "(chat log unavailable)"
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
