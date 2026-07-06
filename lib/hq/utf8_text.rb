# frozen_string_literal: true

module HQ
  module Utf8Text
    module_function

    def normalize(value, replacement: "\uFFFD")
      text = value.to_s.dup.force_encoding(Encoding::UTF_8)
      return text if text.valid_encoding?

      text.encode(Encoding::UTF_8, invalid: :replace, undef: :replace, replace: replacement)
    end
  end
end
