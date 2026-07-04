# frozen_string_literal: true

require_relative "styles"

module HQ
  module UI
    module Rendering
      class ProjectStatusBadge
        STEADY = :steady

        attr_reader :kind, :text, :style_key

        def self.for(_project)
          new(kind: STEADY, text: "#{Styles::MARKERS[:dot]} configured", style_key: :healthy)
        end

        def initialize(kind:, text:, style_key:)
          @kind = kind
          @text = text
          @style_key = style_key
        end

        def spinner?
          false
        end
      end
    end
  end
end
