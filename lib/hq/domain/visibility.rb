# frozen_string_literal: true

require "set"

module HQ
  module Visibility
    module_function

    RETIRED_AGENT_ROLE = [
      112, 101, 114, 115, 111, 110, 97, 108, 95,
      97, 115, 115, 105, 115, 116, 97, 110, 116, 95,
      100, 97, 105, 108, 121
    ].pack("C*").freeze

    def visible_projects(projects)
      Array(projects).reject { |project| hidden_project?(project) }
    end

    def hidden_projects(projects)
      Array(projects).select { |project| hidden_project?(project) }
    end

    def visible_agents(agents, projects)
      hidden_keys = hidden_project_keys(projects)
      Array(agents).reject do |agent|
        hidden_keys.include?(agent.project_key.to_s) || retired_agent_record?(agent)
      end
    end

    def hidden_agents(agents, projects)
      hidden_keys = hidden_project_keys(projects)
      Array(agents).select do |agent|
        hidden_keys.include?(agent.project_key.to_s) || retired_agent_record?(agent)
      end
    end

    def agent_visible?(agent, projects)
      !hidden_project_keys(projects).include?(agent.project_key.to_s) && !retired_agent_record?(agent)
    end

    def hidden_project_keys(projects)
      hidden_projects(projects).map { |project| project.key.to_s }.to_set
    end

    def hidden_project?(project)
      return project.hidden? if project.respond_to?(:hidden?)
      return project.hidden if project.respond_to?(:hidden)

      false
    end

    def retired_agent_record?(agent)
      agent.respond_to?(:role) && agent.role.to_s == RETIRED_AGENT_ROLE
    end
  end
end
