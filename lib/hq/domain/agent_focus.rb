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
    MAX_SUBTITLE_LENGTH = 80
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
        validate_changed_subtitles!(normalized, current["sections"])

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
        object!(section, %w[title subtitle icon items completed])
        completed = completed_value(section)
        icon = section["icon"] || "note"
        raise Error, "Unknown Focus icon: #{icon}" unless ICONS.include?(icon)
        items = section["items"]
        raise Error, "Focus section items must be an array" unless items.is_a?(Array)
        count += items.length
        raise Error, "Focus has more than #{MAX_ITEMS} items" if count > MAX_ITEMS
        {
          "title" => text(section["title"], required: true),
          "subtitle" => subtitle(section["subtitle"]),
          "icon" => icon,
          **(completed ? { "completed" => true } : {}),
          "items" => items.map { |item| normalize_item(item, check_files:) }
        }
      end
      raise Error, "Focus exceeds #{MAX_BYTES} bytes" if JSON.generate(normalized).bytesize > MAX_BYTES
      normalized
    end

    def normalize_item(item, check_files:)
      object!(item, %w[title subtitle attachments completed])
      completed = completed_value(item)
      attachments = item["attachments"] || []
      raise Error, "Focus item must have at most 10 attachments" unless attachments.is_a?(Array) && attachments.length <= 10
      {
        "title" => text(item["title"], required: true),
        "subtitle" => subtitle(item["subtitle"]),
        **(completed ? { "completed" => true } : {}),
        "attachments" => attachments.map { |attachment| normalize_attachment(attachment, check_files:) }
      }
    end

    def completed_value(entry)
      return false unless entry.key?("completed")
      return entry["completed"] if [true, false].include?(entry["completed"])

      raise Error, "Focus completion must be a boolean"
    end

    def subtitle(value)
      text(value)
    end

    def validate_changed_subtitles!(sections, current_sections)
      validate_entry_subtitles!(sections, current_sections, :section)

      new_items = sections.flat_map do |section|
        parent_identity = entry_identity(section, :section)
        section["items"].map { |item| [parent_identity, item] }
      end
      current_items = current_sections.flat_map do |section|
        parent_identity = entry_identity(section, :section)
        section["items"].map { |item| [parent_identity, item] }
      end
      validate_entry_subtitles!(new_items, current_items, :item)
    end

    def validate_entry_subtitles!(entries, current_entries, kind)
      matched_current = {}
      new_matches = {}
      current_by_identity = Hash.new { |hash, key| hash[key] = [] }
      new_identity_counts = Hash.new(0)
      current_entries.each_with_index do |entry, index|
        current_by_identity[entry_identity(entry, kind)] << index
      end
      entries.each { |entry| new_identity_counts[entry_identity(entry, kind)] += 1 }

      # Match exact subtitle values first within each identity group. This keeps
      # duplicate entries one-to-one when callers reorder or copy their data.
      entries.each_with_index do |entry, new_index|
        identity = entry_identity(entry, kind)
        candidates = current_by_identity[identity]
        next if candidates.empty?

        match = candidates.find do |current_index|
          !matched_current[current_index] && entry_subtitle(current_entries[current_index], kind) == entry_subtitle(entry, kind)
        end
        next unless match

        matched_current[match] = true
        new_matches[new_index] = match
      end

      # Match remaining entries by identity. This records changed subtitles as
      # changes to that entry, even when its array position has changed.
      entries.each_with_index do |entry, new_index|
        next if new_matches.key?(new_index)

        match = current_by_identity[entry_identity(entry, kind)].find { |index| !matched_current[index] }
        next unless match

        matched_current[match] = true
        new_matches[new_index] = match
      end

      entries.each_with_index do |entry, new_index|
        value = entry_subtitle(entry, kind)
        next if value.nil? || value.length <= MAX_SUBTITLE_LENGTH

        identity = entry_identity(entry, kind)
        # No stable IDs exist for legacy entries. Do not grant an exception
        # when duplicate identities make the source entry ambiguous.
        if current_by_identity[identity].length != 1 || new_identity_counts[identity] != 1
          raise Error, "Focus subtitles over 80 characters are ambiguous for duplicate entries"
        end
        current_index = new_matches[new_index]
        next if current_index && entry_subtitle(current_entries[current_index], kind) == value

        raise Error, "Focus subtitles must be 80 characters or fewer"
      end
    end

    def entry_identity(entry, kind)
      if kind == :section
        JSON.generate("title" => entry["title"], "icon" => entry["icon"])
      else
        parent_identity, item = entry
        JSON.generate("parent" => parent_identity, "title" => item["title"], "attachments" => item["attachments"])
      end
    end

    def entry_subtitle(entry, kind)
      kind == :section ? entry["subtitle"] : entry.last["subtitle"]
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
