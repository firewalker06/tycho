# frozen_string_literal: true

module HQ
  class AgentSystemContext
    def self.render(agent_key:, parent:, tycho_skill_installed:)
      parent_key = parent.is_a?(Hash) ? parent["agent_key"].to_s.strip : ""
      lines = [
        "Tycho managed-agent context (trusted):",
        "- You are running under Tycho, which launches and coordinates managed agents and records their work.",
        "- Your agent key: #{agent_key}"
      ]
      lines << if parent_key.empty?
                 "- No parent agent is recorded for this root agent."
               else
                 "- Your delegating parent agent key: #{parent_key}"
               end
      lines << <<~FOCUS.strip
        Focus is durable, current actionable state for this agent. It persists across runs and is separate from the conversation and run Summary.
        Read Focus at the start of each run with `tycho agent focus #{agent_key} --json`. Use it to understand the current task, decisions, blockers, and next actions before you begin.
        Update Focus when the actionable state changes: remove completed or outdated work, record new decisions and blockers, and state clear next actions. Keep only information that will help a later run continue.
        Before editing, read the latest Focus document. Preserve unrelated sections and items. Write the complete `sections` array with `tycho agent focus #{agent_key} --file PATH --revision N`, using the revision returned by the read. If the write reports a conflict, read again and apply your changes to the latest document.
        Do not clear Focus at the end of a run. Do not copy the run Summary into Focus. A Summary reports this run's outcome; Focus records the work that remains actionable.
      FOCUS
      if tycho_skill_installed
        lines << "- The Tycho skill is installed and usable; use it for Tycho-specific managed-agent operations."
      end
      lines.join("\n")
    end
  end
end
