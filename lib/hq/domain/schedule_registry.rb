# frozen_string_literal: true

require "time"
require "yaml"

require_relative "constants"
require_relative "file_store"

module HQ
  class CronExpression
    Field = Struct.new(:values, :wildcard, keyword_init: true)

    FIELD_RANGES = [
      [0, 59],
      [0, 23],
      [1, 31],
      [1, 12],
      [0, 7]
    ].freeze

    attr_reader :source

    def initialize(source)
      @source = source.to_s.strip
      parts = @source.split(/\s+/)
      raise ArgumentError, "expected 5 fields" unless parts.length == 5

      @fields = parts.each_with_index.map do |part, index|
        parse_field(part, *FIELD_RANGES.fetch(index), day_of_week: index == 4)
      end
    end

    def next_after(time)
      candidate = minute_after(time)
      (366 * 24 * 60).times do
        return candidate if match?(candidate)

        candidate += 60
      end
      raise ArgumentError, "no matching time found within 366 days"
    end

    def match?(time)
      minute, hour, day, month, wday = @fields
      return false unless minute.values.include?(time.min)
      return false unless hour.values.include?(time.hour)
      return false unless month.values.include?(time.month)

      dom_match = day.values.include?(time.day)
      dow_match = wday.values.include?(time.wday)
      if !day.wildcard && !wday.wildcard
        dom_match || dow_match
      else
        dom_match && dow_match
      end
    end

    private

    def minute_after(time)
      base = Time.new(time.year, time.month, time.day, time.hour, time.min, 0, time.utc_offset)
      base <= time ? base + 60 : base
    end

    def parse_field(source, min, max, day_of_week: false)
      text = source.to_s.strip
      raise ArgumentError, "empty field" if text.empty?

      wildcard = text == "*" || text.start_with?("*/")
      values = text.split(",").flat_map do |part|
        expand_part(part, min, max, day_of_week:)
      end.uniq.sort
      values.map! { |value| day_of_week && value == 7 ? 0 : value }
      values.uniq!
      Field.new(values:, wildcard:)
    end

    def expand_part(part, min, max, day_of_week:)
      base, step_text = part.split("/", 2)
      step = step_text ? integer!(step_text, min: 1, max:) : 1
      range = if base == "*"
                (min..max)
              elsif base.include?("-")
                first, last = base.split("-", 2).map { |value| integer!(value, min:, max:) }
                raise ArgumentError, "invalid range #{base.inspect}" if first > last

                (first..last)
              else
                value = integer!(base, min:, max:)
                (value..value)
              end

      range.step(step).to_a
    end

    def integer!(value, min:, max:)
      text = value.to_s
      raise ArgumentError, "unsupported token #{text.inspect}" unless text.match?(/\A\d+\z/)

      number = text.to_i
      raise ArgumentError, "#{number} outside #{min}-#{max}" if number < min || number > max

      number
    end
  end

  ScheduleDefinition = Struct.new(
    :key, :name, :enabled, :cron, :timezone, :project_key, :agent_name,
    :system_message, :message_source, :message, :message_file, :message_path, :policy,
    keyword_init: true
  ) do
    def cron_expression
      @cron_expression ||= CronExpression.new(cron)
    end

    def enabled?
      true
    end

    def local_time(time)
      timezone.to_s == "UTC" ? time.getutc : time.getlocal
    end

    def next_due_after(time)
      cron_expression.next_after(local_time(time))
    end

    def message_text
      return message.to_s if message_source == "inline"

      File.read(message_path)
    end

    def overlap_policy
      "skip"
    end

    def missed_policy
      "run_once_on_start"
    end

    def archive_previous_agent?
      true
    end
  end

  class ScheduleRegistry
    Error = Class.new(StandardError)

    attr_reader :path, :projects, :schedules_root

    def initialize(path: SCHEDULES_FILE, projects:, schedules_root: nil)
      @path = File.expand_path(path)
      @projects = projects
      @schedules_root = File.expand_path(schedules_root || USER_SCHEDULES_DIR)
    end

    def schedules
      @schedules ||= load_schedules
    end

    def find(key)
      schedules.find { |schedule| schedule.key == key.to_s }
    end

    def create(attrs)
      data = load_yaml
      entries = schedule_entries(data)
      entry = schedule_entry_from_attrs(attrs)
      entries << entry
      validated = validate_entries!(entries)
      data["schedules"] = entries
      write_yaml(data)
      @schedules = validated
      find(entry.fetch("key"))
    end

    def update(key, attrs)
      values = stringify_keys(attrs || {})
      data = load_yaml
      entries = schedule_entries(data)
      index = entries.index { |entry| entry.is_a?(Hash) && entry["key"].to_s == key.to_s }
      raise Error, "Unknown schedule: #{key}" unless index

      if values.key?("key") && values["key"].to_s.strip != key.to_s
        raise Error, "Schedule key cannot be changed"
      end

      entries[index] = schedule_entry_from_attrs(values, existing: entries[index], key: key)
      validated = validate_entries!(entries)
      data["schedules"] = entries
      write_yaml(data)
      @schedules = validated
      find(key)
    end

    def delete(key)
      data = load_yaml
      entries = schedule_entries(data)
      original_count = entries.length
      entries = entries.reject { |entry| entry.is_a?(Hash) && entry["key"].to_s == key.to_s }
      raise Error, "Unknown schedule: #{key}" if entries.length == original_count

      validated = validate_entries!(entries)
      data["schedules"] = entries
      write_yaml(data)
      @schedules = validated
      true
    end

    def persist_system_message(key, system_message)
      message = system_message.to_s.strip
      return false if message.empty?

      data = load_yaml
      entries = schedule_entries(data)
      index = entries.index { |entry| entry.is_a?(Hash) && entry["key"].to_s == key.to_s }
      raise Error, "Unknown schedule: #{key}" unless index

      entry = entries[index]
      target = stringify_keys(entry["target"] || {})
      return false if target["system_message"].to_s.strip == message

      target["system_message"] = message
      entry["target"] = target
      entries[index] = entry
      validated = validate_entries!(entries)
      data["schedules"] = entries
      write_yaml(data)
      @schedules = validated
      true
    end

    private

    def load_schedules
      data = load_yaml
      entries = schedule_entries(data)
      validate_entries!(entries)
    end

    def validate_entries!(entries)
      seen = {}
      entries.each_with_index.map do |entry, index|
        schedule = build_schedule(entry || {}, index:)
        raise Error, "Duplicate schedule key #{schedule.key.inspect}" if seen[schedule.key]

        seen[schedule.key] = true
        schedule
      end
    end

    def schedule_entries(data)
      Array(data["schedules"]).map { |entry| stringify_keys(entry) }
    end

    def load_yaml
      return { "schedules" => [] } unless File.exist?(@path)

      parsed = YAML.safe_load_file(@path, aliases: true) || {}
      raise Error, "#{@path} must contain a YAML mapping" unless parsed.is_a?(Hash)

      parsed
    rescue Psych::SyntaxError => e
      raise Error, "Invalid schedules YAML: #{e.message}"
    end

    def write_yaml(data)
      FileStore.write_yaml(@path, data)
    end

    def schedule_entry_from_attrs(attrs, existing: nil, key: nil)
      values = stringify_keys(attrs || {})
      entry = stringify_keys(existing || {})
      target = stringify_keys(entry["target"] || {})

      entry["key"] = key.to_s.empty? ? clean_string(values["key"], fallback: entry["key"]) : key.to_s
      assign_clean_string(entry, "name", values, fallback: entry["name"])
      entry.delete("enabled")
      assign_clean_string(entry, "cron", values, fallback: entry["cron"])
      assign_clean_string(entry, "timezone", values, fallback: entry["timezone"] || "local")

      target["type"] = "agent"
      assign_clean_string(target, "project_key", values, fallback: target["project_key"])
      assign_clean_string(target, "name", values, source_key: "agent_name", fallback: target["name"])
      assign_clean_string(target, "system_message", values, fallback: target["system_message"])
      source = clean_string(values["message_source"], fallback: target["message_source"])
      source = target["message_file"].to_s.empty? ? "inline" : "file" if source.to_s.empty?
      target["message_source"] = source
      if source == "file"
        assign_clean_string(target, "message_file", values, fallback: target["message_file"])
        target.delete("message")
      else
        target["message_source"] = "inline"
        assign_clean_string(target, "message", values, fallback: target["message"])
        target.delete("message_file")
      end
      entry["target"] = target

      entry.delete("policy")
      entry
    end

    def stringify_keys(value)
      case value
      when Hash
        value.each_with_object({}) { |(key, item), hash| hash[key.to_s] = stringify_keys(item) }
      when Array
        value.map { |item| stringify_keys(item) }
      else
        value
      end
    end

    def assign_clean_string(target, field, values, source_key: field, fallback: nil)
      value = clean_string(values[source_key], fallback:)
      value.to_s.empty? ? target.delete(field) : target[field] = value
    end

    def assign_bool(target, field, values, fallback:)
      raw = values.key?(field) ? values[field] : fallback
      target[field] = boolean_value(raw)
    end

    def clean_string(value, fallback: nil)
      candidate = value.nil? ? fallback : value
      candidate.to_s.strip
    end

    def boolean_value(value)
      return value if value == true || value == false

      !%w[false 0 no off].include?(value.to_s.strip.downcase)
    end

    def build_schedule(entry, index:)
      raise Error, "Schedule ##{index + 1} must be a mapping" unless entry.is_a?(Hash)

      key = required_string(entry, "key", label: "schedule ##{index + 1}")
      target = entry["target"]
      raise Error, "Schedule #{key.inspect} target must be a mapping" unless target.is_a?(Hash)
      type = target["type"].to_s
      raise Error, "Schedule #{key.inspect} only supports target.type agent" unless type == "agent"

      cron = required_string(entry, "cron", label: "schedule #{key.inspect}")
      validate_cron!(key, cron)
      timezone = entry.fetch("timezone", "local").to_s
      validate_timezone!(key, timezone)

      project_key = required_string(target, "project_key", label: "schedule #{key.inspect} target")
      project_for!(key, project_key)
      source, message, message_file, message_path = message_fields!(key, target)
      policy = normalize_policy!(key, entry["policy"])

      ScheduleDefinition.new(
        key: key,
        name: optional_string(entry["name"], fallback: key),
        enabled: entry.key?("enabled") ? entry["enabled"] != false : true,
        cron: cron,
        timezone: timezone,
        project_key: project_key,
        agent_name: optional_string(target["name"], fallback: entry["name"] || key),
        system_message: optional_string(target["system_message"], fallback: nil),
        message_source: source,
        message: message,
        message_file: message_file,
        message_path: message_path,
        policy: policy
      )
    end

    def validate_cron!(key, cron)
      CronExpression.new(cron)
    rescue ArgumentError => e
      raise Error, "Schedule #{key.inspect} has invalid cron: #{e.message}"
    end

    def validate_timezone!(key, timezone)
      return if %w[local UTC].include?(timezone)

      raise Error, "Schedule #{key.inspect} timezone must be local or UTC"
    end

    def project_for!(schedule_key, project_key)
      project = @projects.find { |candidate| candidate.key == project_key }
      return project if project

      raise Error, "Schedule #{schedule_key.inspect} references unknown project #{project_key.inspect}"
    end

    def message_fields!(key, target)
      source = target["message_source"].to_s.strip
      raise Error, "Schedule #{key.inspect} message_source must be inline or file" unless source.empty? || %w[inline file].include?(source)

      if source == "file" || target.key?("message_file")
        message_file = required_string(target, "message_file", label: "schedule #{key.inspect} target")
        path = resolve_message_path!(key, message_file)
        return ["file", nil, message_file, path]
      end

      message = required_string(target, "message", label: "schedule #{key.inspect} target")
      ["inline", message, nil, nil]
    end

    def resolve_message_path!(key, message_file)
      value = message_file.to_s
      if value.start_with?("/") || value.split("/").include?("..") || !value.start_with?("schedules/")
        raise Error, "Schedule #{key.inspect} message_file must be a relative path under schedules/"
      end

      path = File.expand_path(value.delete_prefix("schedules/"), @schedules_root)
      root = File.join(@schedules_root, "")
      unless path.start_with?(root)
        raise Error, "Schedule #{key.inspect} message_file must stay inside schedules/"
      end
      raise Error, "Schedule #{key.inspect} message_file does not exist: #{message_file}" unless File.file?(path)

      path
    end

    def normalize_policy!(key, value)
      policy = value.is_a?(Hash) ? value.transform_keys(&:to_s) : {}
      {
        "overlap" => "skip",
        "missed" => "run_once_on_start",
        "archive_previous_agent" => true
      }
    end

    def required_string(hash, field, label:)
      value = hash[field].to_s.strip
      raise Error, "#{label} requires #{field}" if value.empty?

      value
    end

    def optional_string(value, fallback:)
      text = value.to_s.strip
      text.empty? ? fallback.to_s : text
    end

  end
end
