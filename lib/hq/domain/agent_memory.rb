# frozen_string_literal: true

require "json"
require "fileutils"
require "time"

require_relative "attachment_normalizer"
require_relative "agent_event_journal"
require_relative "file_store"
require_relative "../log_file_reader"

module HQ
  class AgentMemory
    def initialize(agent)
      @agent = agent
    end

    def path
      @agent.memory_path
    end

    def attachments_path
      if @agent.respond_to?(:attachments_path)
        @agent.attachments_path
      else
        path.to_s.sub(/\.memory\.jsonl\z/, ".attachments.json")
      end
    end

    def exists?
      File.exist?(path)
    end

    def conversation_messages
      events = read_events
      messages = []

      system_prompt_events(events).each do |event|
        messages << {
          role: "system",
          content: event["content"].to_s,
          created_at: parse_time(event["created_at"])
        }
      end

      events.each do |event|
        next unless %w[user_message assistant_message].include?(event["type"])

        messages << {
          role: event["type"] == "assistant_message" ? "assistant" : "user",
          content: event["content"].to_s,
          created_at: parse_time(event["created_at"]),
          metadata: message_metadata_for(event)
        }
      end

      messages
    end

    def prompt_messages
      events = read_events
      messages = []

      system_prompt_events(events).each do |event|
        messages << {
          role: "system",
          content: event["content"].to_s,
          created_at: parse_time(event["created_at"])
        }
      end

      if (inquiry = unresolved_inquiry_event(events))
        text = format_inquiry_context(inquiry)
        unless text.empty?
          messages << {
            role: "system",
            content: text,
            created_at: parse_time(inquiry["created_at"])
          }
        end
      end

      events.each do |event|
        case event["type"]
        when "user_message"
          messages << {
            role: "user",
            content: event["content"].to_s,
            created_at: parse_time(event["created_at"]),
            metadata: message_metadata_for(event)
          }
        when "assistant_message"
          messages << {
            role: "assistant",
            content: event["content"].to_s,
            created_at: parse_time(event["created_at"]),
            metadata: message_metadata_for(event)
          }
        when "tool_summary"
          text = event["content"].to_s.strip
          next if text.empty?

          messages << {
            role: "system",
            content: "tool: #{text}",
            created_at: parse_time(event["created_at"])
          }
        when "run_summary"
          text = event["content"].to_s.strip
          next if text.empty?

          status = event["status"].to_s.strip
          line = status.empty? ? text : "#{status}: #{text}"
          messages << {
            role: "system",
            content: "run summary — #{line}",
            created_at: parse_time(event["created_at"])
          }
        end
      end

      messages
    end

    def latest_inquiry(fallback: nil)
      inquiry = latest_inquiry_event(fallback:)
      return fallback if inquiry.equal?(fallback)
      return nil if inquiry.nil?

      metadata = inquiry["metadata"]
      metadata.is_a?(Hash) ? metadata["inquiry"] : nil
    rescue StandardError
      fallback
    end

    def latest_inquiry_event(fallback: nil)
      events = read_events
      has_request = events.any? { |event| event["type"] == "inquiry_request" }
      has_lifecycle = events.any? { |event| inquiry_lifecycle_event?(event) }
      return fallback unless has_request || has_lifecycle

      active_inquiry_event(events)
    rescue StandardError
      fallback
    end

    def suspended_inquiry
      event = suspended_inquiry_event
      return nil unless event

      metadata = event["metadata"]
      metadata.is_a?(Hash) ? metadata["inquiry"] : nil
    rescue StandardError
      nil
    end

    def suspended_inquiry_event
      suspended_inquiry_event_from(read_events)
    rescue StandardError
      nil
    end

    def suspended_inquiry_id
      event = suspended_inquiry_event
      event ? inquiry_id_for_event(event) : nil
    rescue StandardError
      nil
    end

    def latest_inquiry_id(fallback: nil)
      inquiry = latest_inquiry_event(fallback:)
      return fallback if inquiry.equal?(fallback)
      return nil unless inquiry

      inquiry_id_for_event(inquiry)
    rescue StandardError
      fallback
    end

    def events
      read_events
    end

    def attachments
      events = read_events.flat_map { |event| attachments_for_event(event) }
      dedupe_attachments(read_attachment_records + events)
    rescue StandardError
      []
    end

    def latest_user_message_after(time, ignored_metadata: nil, inclusive: false)
      threshold = time.is_a?(Time) ? time : nil
      read_events.reverse_each do |event|
        next unless event["type"] == "user_message"
        next if metadata_matches?(event["metadata"], ignored_metadata)

        event_time = parse_time(event["created_at"])
        next if threshold && event_time && (inclusive ? event_time < threshold : event_time <= threshold)

        text = event["content"].to_s.strip
        return message_with_attachment_context(text, event) unless text.empty?
      end

      nil
    rescue StandardError
      nil
    end

    def user_message_with_metadata(expected)
      read_events.reverse_each do |event|
        next unless event["type"] == "user_message"
        next unless metadata_matches?(event["metadata"], expected)

        text = event["content"].to_s.strip
        return message_with_attachment_context(text, event) unless text.empty?
      end

      nil
    rescue StandardError
      nil
    end

    def append_system_prompt!(content, created_at: Time.now, prompt_role: nil)
      text = content.to_s
      return if text.empty?

      append_event!(
        "type" => "system_prompt",
        "content" => text,
        "created_at" => created_at.iso8601,
        "pinned" => true,
        "metadata" => prompt_role.to_s.empty? ? nil : { "prompt_role" => prompt_role.to_s }
      )
    end

    def replace_system_prompt!(previous_content, content, created_at: Time.now)
      previous_text = previous_content.to_s
      text = content.to_s
      return if text.empty?

      events = read_events
      matching_indexes = events.each_index.select do |index|
        event = events[index]
        event["type"] == "system_prompt" && event.dig("metadata", "prompt_role") == "base"
      end
      matching_indexes = events.each_index.select do |index|
        event = events[index]
        event["type"] == "system_prompt" && event["content"].to_s == previous_text
      end if matching_indexes.empty?
      return append_system_prompt!(text, created_at:, prompt_role: "base") if matching_indexes.empty?

      replacement_index = matching_indexes.last
      next_events = events.each_with_index.filter_map do |event, index|
        next event unless matching_indexes.include?(index)
        next unless index == replacement_index

        event.merge(
          "content" => text,
          "created_at" => created_at.iso8601,
          "pinned" => true,
          "metadata" => { "prompt_role" => "base" }
        )
      end
      write_events!(next_events)
    end

    def prepend_system_prompt_once!(content, created_at: Time.now, prompt_role: nil)
      text = content.to_s
      return false if text.empty?

      events = read_events
      return false if events.any? { |event| event["type"] == "system_prompt" && event["content"].to_s == text }

      event = {
        "type" => "system_prompt",
        "content" => text,
        "created_at" => created_at.iso8601,
        "pinned" => true,
        "metadata" => prompt_role.to_s.empty? ? nil : { "prompt_role" => prompt_role.to_s }
      }
      write_events!([event] + events)
      true
    rescue StandardError
      false
    end

    def append_user_message!(content, created_at: Time.now, attachments: nil, metadata: nil)
      text = content.to_s.strip
      return if text.empty?

      normalized_attachments = normalize_attachments(attachments)
      event_metadata = metadata.is_a?(Hash) ? metadata.dup : {}
      event_metadata.merge!(attachment_metadata(normalized_attachments) || {})
      append_attachment_records!(normalized_attachments, created_at:) if normalized_attachments.any?
      append_event!(
        "type" => "user_message",
        "content" => text,
        "created_at" => created_at.iso8601,
        "metadata" => event_metadata.empty? ? nil : event_metadata
      )
    end

    def append_assistant_message!(content, created_at: Time.now, metadata: nil)
      text = content.to_s.strip
      return if text.empty?

      append_event!(
        "type" => "assistant_message",
        "content" => text,
        "created_at" => created_at.iso8601,
        "metadata" => metadata.is_a?(Hash) && !metadata.empty? ? metadata : nil
      )
    end

    def append_tool_summary!(content, tool_name:, created_at: Time.now, metadata: nil)
      text = content.to_s.strip
      return if text.empty?

      append_event!(
        "type" => "tool_summary",
        "content" => text,
        "created_at" => created_at.iso8601,
        "metadata" => {
          "tool_name" => tool_name.to_s,
          "details" => metadata
        }.compact
      )
    end

    def append_token_usage!(content, created_at: Time.now, metadata: nil)
      text = content.to_s.strip
      return if text.empty?

      append_event!(
        "type" => "token_usage",
        "content" => text,
        "created_at" => created_at.iso8601,
        "metadata" => metadata.is_a?(Hash) && !metadata.empty? ? metadata : nil
      )
    end

    def append_validation_retry!(content, created_at: Time.now, metadata: nil)
      text = content.to_s.strip
      return if text.empty?

      append_event!(
        "type" => "validation_retry",
        "content" => text,
        "created_at" => created_at.iso8601,
        "metadata" => metadata.is_a?(Hash) && !metadata.empty? ? metadata : nil
      )
    end

    def append_delegation_event!(content, event_id:, created_at: Time.now, metadata: nil)
      text = content.to_s.strip
      id = event_id.to_s.strip
      return false if text.empty? || id.empty?

      append_unique_event!(id,
                           "type" => "delegation_event",
                           "content" => text,
                           "created_at" => created_at.iso8601,
                           "metadata" => (metadata.is_a?(Hash) ? metadata : {}).merge("event_id" => id))
    end

    def append_delegation_report!(content, report_id:, created_at: Time.now, metadata: nil)
      text = content.to_s.strip
      id = report_id.to_s.strip
      return false if text.empty? || id.empty?

      append_unique_event!(id,
                           "type" => "user_message",
                           "content" => text,
                           "created_at" => created_at.iso8601,
                           "metadata" => (metadata.is_a?(Hash) ? metadata : {}).merge(
                             "delegation_callback" => true,
                             "event_id" => id
                           ))
    end

    def append_run_summary!(summary:, status:, created_at: Time.now, metadata: nil, event_id: nil)
      text = summary.to_s.strip
      return if text.empty?

      append_event!({
        "type" => "run_summary",
        "content" => text,
        "status" => status.to_s,
        "created_at" => created_at.iso8601,
        "metadata" => metadata
      }, event_id:)
    end

    def append_run_started!(run_id:, created_at: Time.now)
      id = run_id.to_s.strip
      return if id.empty?

      append_event!({
        "type" => "run_started",
        "content" => "Run started",
        "run_id" => id,
        "created_at" => created_at.iso8601
      }, event_id: "#{id}:run-started")
    end

    def append_inquiry_request!(inquiry, created_at: Time.now, inquiry_id: nil)
      return unless inquiry.is_a?(Hash)

      message = inquiry["message"].to_s.strip
      return if message.empty?

      metadata = { "inquiry" => inquiry }
      id = inquiry_id.to_s.strip
      metadata["inquiry_id"] = id unless id.empty?

      append_event!(
        "type" => "inquiry_request",
        "content" => message,
        "created_at" => created_at.iso8601,
        "metadata" => metadata
      )
    end

    def append_inquiry_response!(content, created_at: Time.now, inquiry_id: nil)
      text = content.to_s.strip
      return if text.empty?

      metadata = {}
      id = inquiry_id.to_s.strip
      metadata["inquiry_id"] = id unless id.empty?
      begin
        parsed = JSON.parse(text)
        metadata["response"] = parsed if parsed.is_a?(Hash)
      rescue JSON::ParserError
        nil
      end

      append_event!(
        "type" => "inquiry_response",
        "content" => text,
        "created_at" => created_at.iso8601,
        "metadata" => metadata.empty? ? nil : metadata
      )
    end

    def append_inquiry_cancelled!(created_at: Time.now, inquiry_id: nil)
      id = inquiry_id.to_s.strip
      return if id.empty?

      append_event!(
        "type" => "inquiry_cancelled",
        "content" => "Inquiry cancelled by a new parent prompt",
        "created_at" => created_at.iso8601,
        "metadata" => { "inquiry_id" => id }
      )
    end

    def append_inquiry_suspended!(created_at: Time.now, inquiry_id: nil)
      append_inquiry_lifecycle!("inquiry_suspended", "Inquiry dismissed", created_at:, inquiry_id:)
    end

    def append_inquiry_restored!(created_at: Time.now, inquiry_id: nil)
      append_inquiry_lifecycle!("inquiry_restored", "Inquiry restored", created_at:, inquiry_id:)
    end

    def append_inquiry_retired!(created_at: Time.now, inquiry_id: nil)
      append_inquiry_lifecycle!("inquiry_retired", "Inquiry retired by an ordinary prompt", created_at:, inquiry_id:)
    end

    def append_attachment!(attachment, created_at: Time.now)
      attachment = normalize_attachments([attachment]).first
      return unless attachment.is_a?(Hash)

      title = attachment["title"].to_s.strip
      target = AttachmentNormalizer.attachment_target(attachment)
      return if title.empty? && target.empty?

      event = {
        "type" => "attachment",
        "content" => title.empty? ? target : title,
        "created_at" => created_at.iso8601,
        "metadata" => {
          "attachment" => attachment
        }
      }
      append_attachment_record!(attachment, created_at:)
      append_event!(event)
    end

    def delete_attachment!(attachment)
      target_key = attachment_dedupe_key(attachment)
      return false unless target_key

      changed = delete_attachment_records!(target_key)
      events = read_events
      next_events = []
      events_changed = false

      events.each do |event|
        next_event = delete_attachment_from_event(event, target_key)
        events_changed = true unless next_event == event
        next_events << next_event if next_event
      end

      if events_changed
        write_events!(next_events)
        changed = true
      end

      changed
    end

    def write_events!(events)
      journal.replace(events)
    end

    private

    def read_events
      journal.events
    end

    def append_event!(event = nil, event_id: nil, **attributes)
      event ||= attributes
      journal.append(event, event_id:)
    rescue StandardError
      nil
    end

    def append_unique_event!(event_id, event)
      journal.append_unique(event.merge("event_id" => event_id), event_id:)
    rescue StandardError => e
      raise IOError, "Failed to append durable agent event: #{e.message}"
    end

    def journal
      @journal ||= AgentEventJournal.new(path)
    end

    def read_attachment_records
      parsed = FileStore.read_json(attachments_path, fallback: [])
      records = parsed.is_a?(Hash) ? parsed["attachments"] : parsed
      Array(records).filter_map do |record|
        next unless record.is_a?(Hash)

        attachment = record["attachment"]
        if attachment.is_a?(Hash)
          attachment = attachment.dup
          attachment["created_at"] ||= record["created_at"] if record["created_at"]
          attachment
        else
          record
        end
      end
    rescue StandardError => e
      HQ.logger.warn("AgentMemory") { "Failed to load attachment records from #{attachments_path}: #{e.class} - #{e.message}" }
      []
    end

    def append_attachment_record!(attachment, created_at:)
      append_attachment_records!([attachment], created_at:)
    end

    def append_attachment_records!(attachments, created_at:)
      created_at = parse_time(created_at) || Time.now
      records_to_append = normalize_attachments(attachments).map do |attachment|
        attachment.merge("created_at" => attachment["created_at"] || created_at.iso8601)
      end
      return if records_to_append.empty?

      records = dedupe_attachments(records_to_append + read_attachment_records)
      FileStore.write_json(attachments_path, { "attachments" => records })
    rescue StandardError
      nil
    end

    def delete_attachment_records!(target_key)
      records = read_attachment_records
      filtered = records.reject { |attachment| attachment_dedupe_key(attachment) == target_key }
      return false if filtered.length == records.length

      if filtered.empty?
        FileUtils.rm_f(attachments_path)
      else
        FileStore.write_json(attachments_path, { "attachments" => filtered })
      end
      true
    rescue StandardError
      false
    end

    def system_prompt_events(events)
      events.select { |event| event["type"] == "system_prompt" && !event["content"].to_s.empty? }
    end

    def attachments_for_event(event)
      case event["type"]
      when "attachment"
        metadata = event["metadata"]
        attachment = metadata.is_a?(Hash) ? metadata["attachment"] : nil
        if attachment.is_a?(Hash)
          [attachment.merge("created_at" => event["created_at"])]
        else
          []
        end
      when "user_message", "assistant_message"
        metadata = event["metadata"]
        return [] unless metadata.is_a?(Hash)

        Array(metadata["attachments"]).select { |attachment| attachment.is_a?(Hash) }
      when "run_summary"
        metadata = event["metadata"]
        return [] unless metadata.is_a?(Hash)

        Array(metadata["attachments"]).select { |attachment| attachment.is_a?(Hash) }
      else
        []
      end
    end

    def delete_attachment_from_event(event, target_key)
      case event["type"]
      when "attachment"
        metadata = event["metadata"]
        attachment = metadata.is_a?(Hash) ? metadata["attachment"] : nil
        attachment_dedupe_key(attachment) == target_key ? nil : event
      when "user_message", "assistant_message", "run_summary"
        delete_attachment_from_metadata_event(event, target_key)
      else
        event
      end
    end

    def delete_attachment_from_metadata_event(event, target_key)
      metadata = event["metadata"]
      return event unless metadata.is_a?(Hash)

      attachments = Array(metadata["attachments"]).select { |attachment| attachment.is_a?(Hash) }
      return event if attachments.empty?

      filtered = attachments.reject { |attachment| attachment_dedupe_key(attachment) == target_key }
      return event if filtered.length == attachments.length

      next_metadata = metadata.dup
      filtered.empty? ? next_metadata.delete("attachments") : next_metadata["attachments"] = filtered
      next_event = event.dup
      next_event["metadata"] = next_metadata.empty? ? nil : next_metadata
      next_event.compact
    end

    def dedupe_attachments(attachments)
      normalize_attachments(attachments)
    end

    def normalize_attachments(attachments)
      AttachmentNormalizer.normalize(attachments, workspace: attachment_workspace)
    end

    def attachment_dedupe_key(attachment)
      normalized = normalize_attachments([attachment]).first
      return nil unless normalized.is_a?(Hash)

      [
        normalized["type"],
        normalized["type"] == "link" ? normalized["url"] : normalized["path"]
      ].map(&:to_s)
    end

    def attachment_metadata(attachments)
      items = normalize_attachments(attachments)
      return nil if items.empty?

      { "attachments" => items }
    end

    def message_metadata_for(event)
      metadata = event["metadata"]
      return nil unless metadata.is_a?(Hash) && !metadata.empty?

      metadata
    end

    def metadata_matches?(metadata, expected)
      return false unless metadata.is_a?(Hash)
      return false unless expected.is_a?(Hash) && !expected.empty?

      expected.all? { |key, value| metadata[key.to_s] == value }
    end

    def message_with_attachment_context(text, event)
      attachments = attachments_for_event(event)
      return text if attachments.empty?

      lines = [
        text,
        "",
        "Attachments are available as files or links. Use the targets below when you need to inspect them:"
      ]
      attachments.each do |attachment|
        title = attachment["title"].to_s.strip
        target = AttachmentNormalizer.attachment_target(attachment)
        title = target if title.empty?
        type = attachment["type"].to_s.strip
        type = AttachmentNormalizer.link_attachment?(attachment) ? "link" : "file" if type.empty?
        details = [type, title].reject(&:empty?).join(" ")
        lines << "- #{details}: #{target}"
      end
      lines.join("\n")
    end

    def attachment_workspace
      @agent.respond_to?(:workspace) ? @agent.workspace : Dir.pwd
    end

    def unresolved_inquiry_event(events)
      active_inquiry_event(events) || suspended_inquiry_event_from(events)
    end

    def active_inquiry_event(events)
      inquiry_event_for_state(events, "active")
    end

    def suspended_inquiry_event_from(events)
      inquiry_event_for_state(events, "suspended")
    end

    def inquiry_event_for_state(events, expected_state)
      inquiry_index = events.rindex { |event| event["type"] == "inquiry_request" }
      return nil unless inquiry_index

      inquiry = events[inquiry_index]
      inquiry_id = inquiry_id_for_event(inquiry)
      lifecycle = Array(events[(inquiry_index + 1)..]).reverse.find do |event|
        next false unless inquiry_lifecycle_event?(event)

        event_id = inquiry_id_for_event(event)
        inquiry_id.to_s.empty? ? event_id.to_s.empty? : event_id == inquiry_id
      end
      inquiry_state_for_lifecycle(lifecycle) == expected_state ? inquiry : nil
    end

    def inquiry_lifecycle_event?(event)
      %w[inquiry_response inquiry_cancelled inquiry_suspended inquiry_restored inquiry_retired].include?(event["type"])
    end

    def inquiry_state_for_lifecycle(event)
      case event&.fetch("type", nil)
      when nil, "inquiry_restored" then "active"
      when "inquiry_suspended" then "suspended"
      else "retired"
      end
    end

    def append_inquiry_lifecycle!(type, content, created_at:, inquiry_id:)
      id = inquiry_id.to_s.strip
      return false if id.empty?

      journal.append({
        "type" => type,
        "content" => content,
        "created_at" => created_at.iso8601,
        "metadata" => { "inquiry_id" => id }
      })
      true
    end

    def format_inquiry_context(event)
      metadata = event["metadata"]
      inquiry = metadata.is_a?(Hash) ? metadata["inquiry"] : nil
      return "" unless inquiry.is_a?(Hash)

      fields = requested_field_labels(inquiry)
      lines = ["Outstanding inquiry from the previous run:", inquiry["message"].to_s.strip]
      lines << "Requested fields: #{fields.join(", ")}" if fields.any?
      lines.join("\n")
    end

    def requested_field_labels(inquiry)
      fields = inquiry["fields"]
      if fields.is_a?(Array)
        labels = fields.filter_map do |field|
          next unless field.is_a?(Hash)

          label = field["label"].to_s.strip
          label = field["key"].to_s.strip if label.empty?
          label unless label.empty?
        end
        return labels unless labels.empty?
      end

      schema = inquiry["requested_schema"]
      return [] unless schema.is_a?(Hash)

      properties = schema["properties"]
      return [] unless properties.is_a?(Hash)

      properties.map do |key, definition|
        next key.to_s unless definition.is_a?(Hash)

        title = definition["title"].to_s.strip
        title.empty? ? key.to_s : title
      end
    end

    def inquiry_id_for_event(event)
      metadata = event["metadata"]
      return nil unless metadata.is_a?(Hash)

      metadata["inquiry_id"].to_s.strip.empty? ? nil : metadata["inquiry_id"].to_s
    end

    def parse_time(value)
      return nil if value.to_s.empty?

      Time.parse(value.to_s)
    rescue StandardError
      nil
    end
  end
end
