# frozen_string_literal: true

require "timeout"

module HQ
  module Hooks
    module RubyRunner
      module_function

      def call(hook_config, event, payload, blocking: false)
        handler = hook_config[:handler]
        return nil unless handler

        frozen_payload = payload.frozen? ? payload : payload.dup.freeze
        if blocking
          Timeout.timeout(hook_config[:timeout]) { handler.call(frozen_payload) }
        else
          handler.call(frozen_payload)
          nil
        end
      rescue Timeout::Error
        HQ.logger.warn("Hooks") { "Ruby timeout (#{hook_config[:timeout]}s) on #{event}" }
        nil
      rescue StandardError => e
        HQ.logger.error("Hooks") { "Ruby hook failed for #{event}: #{e.class}: #{e.message}" }
        nil
      end
    end
  end
end
