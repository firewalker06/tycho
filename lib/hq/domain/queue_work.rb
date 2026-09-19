# frozen_string_literal: true

require "json"
require "securerandom"
require "time"

module HQ
  module QueueWork
    VERSION = 1
    USER_OUTCOMES = %w[completed needs_input declined_with_reason].freeze
    REPORT_OUTCOMES = %w[incorporated superseded_with_reason].freeze
    REASON_OUTCOMES = %w[declined_with_reason superseded_with_reason].freeze
    TERMINAL_STATES = %w[resolved blocked].freeze
    MAX_AUTOMATIC_CONTINUATIONS = 1

    module_function

    def normalize(value, legacy_claim: nil, entry_normalizer: nil)
      source = value.is_a?(Hash) ? value : {}
      batches = Array(source["batches"]).filter_map do |batch|
        normalize_batch(batch, entry_normalizer:)
      end
      active_id = source["active_batch_id"].to_s
      active_id = nil unless batches.any? { |batch| batch["id"] == active_id && !terminal?(batch) }

      if batches.empty? && legacy_claim.is_a?(Hash)
        entries = normalize_entries(legacy_claim["entries"], entry_normalizer:)
        unless entries.empty?
          migrated = build_batch(
            entries,
            id: legacy_claim["id"],
            opened_at: legacy_claim["claimed_at"],
            state: legacy_claim["message_appended"] == true ? "in_progress" : "open"
          )
          migrated["legacy_prompt_queue_claim"] = true
          batches << migrated
          active_id = migrated["id"]
        end
      end

      { "version" => VERSION, "batches" => batches, "active_batch_id" => active_id }.compact
    end

    def normalize_batch(value, entry_normalizer: nil)
      return nil unless value.is_a?(Hash)

      id = value["id"].to_s.strip
      entries = normalize_entries(value["entries"], entry_normalizer:)
      return nil if id.empty? || entries.empty?

      dispositions = normalize_stored_dispositions(value["dispositions"], entries)
      state = value["state"].to_s
      state = dispositions.length == entries.length ? resolved_state(dispositions) : "open" unless
        %w[open in_progress resolved blocked].include?(state)
      state = "open" if TERMINAL_STATES.include?(state) && dispositions.length != entries.length
      result = {
        "id" => id,
        "state" => state,
        "entries" => entries,
        "opened_at" => value["opened_at"].to_s,
        "ownership_stamp" => normalize_ownership_stamp(value["ownership_stamp"]) ||
          normalize_ownership_stamp(entries.last&.fetch("authority", nil)),
        "dispositions" => dispositions,
        "delivery_count" => [value["delivery_count"].to_i, 0].max,
        "automatic_continuation_count" => [value["automatic_continuation_count"].to_i, 0].max,
        "resume_pending" => value["resume_pending"] == true,
        "read_id" => value["read_id"].to_s.empty? ? nil : value["read_id"].to_s,
        "resolved_at" => value["resolved_at"].to_s.empty? ? nil : value["resolved_at"].to_s,
        "legacy_prompt_queue_claim" => value["legacy_prompt_queue_claim"] == true
      }.compact
      result["state"] = resolved_state(dispositions) if dispositions.length == entries.length
      result
    end

    def build_batch(entries, id: SecureRandom.uuid, opened_at: Time.now, state: "open")
      items = Array(entries).map { |entry| deep_copy(entry) }
      {
        "id" => id.to_s,
        "state" => state,
        "entries" => items,
        "opened_at" => timestamp(opened_at),
        "ownership_stamp" => normalize_ownership_stamp(items.last&.fetch("authority", nil)),
        "dispositions" => {},
        "delivery_count" => 0,
        "automatic_continuation_count" => 0,
        "resume_pending" => false
      }.compact
    end

    def active(store)
      id = store.is_a?(Hash) ? store["active_batch_id"].to_s : ""
      return nil if id.empty?

      Array(store["batches"]).find { |batch| batch["id"] == id && !terminal?(batch) }
    end

    def find(store, batch_id)
      Array(store.is_a?(Hash) ? store["batches"] : nil).find { |batch| batch["id"] == batch_id.to_s }
    end

    def terminal?(batch)
      TERMINAL_STATES.include?(batch&.fetch("state", nil).to_s)
    end

    def unresolved_ids(batch)
      dispositions = batch.is_a?(Hash) ? batch.fetch("dispositions", {}) : {}
      Array(batch&.fetch("entries", nil)).filter_map do |entry|
        id = entry["id"].to_s
        id unless dispositions.key?(id)
      end
    end

    def projection(batch)
      entries = Array(batch&.fetch("entries", nil))
      instructions = entries.select { |entry| entry_kind(entry) == "user_instruction" }
      reports = entries.select { |entry| entry_kind(entry) == "delegated_report" }
      {
        "batch_id" => batch&.fetch("id", nil),
        "state" => batch&.fetch("state", nil),
        "user_instruction_count" => instructions.length,
        "report_count" => reports.length,
        "required_actions" => instructions.map { |entry| projected_entry(entry, "required_instruction") },
        "contextual_reports" => reports.map { |entry| projected_entry(entry, "contextual_report") },
        "entry_ids" => entries.map { |entry| entry["id"].to_s },
        "unresolved_entry_ids" => unresolved_ids(batch)
      }
    end

    def payload(batch)
      projection(batch).merge(
        "entries" => Array(batch&.fetch("entries", nil)).map { |entry| deep_copy(entry) },
        "ownership_stamp" => deep_copy(batch&.fetch("ownership_stamp", nil)),
        "dispositions" => deep_copy(batch&.fetch("dispositions", {})),
        "opened_at" => batch&.fetch("opened_at", nil),
        "resolved_at" => batch&.fetch("resolved_at", nil)
      ).compact
    end

    def contract(batch, agent_key:)
      projected = projection(batch)
      machine = {
        "protocol" => "tycho.queue_work/v1",
        "batch_id" => batch.fetch("id"),
        "state" => batch.fetch("state"),
        "user_instruction_count" => projected.fetch("user_instruction_count"),
        "report_count" => projected.fetch("report_count"),
        "entry_ids" => projected.fetch("entry_ids"),
        "unresolved_entry_ids" => projected.fetch("unresolved_entry_ids"),
        "completion_command" => "tycho queue-work complete #{agent_key} #{batch.fetch('id')} --dispositions-json '<JSON_ARRAY>'"
      }
      lines = [
        "[TYCHO QUEUE WORK CONTRACT — REQUIRED]",
        JSON.generate(machine),
        "You own this entire batch. Process every entry. Reading or receiving it does not complete it.",
        "Tycho blocks successful finalization until every stable entry ID has one valid source-appropriate outcome.",
        "",
        "REQUIRED USER INSTRUCTIONS (#{projected.fetch('user_instruction_count')})"
      ]
      projected.fetch("required_actions").each do |entry|
        lines << "- [#{entry.fetch('id')}] #{entry.fetch('prompt')}"
        append_attachment_lines(lines, entry)
      end
      lines << "- None" if projected.fetch("required_actions").empty?
      lines << ""
      lines << "CONTEXTUAL DELEGATED REPORTS (#{projected.fetch('report_count')})"
      projected.fetch("contextual_reports").each do |entry|
        lines << "- [#{entry.fetch('id')}] Delegated callback (structured payload follows unchanged):"
        lines << entry.fetch("prompt")
        append_attachment_lines(lines, entry)
      end
      lines << "- None" if projected.fetch("contextual_reports").empty?
      lines << ""
      lines << "CANONICAL FIFO ENTRY IDS: #{projected.fetch('entry_ids').join(', ')}"
      lines << "Record dispositions before final output with: #{machine.fetch('completion_command')}"
      lines.join("\n")
    end

    def apply_dispositions!(batch, submitted, completed_at: Time.now)
      entries = Array(batch.fetch("entries"))
      prior_state = batch["state"].to_s
      known = entries.to_h { |entry| [entry.fetch("id").to_s, entry] }
      existing = batch["dispositions"].is_a?(Hash) ? batch["dispositions"].dup : {}
      errors = []
      grouped = Array(submitted).group_by { |item| item.is_a?(Hash) ? item["entry_id"].to_s : "" }
      grouped.each do |entry_id, items|
        if entry_id.empty? || !known.key?(entry_id)
          errors << disposition_error("unknown_entry", entry_id, "Unknown queue-work entry")
          next
        end
        if items.length != 1
          errors << disposition_error("duplicate_entry", entry_id, "Submit exactly one outcome per entry")
          next
        end
        normalized, error = normalize_disposition(items.first, known.fetch(entry_id))
        if error
          errors << error
          next
        end
        prior = existing[entry_id]
        if prior && prior != normalized
          errors << disposition_error("conflicting_outcome", entry_id, "An entry already has a different outcome")
          next
        end
        existing[entry_id] = normalized
      end

      batch["dispositions"] = existing
      unresolved = known.keys.reject { |id| existing.key?(id) }
      if unresolved.empty? && (errors.empty? || TERMINAL_STATES.include?(prior_state))
        batch["state"] = resolved_state(existing)
        batch["resolved_at"] ||= timestamp(completed_at)
        batch["resume_pending"] = false
      else
        batch["state"] = "in_progress"
      end
      {
        "accepted" => errors.empty?,
        "batch" => payload(batch),
        "errors" => errors,
        "unresolved_entry_ids" => unresolved
      }
    end

    def mark_delivered!(batch, read_id: nil)
      batch["state"] = "in_progress" unless terminal?(batch)
      batch["delivery_count"] = batch.fetch("delivery_count", 0).to_i + 1
      batch["read_id"] ||= read_id.to_s unless read_id.to_s.empty?
      batch
    end

    def request_automatic_continuation!(batch)
      return false if terminal?(batch)
      return false if batch.fetch("automatic_continuation_count", 0).to_i >= MAX_AUTOMATIC_CONTINUATIONS

      batch["automatic_continuation_count"] = batch.fetch("automatic_continuation_count", 0).to_i + 1
      batch["resume_pending"] = true
      true
    end

    def consume_resume_request!(batch)
      return false unless batch&.fetch("resume_pending", false)

      batch["resume_pending"] = false
      true
    end

    def entry_kind(entry)
      entry["source"].to_s == "delegation_callback" ? "delegated_report" : "user_instruction"
    end

    def normalize_entries(values, entry_normalizer: nil)
      Array(values).filter_map do |entry|
        normalized = entry_normalizer ? entry_normalizer.call(entry) : deep_copy(entry)
        next unless normalized.is_a?(Hash)

        normalized["source"] = normalized["source"].to_s.empty? ? "user" : normalized["source"].to_s
        normalized
      end
    end
    private_class_method :normalize_entries

    def normalize_stored_dispositions(value, entries)
      known = entries.to_h { |entry| [entry["id"].to_s, entry] }
      return {} unless value.is_a?(Hash)

      value.each_with_object({}) do |(entry_id, disposition), result|
        next unless known.key?(entry_id.to_s)

        normalized, error = normalize_disposition(disposition, known.fetch(entry_id.to_s), entry_id: entry_id.to_s)
        result[entry_id.to_s] = normalized unless error
      end
    end
    private_class_method :normalize_stored_dispositions

    def normalize_disposition(value, entry, entry_id: nil)
      return [nil, disposition_error("invalid_outcome", entry_id, "Disposition must be an object")] unless value.is_a?(Hash)

      id = entry_id || value["entry_id"].to_s
      outcome = value["outcome"].to_s
      reason = value["reason"].to_s.strip
      allowed = entry_kind(entry) == "delegated_report" ? REPORT_OUTCOMES : USER_OUTCOMES
      unless allowed.include?(outcome)
        return [nil, disposition_error("invalid_outcome", id, "Allowed outcomes: #{allowed.join(', ')}")]
      end
      if REASON_OUTCOMES.include?(outcome) && reason.empty?
        return [nil, disposition_error("reason_required", id, "This outcome requires a non-empty reason")]
      end

      normalized = { "entry_id" => id, "outcome" => outcome }
      normalized["reason"] = reason unless reason.empty?
      [normalized, nil]
    end
    private_class_method :normalize_disposition

    def resolved_state(dispositions)
      outcomes = dispositions.values.map { |value| value["outcome"] }
      outcomes.include?("needs_input") ? "blocked" : "resolved"
    end
    private_class_method :resolved_state

    def projected_entry(entry, kind)
      {
        "id" => entry["id"].to_s,
        "kind" => kind,
        "prompt" => entry["prompt"].to_s,
        "attachments" => deep_copy(Array(entry["attachments"])),
        "accepted_at" => entry["accepted_at"],
        "authority" => deep_copy(entry["authority"])
      }.compact
    end
    private_class_method :projected_entry

    def normalize_ownership_stamp(value)
      return nil unless value.is_a?(Hash)

      value.slice("relationship_id", "owner", "generation").compact
    end
    private_class_method :normalize_ownership_stamp

    def append_attachment_lines(lines, entry)
      Array(entry["attachments"]).each do |attachment|
        target = attachment["type"] == "link" ? attachment["url"] : attachment["path"]
        lines << "  attachment: #{JSON.generate(attachment.merge('target' => target).compact)}"
      end
    end
    private_class_method :append_attachment_lines

    def disposition_error(code, entry_id, message)
      { "code" => code, "entry_id" => entry_id.to_s, "message" => message }
    end
    private_class_method :disposition_error

    def timestamp(value)
      value.respond_to?(:utc) ? value.utc.iso8601(6) : value.to_s
    end
    private_class_method :timestamp

    def deep_copy(value)
      return nil if value.nil?

      JSON.parse(JSON.generate(value))
    end
    private_class_method :deep_copy
  end
end
