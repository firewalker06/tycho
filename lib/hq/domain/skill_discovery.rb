# frozen_string_literal: true

require_relative "../harness_registry"

module HQ
  module SkillDiscovery
    module_function

    def discover(workspace:, agent_kind:)
      kind = agent_kind.to_s.downcase
      roots = roots_for(kind, workspace)
      seen = {}
      roots.each do |root|
        next unless root && Dir.exist?(root)

        Dir.children(root).sort.each do |entry|
          dir = File.join(root, entry)
          skill_file = File.join(dir, "SKILL.md")
          next unless File.directory?(dir) && File.file?(skill_file)

          seen[entry] = { "name" => entry, "path" => skill_file }
        end
      end
      seen.values
    rescue StandardError
      []
    end

    def trigger_for(agent_kind)
      HQ.harness_adapter(agent_kind) == "claude" ? "/" : "$"
    end

    def roots_for(kind, workspace)
      workspace = workspace.to_s
      if HQ.harness_adapter(kind) == "claude"
        [
          File.expand_path("~/.claude/skills"),
          workspace.empty? ? nil : File.join(workspace, ".claude", "skills")
        ]
      else
        [
          File.expand_path("~/.codex/skills"),
          workspace.empty? ? nil : File.join(workspace, ".agents", "skills")
        ]
      end
    end
  end
end
