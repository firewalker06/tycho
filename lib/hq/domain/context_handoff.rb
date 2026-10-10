# frozen_string_literal: true

require "fileutils"

module HQ
  module ContextHandoff
    module_function

    def prepare!(source, target, schedule_replacement: false)
      target.add_user_message!(prompt(source, schedule_replacement:), metadata: {
        "context_handoff" => true,
        "source_agent_key" => source.key,
        "schedule_replacement" => schedule_replacement ? true : nil
      })
      copy_pull_request_catalog(source, target)
      target
    end

    def prompt(source, schedule_replacement: false)
      handoff = source.structured_result&.dig("memory_handoff")
      semantic = handoff.is_a?(Hash) ? formatted_handoff(handoff) : formatted_summary(source.last_summary)
      operational_state = if schedule_replacement
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

        Review the source agent before you resolve or archive any remaining work.
      PROMPT
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
      value = "No completed-run summary is available." if value.empty?
      "Previous summary:\n#{value}"
    end

    def append_text_section(sections, title, value)
      text = value.to_s.strip
      sections << "#{title}:\n#{text.empty? ? "None provided." : text}"
    end

    def append_list_section(sections, title, values)
      items = Array(values).map(&:to_s).map(&:strip).reject(&:empty?)
      return if items.empty?

      sections << "#{title}:\n#{items.map { |item| "- #{item}" }.join("\n")}"
    end

    def copy_pull_request_catalog(source, target)
      return unless File.file?(source.pull_request_catalog_path)

      FileUtils.mkdir_p(File.dirname(target.pull_request_catalog_path))
      FileUtils.cp(source.pull_request_catalog_path, target.pull_request_catalog_path)
    end
  end
end
