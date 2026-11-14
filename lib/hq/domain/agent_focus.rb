# frozen_string_literal: true

require "json"
require "time"
require "uri"
require_relative "file_store"

module HQ
  # A current-state document, independent of run results and the transcript.
  class AgentFocus
    class Error < StandardError; end
    class Conflict < Error; end

    MAX_BYTES = 128 * 1024
    MAX_SECTIONS = 20
    MAX_ITEMS = 100
    ICONS = %w[todo_done todo_working todo_pending blocked note].freeze

    def initialize(agent)
      @agent = agent
      @path = agent.focus_path
    end

    def read
      return empty unless File.exist?(@path)

      value = JSON.parse(File.read(@path, encoding: "UTF-8"))
      unless value.is_a?(Hash) && value["revision"].is_a?(Integer) && value["revision"] >= 0 && value["sections"].is_a?(Array)
        raise Error, "Invalid saved Focus document"
      end
      value.merge("sections" => normalize(value["sections"], check_files: false))
    rescue JSON::ParserError, EncodingError
      raise Error, "Cannot read saved Focus document; preserve the file before repair"
    end

    def replace(sections, expected_revision:)
      raise Error, "Archived agent Focus is read-only" if @agent.archived?
      raise Error, "Focus revision must be a non-negative integer" unless expected_revision.is_a?(Integer) && expected_revision >= 0

      normalized = normalize(sections)
      FileUtils.mkdir_p(File.dirname(@path))
      File.open("#{@path}.lock", File::RDWR | File::CREAT, 0o600) do |lock|
        lock.flock(File::LOCK_EX)
        current = read
        # A lost-response retry is safe, but a stale different write is rejected.
        return current if current["sections"] == normalized && [current["revision"], current["revision"] - 1].include?(expected_revision)
        raise Conflict, "Focus changed; read the current revision before updating" unless current["revision"] == expected_revision

        result = { "revision" => current["revision"] + 1, "updated_at" => Time.now.utc.iso8601(6), "sections" => normalized }
        FileStore.write_json(@path, result)
        result
      end
    end

    private

    def empty
      { "revision" => 0, "updated_at" => nil, "sections" => [] }
    end

    def normalize(sections, check_files: true)
      raise Error, "Focus must contain at most #{MAX_SECTIONS} sections" unless sections.is_a?(Array) && sections.length <= MAX_SECTIONS
      raise Error, "Focus exceeds #{MAX_BYTES} bytes" if JSON.generate(sections).bytesize > MAX_BYTES
      count = 0
      normalized = sections.map do |section|
        object!(section, %w[title subtitle icon items])
        icon = section["icon"] || "note"
        raise Error, "Unknown Focus icon: #{icon}" unless ICONS.include?(icon)
        items = section["items"]
        raise Error, "Focus section items must be an array" unless items.is_a?(Array)
        count += items.length
        raise Error, "Focus has more than #{MAX_ITEMS} items" if count > MAX_ITEMS
        {
          "title" => text(section["title"], required: true),
          "subtitle" => text(section["subtitle"]),
          "icon" => icon,
          "items" => items.map { |item| normalize_item(item, check_files:) }
        }
      end
      raise Error, "Focus exceeds #{MAX_BYTES} bytes" if JSON.generate(normalized).bytesize > MAX_BYTES
      normalized
    end

    def normalize_item(item, check_files:)
      object!(item, %w[title subtitle attachments])
      attachments = item["attachments"] || []
      raise Error, "Focus item must have at most 10 attachments" unless attachments.is_a?(Array) && attachments.length <= 10
      {
        "title" => text(item["title"], required: true),
        "subtitle" => text(item["subtitle"]),
        "attachments" => attachments.map { |attachment| normalize_attachment(attachment, check_files:) }
      }
    end

    def normalize_attachment(attachment, check_files:)
      object!(attachment, %w[type title url path])
      title = text(attachment["title"], required: true)
      case attachment["type"]
      when "link"
        url = attachment["url"]
        uri = URI.parse(url.to_s)
        unless url.is_a?(String) && url.length <= 4096 && %w[http https].include?(uri.scheme) && uri.host && !uri.userinfo
          raise Error, "Focus links require an HTTP or HTTPS URL without credentials"
        end
        { "type" => "link", "title" => title, "url" => url }
      when "file"
        path = attachment["path"]
        unless path.is_a?(String) && (!check_files || @agent.attachments.any? { |entry| entry["path"] == path && entry["type"] != "link" })
          raise Error, "Focus files must reference an existing agent attachment path"
        end
        { "type" => "file", "title" => title, "path" => path }
      else
        raise Error, "Focus attachment type must be link or file"
      end
    rescue URI::InvalidURIError
      raise Error, "Invalid Focus attachment URL"
    end

    def object!(value, keys)
      raise Error, "Focus entries must be objects with supported fields: #{keys.join(", ")}" unless value.is_a?(Hash) && (value.keys - keys).empty?
    end

    def text(value, required: false)
      return nil if value.nil? && !required
      unless value.is_a?(String) && value.length <= 2000 && (!required || !value.strip.empty?)
        raise Error, "Focus text must be a string of at most 2000 characters; titles must not be empty"
      end
      value
    end
  end
end
