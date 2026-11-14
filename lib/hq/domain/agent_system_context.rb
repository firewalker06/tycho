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
      lines << "- Focus is your durable current-state artifact. Read with `tycho agent focus #{agent_key} --json`; replace sections with `tycho agent focus #{agent_key} --file PATH --revision N`. Read first, preserve unrelated items, and use the returned revision. Focus persists across runs; update it when actionable state changes."
      if tycho_skill_installed
        lines << "- The Tycho skill is installed and usable; use it for Tycho-specific managed-agent operations."
      end
      lines.join("\n")
    end
  end
end
