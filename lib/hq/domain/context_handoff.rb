# frozen_string_literal: true

require "fileutils"
require "json"

module HQ
  module ContextHandoff
    module_function

    def prepare!(source, target)
      target.add_user_message!(prompt(source), metadata: {
        "context_handoff" => true,
        "source_agent_key" => source.key
      })
      copy_pull_request_catalog(source, target)
      target
    end

    def prompt(source)
      handoff = source.structured_result&.dig("memory_handoff")
      semantic = handoff.is_a?(Hash) ? JSON.pretty_generate(handoff) : source.last_summary.to_s.strip
      semantic = "No completed-run summary is available." if semantic.empty?
      <<~PROMPT.strip
        Continue from a fresh context. This handoff was copied from managed agent #{source.key}.

        #{semantic}

        Operational state remains on the source agent and was not discarded:
        - queued work: #{source.queued_prompts.length}
        - unresolved inquiry: #{source.inquiry_blocking_prompt_queue? ? "yes" : "no"}
        - schedule: #{source.schedule_key || "none"}

        Review the source agent before you resolve or archive any remaining work.
      PROMPT
    end

    def copy_pull_request_catalog(source, target)
      return unless File.file?(source.pull_request_catalog_path)

      FileUtils.mkdir_p(File.dirname(target.pull_request_catalog_path))
      FileUtils.cp(source.pull_request_catalog_path, target.pull_request_catalog_path)
    end
  end
end
