# frozen_string_literal: true

module HQ
  module Hooks
    class Dispatcher
      STOP = :__hq_hooks_stop__

      attr_reader :registry

      def initialize(registry: Registry.new)
        @registry = registry
        @queue = Queue.new
        @mutex = Mutex.new
        @worker = nil
      end

      def start!
        @mutex.synchronize do
          return self if @worker && @worker.alive?

          @worker = Thread.new { run_loop }
          @worker.name = "hq-hooks-dispatcher"
        end
        self
      end

      def stop!
        return unless @worker

        @queue << STOP
        @worker.join(5)
        @worker = nil
      end

      def load!(**kwargs)
        @registry.load!(**kwargs)
        self
      end

      def reload!(**kwargs)
        @registry.load!(**kwargs)
        self
      end

      def register_ruby_handler(pattern, &block)
        @registry.register_ruby_handler(pattern, &block)
      end

      def publish(event, payload = {})
        payload = stringify_keys(payload)
        handlers = @registry.handlers_for(event.to_s, project_key: payload["project_key"])
        async = handlers.reject { |h| h[:blocking] }
        return if async.empty?

        @queue << { event: event.to_s, payload: payload, handlers: async }
        nil
      end

      def publish_blocking(event, payload = {})
        payload = stringify_keys(payload)
        handlers = @registry.handlers_for(event.to_s, project_key: payload["project_key"])
        blocking = handlers.select { |h| h[:blocking] }
        return nil if blocking.empty?

        blocking.each do |handler|
          response = run_handler(handler, event.to_s, payload, blocking: true)
          return response if response.is_a?(Hash)
        end
        nil
      end

      private

      def run_loop
        loop do
          item = @queue.pop
          break if item == STOP

          item[:handlers].each do |handler|
            run_handler(handler, item[:event], item[:payload], blocking: false)
          end
        rescue Exception => e # rubocop:disable Lint/RescueException
          HQ.logger.error("Hooks") { "Dispatcher loop error: #{e.class}: #{e.message}" }
          retry
        end
      end

      def run_handler(handler, event, payload, blocking:)
        case handler[:type]
        when :shell
          ShellRunner.call(handler, event, payload, blocking: blocking)
        when :ruby
          RubyRunner.call(handler, event, payload, blocking: blocking)
        end
      end

      def stringify_keys(hash)
        return {} unless hash.is_a?(Hash)

        hash.each_with_object({}) { |(k, v), result| result[k.to_s] = v }
      end
    end
  end
end
