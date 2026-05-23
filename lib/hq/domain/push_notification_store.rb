# frozen_string_literal: true

require "json"

require_relative "constants"

module HQ
  class PushNotificationStore
    DEFAULT_LIMIT = 500

    def initialize(path: PUSH_NOTIFICATIONS_FILE, limit: DEFAULT_LIMIT)
      @path = path
      @limit = limit.to_i.positive? ? limit.to_i : DEFAULT_LIMIT
    end

    def recorded?(id)
      id = id.to_s
      return false if id.empty?

      events.any? { |event| event["id"] == id }
    end

    def record!(id, attrs = {})
      id = id.to_s
      return false if id.empty? || recorded?(id)

      now = Time.now.utc.iso8601
      next_events = events
      next_events << attrs.transform_keys(&:to_s).merge("id" => id, "created_at" => now)
      write(next_events.last(@limit))
      true
    end

    private

    def events
      return [] unless File.exist?(@path)

      parsed = JSON.parse(File.read(@path))
      parsed.is_a?(Array) ? parsed : []
    rescue StandardError
      []
    end

    def write(events)
      FileUtils.mkdir_p(File.dirname(@path))
      File.write(@path, JSON.pretty_generate(events))
    end
  end
end
