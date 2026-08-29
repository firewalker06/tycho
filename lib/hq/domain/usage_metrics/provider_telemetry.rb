# frozen_string_literal: true

require_relative "../../harness_registry"

module HQ
  module UsageMetrics
    class ProviderTelemetry
      class Base
        attr_reader :adapter, :event_type

        def initialize(adapter:, event_type: nil)
          @adapter = adapter
          @event_type = event_type
        end

        def usage_metadata(_event)
          nil
        end

        def session_id(event)
          value = event["session_id"]
          value.to_s unless value.to_s.empty?
        end

        def infer_status(_events)
          "unknown"
        end

        def reported_cost(_entries)
          nil
        end

        def codex?
          false
        end
      end

      class Codex < Base
        def initialize
          super(adapter: "codex", event_type: "turn.completed")
        end

        def usage_metadata(event)
          return nil unless event["type"] == event_type

          { "event_type" => event_type, "usage" => event["usage"], "model" => event["model"] }.compact
        end

        def session_id(event)
          value = event["thread_id"] || event["session_id"] || (event["id"] if event["type"] == "thread.started")
          value.to_s unless value.to_s.empty?
        end

        def infer_status(events)
          return "failed" if events.any? { |event| %w[turn.failed error].include?(event["type"]) }
          return "succeeded" if events.any? { |event| event["type"] == event_type }

          "unknown"
        end

        def codex?
          true
        end
      end

      class Claude < Base
        def initialize
          super(adapter: "claude", event_type: "result")
        end

        def usage_metadata(event)
          return nil unless event["type"] == event_type

          {
            "event_type" => event_type, "total_cost_usd" => event["total_cost_usd"],
            "usage" => event["usage"], "model_usage" => event["modelUsage"] || event["model_usage"],
            "model" => event["model"], "duration_ms" => event["duration_ms"]
          }.compact
        end

        def infer_status(events)
          result = events.reverse.find { |event| event["type"] == event_type }
          result ? result["is_error"] ? "failed" : "succeeded" : "unknown"
        end

        def reported_cost(entries)
          entries.filter_map { |entry| yield(entry) }.last
        end
      end

      class OpenCode < Base
        def initialize
          super(adapter: "opencode", event_type: "step_finish")
        end

        def usage_metadata(event)
          return nil unless event["type"] == event_type

          {
            "event_type" => event_type, "total_cost_usd" => event["total_cost_usd"] || event.dig("part", "cost"),
            "usage" => event["usage"] || event.dig("part", "tokens"),
            "model" => event["model"] || event.dig("part", "model")
          }.compact
        end

        def session_id(event)
          value = event["session_id"] || event["sessionID"] || event["sessionId"] || event.dig("session", "id")
          value.to_s unless value.to_s.empty?
        end

        def infer_status(events)
          events.any? { |event| event["type"] == event_type } ? "succeeded" : "unknown"
        end

        def reported_cost(entries)
          values = entries.filter_map { |entry| yield(entry) }
          values.sum unless values.empty?
        end
      end

      class Pi < Base
        def initialize
          super(adapter: "pi", event_type: "message_end")
        end

        def usage_metadata(event)
          message = event["message"]
          return nil unless event["type"] == event_type && message.is_a?(Hash) &&
                            message["role"] == "assistant" && message["usage"].is_a?(Hash)

          raw = message["usage"]
          {
            "event_type" => event_type,
            "total_cost_usd" => raw.dig("cost", "total"),
            "usage" => {
              "input_tokens" => raw["input"],
              "output_tokens" => raw["output"],
              "cache_read_input_tokens" => raw["cacheRead"],
              "cache_creation_input_tokens" => raw["cacheWrite"]
            }.compact,
            "model" => message["model"],
            "provider" => message["provider"]
          }.compact
        end

        def session_id(event)
          value = event["id"] if event["type"] == "session"
          value.to_s unless value.to_s.empty?
        end

        def infer_status(events)
          messages = events.filter_map { |event| event["message"] if event["type"] == event_type }
          return "failed" if messages.any? { |message| message["stopReason"] == "error" }
          return "succeeded" if events.any? { |event| event["type"] == "agent_end" }

          "unknown"
        end

        def reported_cost(entries)
          values = entries.filter_map { |entry| yield(entry) }
          values.sum unless values.empty?
        end
      end

      PROVIDERS = {
        "codex" => Codex,
        "claude" => Claude,
        "opencode" => OpenCode,
        "pi" => Pi
      }.freeze

      def self.for(harness)
        adapter = HQ.harness_adapter(harness)
        provider = PROVIDERS[adapter]
        provider ? provider.new : Base.new(adapter:)
      end
    end
  end
end
