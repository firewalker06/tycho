# frozen_string_literal: true

require "fileutils"
require "json"
require "securerandom"
require "time"

module HQ
  class AgentEventJournal
    SCHEMA_VERSION = 1

    def initialize(path)
      @path = path
    end

    attr_reader :path

    def events
      return [] unless File.exist?(path)

      with_file(File::LOCK_SH) { |file| read_events(file) }
    rescue StandardError
      []
    end

    def append(event, event_id: nil)
      append_with_status(event, event_id:).first
    end

    def append_unique(event, event_id:)
      append_with_status(event, event_id:).last
    end

    def replace(events)
      with_file(File::LOCK_EX) do |file|
        normalized = normalize_replacement(events)
        file.rewind
        file.truncate(0)
        normalized.each { |event| file.puts(JSON.generate(event.compact)) }
        file.flush
        file.fsync
        normalized
      end
    end

    private

    def append_with_status(event, event_id: nil)
      payload = stringify_keys(event)
      id = event_id.to_s.strip
      id = payload["event_id"].to_s.strip if id.empty?
      id = SecureRandom.uuid if id.empty?

      with_file(File::LOCK_EX) do |file|
        existing = read_events(file)
        if existing.any? { |entry| integer_sequence(entry["sequence"]).nil? }
          existing = normalize_replacement(existing)
          rewrite(file, existing)
        end
        duplicate = existing.find { |entry| entry["event_id"].to_s == id }
        return [duplicate, false] if duplicate

        sequence = existing.filter_map { |entry| integer_sequence(entry["sequence"]) }.max.to_i + 1
        now = Time.now.iso8601(6)
        stored = payload.merge(
          "schema_version" => payload["schema_version"] || SCHEMA_VERSION,
          "sequence" => sequence,
          "event_id" => id,
          "recorded_at" => payload["recorded_at"] || now
        ).compact
        stored["created_at"] ||= stored["occurred_at"] || now

        file.seek(0, IO::SEEK_END)
        file.puts(JSON.generate(stored))
        file.flush
        file.fsync
        [stored, true]
      end
    rescue StandardError => e
      raise IOError, "Failed to append durable agent event: #{e.message}"
    end

    def with_file(lock_mode)
      FileUtils.mkdir_p(File.dirname(path))
      File.open(path, File::RDWR | File::CREAT, 0o600, encoding: "UTF-8") do |file|
        file.flock(lock_mode)
        yield file
      ensure
        file.flock(File::LOCK_UN)
      end
    end

    def read_events(file)
      file.rewind
      file.each_line.filter_map do |line|
        next if line.to_s.strip.empty?

        event = JSON.parse(line)
        event if event.is_a?(Hash)
      rescue JSON::ParserError
        nil
      end
    end

    def normalize_replacement(events)
      Array(events).filter_map.with_index(1) do |event, sequence|
        next unless event.is_a?(Hash)

        payload = stringify_keys(event)
        payload["sequence"] = sequence
        payload["schema_version"] ||= SCHEMA_VERSION
        payload["event_id"] ||= payload.dig("metadata", "event_id")
        payload["event_id"] = SecureRandom.uuid if payload["event_id"].to_s.empty?
        payload["recorded_at"] ||= payload["created_at"] || Time.now.iso8601(6)
        payload
      end
    end

    def rewrite(file, events)
      file.rewind
      file.truncate(0)
      events.each { |event| file.puts(JSON.generate(event.compact)) }
      file.flush
      file.fsync
    end

    def integer_sequence(value)
      number = Integer(value)
      number.positive? ? number : nil
    rescue ArgumentError, TypeError
      nil
    end

    def stringify_keys(value)
      if value.is_a?(Hash)
        return value.each_with_object({}) do |(key, item), result|
          result[key.to_s] = stringify_keys(item)
        end
      end
      return value.map { |item| stringify_keys(item) } if value.is_a?(Array)

      value
    end
  end
end
