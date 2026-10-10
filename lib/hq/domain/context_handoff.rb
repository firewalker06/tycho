# frozen_string_literal: true

require "fileutils"
require_relative "memory_handoff"

module HQ
  module ContextHandoff
    module_function

    def prepare!(source, target, schedule_replacement: false, archive_source: false)
      target.add_user_message!(
        prompt(source, schedule_replacement:, archive_source:),
        metadata: {
          "context_handoff" => true,
          "source_agent_key" => source.key,
          "schedule_replacement" => schedule_replacement ? true : nil,
          "source_archived_after_start" => archive_source ? true : nil
        }
      )
      copy_pull_request_catalog(source, target)
      target
    end

    def prompt(source, schedule_replacement: false, archive_source: false)
      handoff = MemoryHandoff.normalize(source.structured_result&.dig("memory_handoff"))
      semantic = handoff ? formatted_handoff(handoff) : formatted_summary(source.last_summary)
      state = archive_source ? archived_handoff_state(source, schedule_replacement:) :
        active_handoff_state(source, schedule_replacement:)
      instruction = if archive_source
                      "Inspect the archived source record when you need prior context. " \
                        "Do not try to resolve or archive the source again."
                    else
                      "Review the source agent record, whether active or archived, before you resolve any remaining work."
                    end
      <<~PROMPT.strip
        Continue from a fresh context. This handoff was copied from managed agent #{source.key}.

        #{semantic}

        #{state}

        #{instruction}
      PROMPT
    end

    def record_archive_rejection!(source, target)
      target.add_user_message!(
        "The source agent remains active because new work arrived before its archive completed. " \
          "Do not continue this replacement. Review the active source record before any recovery action.",
        metadata: {
          "context_handoff_archive_rejected" => true,
          "source_agent_key" => source.key
        }
      )
      target
    end

    def active_handoff_state(source, schedule_replacement:)
      label = schedule_replacement ? "replaced schedule" : "schedule"
      transfer = "The schedule connection moves to this replacement agent. " if schedule_replacement
      <<~STATE.strip
        #{transfer}Operational state remains on the source agent and was not discarded:
        - queued work: #{source.queued_prompts.length}
        - unresolved inquiry: #{source.inquiry_blocking_prompt_queue? ? "yes" : "no"}
        - #{label}: #{source.schedule_key || "none"}
      STATE
    end

    def archived_handoff_state(source, schedule_replacement:)
      callbacks = source.queued_prompts.count { |entry| entry["source"] == "delegation_callback" }
      label = schedule_replacement ? "replaced schedule" : "schedule"
      queued_work = if callbacks.zero?
                      "none"
                    else
                      "#{callbacks} callback-only report#{callbacks == 1 ? "" : "s"} " \
                        "preserved in archived history"
                    end
      <<~STATE.strip
        The source agent will be archived after this replacement starts. Its history remains available as read-only archived source history:
        - queued work: #{queued_work}
        - unresolved inquiry: none
        - #{label}: #{source.schedule_key || "none"}

        If this replacement does not start, the source stays active with its current state.
      STATE
    end

    def formatted_handoff(handoff)
      sections = ["Handoff summary:\n#{handoff.fetch("outcome")}"]
      append_list_section(sections, "Decisions", handoff["decisions"])
      append_text_section(sections, "Continuing context", handoff["continuing_context"])
      append_list_section(sections, "References", handoff["references"])
      append_list_section(sections, "Lessons", handoff["lessons"])
      append_list_section(sections, "Promotion candidates", handoff["promotion_candidates"])
      sections.join("\n\n")
    end

    def formatted_summary(summary)
      value = summary.to_s.strip
      "Previous summary:\n#{value.empty? ? "No completed-run summary is available." : value}"
    end

    def append_text_section(sections, title, value)
      text = value.to_s.strip
      sections << "#{title}:\n#{text.empty? ? "None provided." : text}"
    end

    def append_list_section(sections, title, values)
      items = Array(values).map(&:to_s).map(&:strip).reject(&:empty?)
      sections << "#{title}:\n#{items.map { |item| "- #{item}" }.join("\n")}" unless items.empty?
    end

    def copy_pull_request_catalog(source, target)
      return unless File.file?(source.pull_request_catalog_path)
      FileUtils.mkdir_p(File.dirname(target.pull_request_catalog_path))
      FileUtils.cp(source.pull_request_catalog_path, target.pull_request_catalog_path)
    end
  end
end
