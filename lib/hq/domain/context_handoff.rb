# frozen_string_literal: true

require "fileutils"
require "json"

module HQ
  module ContextHandoff
    module_function

    def prepare!(source, target, schedule_replacement: false, archive_source: false)
      target.add_user_message!(prompt(source, schedule_replacement:, archive_source:), metadata: {
        "context_handoff" => true,
        "source_agent_key" => source.key,
        "schedule_replacement" => schedule_replacement ? true : nil,
        "source_archived_after_start" => archive_source ? true : nil
      })
      copy_pull_request_catalog(source, target)
      target
    end

    def prompt(source, schedule_replacement: false, archive_source: false)
      handoff = source.structured_result&.dig("memory_handoff")
      semantic = handoff.is_a?(Hash) ? JSON.pretty_generate(handoff) : source.last_summary.to_s.strip
      semantic = "No completed-run summary is available." if semantic.empty?
      operational_state = if archive_source
                            archived_handoff_state(source, schedule_replacement:)
                          elsif schedule_replacement
                            <<~STATE.strip
                              The schedule connection moves to this replacement agent. Other operational state remains on the source agent and was not discarded:
                              - queued work: #{source.queued_prompts.length}
                              - unresolved inquiry: #{source.inquiry_blocking_prompt_queue? ? "yes" : "no"}
                              - replaced schedule: #{source.schedule_key || "none"}
                            STATE
                          else
                            <<~STATE.strip
                              Operational state remains on the source agent and was not discarded:
                              - queued work: #{source.queued_prompts.length}
                              - unresolved inquiry: #{source.inquiry_blocking_prompt_queue? ? "yes" : "no"}
                              - schedule: #{source.schedule_key || "none"}
                            STATE
                          end
      <<~PROMPT.strip
        Continue from a fresh context. This handoff was copied from managed agent #{source.key}.

        #{semantic}

        #{operational_state}

        #{archive_source ? "Inspect the archived source history when you need prior context. Do not try to resolve or archive the source again." : "Review the source agent before you resolve or archive any remaining work."}
      PROMPT
    end

    def archived_handoff_state(source, schedule_replacement:)
      callbacks = source.queued_prompts.count { |entry| entry["source"] == "delegation_callback" }
      schedule = schedule_replacement ? "replaced schedule: #{source.schedule_key || "none"}" : "schedule: #{source.schedule_key || "none"}"
      <<~STATE.strip
        The source agent will be archived after this replacement starts. Its history remains available as read-only archived history:
        - queued work: #{callbacks.zero? ? "none" : "#{callbacks} callback-only report#{callbacks == 1 ? "" : "s"} preserved in archived history"}
        - unresolved inquiry: none
        - #{schedule}

        If this replacement does not start, the source stays active with its current state.
      STATE
    end

    def copy_pull_request_catalog(source, target)
      return unless File.file?(source.pull_request_catalog_path)

      FileUtils.mkdir_p(File.dirname(target.pull_request_catalog_path))
      FileUtils.cp(source.pull_request_catalog_path, target.pull_request_catalog_path)
    end
  end
end
