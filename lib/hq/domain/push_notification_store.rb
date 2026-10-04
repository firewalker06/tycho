# frozen_string_literal: true

require "fileutils"
require "json"
require "time"

require_relative "constants"
require_relative "file_store"

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

      with_lock(File::LOCK_SH) { events.any? { |event| event["id"] == id } }
    end

    def all
      with_lock(File::LOCK_SH) { events.reverse }
    end

    def find(id)
      target = id.to_s
      return nil if target.empty?

      with_lock(File::LOCK_SH) { events.find { |event| event["id"] == target } }
    end

    def mark_read!(id, read_at: Time.now)
      target = id.to_s
      return nil if target.empty?

      with_lock(File::LOCK_EX) do
        changed = false
        next_events = events.map do |event|
          next event unless event["id"] == target

          changed = true
          event.merge("read_at" => event["read_at"] || read_at.utc.iso8601)
        end
        write(next_events) if changed
        next_events.find { |event| event["id"] == target }
      end
    end

    def reconcile_agent!(agent_key, state:, archived_at: nil)
      key = agent_key.to_s
      return false if key.empty?

      archived_value = archived_at&.utc&.iso8601
      with_lock(File::LOCK_EX) do
        changed = false
        next_events = events.map do |event|
          next event unless event["agent_key"] == key
          next event if event["target_state"] == state.to_s &&
                        event["target_archived_at"].to_s == archived_value.to_s

          changed = true
          event.merge(
            "target_state" => state.to_s,
            "target_archived_at" => archived_value
          ).compact
        end
        write(next_events) if changed
        changed
      end
    end

    def reconcile_queue_failures!(active_ids, resolved_at: Time.now)
      active = Array(active_ids).map(&:to_s)
      with_lock(File::LOCK_EX) do
        changed = false
        next_events = events.map do |event|
          next event unless event["kind"] == "queue_process_failed"
          next event if active.include?(event["id"]) || !event["resolved_at"].to_s.empty?

          changed = true
          event.merge("resolved_at" => resolved_at.utc.iso8601)
        end
        write(next_events) if changed
        changed
      end
    end

    def record!(id, attrs = {})
      id = id.to_s
      return false if id.empty?

      with_lock(File::LOCK_EX) do
        next_events = events
        if next_events.any? { |event| event["id"] == id }
          false
        else
          next_events << attrs.transform_keys(&:to_s).merge(
            "id" => id,
            "created_at" => Time.now.utc.iso8601,
            "read_at" => nil
          )
          write(next_events.last(@limit))
          true
        end
      end
    end

    private

    def events
      parsed = FileStore.read_json(@path, fallback: [])
      parsed.is_a?(Array) ? parsed : []
    rescue StandardError => e
      HQ.logger.warn("Push") { "Failed to load push notifications from #{@path}: #{e.class} - #{e.message}" }
      []
    end

    def write(events)
      FileStore.write_json(@path, events)
    end

    def with_lock(mode)
      FileUtils.mkdir_p(File.dirname(@path))
      File.open("#{@path}.lock", File::RDWR | File::CREAT, 0o600) do |lock|
        lock.flock(mode)
        yield
      ensure
        lock.flock(File::LOCK_UN) rescue nil
      end
    end
  end
end
