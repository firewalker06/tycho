# frozen_string_literal: true

require "digest"
require "json"

require_relative "constants"
require_relative "file_store"

module HQ
  class PushSubscriptionStore
    def initialize(path: PUSH_SUBSCRIPTIONS_FILE)
      @path = path
    end

    def all
      read
    end

    def enabled
      all.reject { |subscription| subscription["disabled_at"].to_s != "" }
    end

    def count
      enabled.length
    end

    def save_subscription(attrs, user_agent: nil)
      endpoint = attrs["endpoint"].to_s.strip
      keys = attrs["keys"].is_a?(Hash) ? attrs["keys"] : {}
      p256dh = keys["p256dh"].to_s.strip
      auth = keys["auth"].to_s.strip
      raise ArgumentError, "endpoint is required" if endpoint.empty?
      raise ArgumentError, "p256dh is required" if p256dh.empty?
      raise ArgumentError, "auth is required" if auth.empty?

      now = Time.now.utc.iso8601
      subscriptions = all
      index = subscriptions.index { |subscription| subscription["endpoint"] == endpoint }
      existing = index ? subscriptions[index] : {}
      subscription = existing.merge(
        "id" => existing["id"] || subscription_id(endpoint),
        "endpoint" => endpoint,
        "p256dh" => p256dh,
        "auth" => auth,
        "user_agent" => user_agent.to_s,
        "created_at" => existing["created_at"] || now,
        "updated_at" => now,
        "last_seen_at" => now,
        "failure_count" => 0,
        "disabled_at" => nil
      )
      index ? subscriptions[index] = subscription : subscriptions << subscription
      write(subscriptions)
      subscription
    end

    def disable(endpoint)
      endpoint = endpoint.to_s
      return nil if endpoint.empty?

      changed = false
      disabled = nil
      now = Time.now.utc.iso8601
      subscriptions = all.map do |subscription|
        next subscription unless subscription["endpoint"] == endpoint

        changed = true
        disabled = subscription.merge("disabled_at" => now, "updated_at" => now)
      end
      write(subscriptions) if changed
      disabled
    end

    def record_failure(endpoint)
      endpoint = endpoint.to_s
      subscriptions = all
      changed = false
      subscriptions.each do |subscription|
        next unless subscription["endpoint"] == endpoint

        subscription["failure_count"] = subscription["failure_count"].to_i + 1
        subscription["updated_at"] = Time.now.utc.iso8601
        changed = true
      end
      write(subscriptions) if changed
    end

    private

    def read
      parsed = FileStore.read_json(@path, fallback: [])
      parsed.is_a?(Array) ? parsed : []
    rescue StandardError => e
      HQ.logger.warn("Push") { "Failed to load push subscriptions from #{@path}: #{e.class} - #{e.message}" }
      []
    end

    def write(subscriptions)
      FileStore.write_json(@path, subscriptions)
    end

    def subscription_id(endpoint)
      Digest::SHA256.hexdigest(endpoint)[0, 16]
    end
  end
end
