# frozen_string_literal: true

require "bubbletea"
require "bubbles"

module HQ
  module UI
    module TextPaste
      module_function

      def normalize_message(input, message)
        text = pasted_text(message)
        return message unless text

        case input
        when Bubbles::TextArea
          Bubbles::TextArea::PasteMessage.new(text)
        when Bubbles::TextInput
          Bubbles::TextInput::PasteMessage.new(text)
        else
          message
        end
      end

      def pasted_text(message)
        return nil unless message.is_a?(Bubbletea::KeyMessage)
        return nil unless message.respond_to?(:runes) && message.runes && message.runes.length > 1

        message.runes.pack("U*")
      rescue StandardError
        nil
      end
    end
  end
end
