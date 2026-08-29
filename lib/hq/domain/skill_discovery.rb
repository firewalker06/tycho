# frozen_string_literal: true

require "find"

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

        skill_files(root).each do |skill_file|
          name = File.basename(File.dirname(skill_file))
          seen[name] = { "name" => name, "path" => skill_file }
        end
      end
      seen.values
    rescue StandardError
      []
    end

    def trigger_for(agent_kind)
      case HQ.harness_adapter(agent_kind)
      when "claude" then "/"
      when "pi" then "/skill:"
      else "$"
      end
    end

    def skill_files(root)
      files = []
      Find.find(root) do |path|
        next if path == root
        next unless File.directory?(path)

        skill_file = File.join(path, "SKILL.md")
        next unless File.file?(skill_file)

        files << skill_file
        Find.prune
      end
      files.sort
    end

    def roots_for(kind, workspace)
      workspace = workspace.to_s
      case HQ.harness_adapter(kind)
      when "claude"
        [
          File.expand_path("~/.claude/skills"),
          workspace.empty? ? nil : File.join(workspace, ".claude", "skills")
        ]
      when "opencode"
        [
          File.expand_path("~/.config/opencode/skills"),
          File.expand_path("~/.claude/skills"),
          File.expand_path("~/.agents/skills"),
          workspace.empty? ? nil : File.join(workspace, ".opencode", "skills"),
          workspace.empty? ? nil : File.join(workspace, ".claude", "skills"),
          workspace.empty? ? nil : File.join(workspace, ".agents", "skills")
        ]
      when "pi"
        [
          File.expand_path("~/.pi/agent/skills"),
          File.expand_path("~/.agents/skills"),
          workspace.empty? ? nil : File.join(workspace, ".pi", "skills"),
          workspace.empty? ? nil : File.join(workspace, ".agents", "skills")
        ]
      else
        [
          File.expand_path("~/.codex/skills"),
          File.expand_path("~/.agents/skills"),
          workspace.empty? ? nil : File.join(workspace, ".agents", "skills")
        ]
      end
    end
  end
end
