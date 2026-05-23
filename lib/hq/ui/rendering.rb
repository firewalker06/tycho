# frozen_string_literal: true

require_relative "rendering/styles"
require_relative "rendering/text_helpers"
require_relative "rendering/layout"
require_relative "rendering/status_helpers"
require_relative "rendering/chat_rendering"
require_relative "rendering/views"

module HQ
  module UI
    module Rendering
      include Rendering::Styles
      include Rendering::TextHelpers
      include Rendering::Layout
      include Rendering::StatusHelpers
      include Rendering::ChatRendering
      include Rendering::Views
    end
  end
end
