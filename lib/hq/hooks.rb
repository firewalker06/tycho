# frozen_string_literal: true

require_relative "hooks/registry"
require_relative "hooks/shell_runner"
require_relative "hooks/ruby_runner"
require_relative "hooks/dispatcher"

module HQ
  module Hooks
    module_function

    def on(pattern, &block)
      raise ArgumentError, "block required" unless block

      HQ.hooks.register_ruby_handler(pattern.to_s, &block)
    end
  end
end
