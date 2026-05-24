# frozen_string_literal: true

require "set"

module HQ
  module Visibility
    module_function

    def visible_projects(projects)
      Array(projects).reject { |project| hidden_project?(project) }
    end

    def hidden_projects(projects)
      Array(projects).select { |project| hidden_project?(project) }
    end

    def visible_agents(agents, projects)
      hidden_keys = hidden_project_keys(projects)
      Array(agents).reject { |agent| hidden_keys.include?(agent.project_key.to_s) }
    end

    def hidden_agents(agents, projects)
      hidden_keys = hidden_project_keys(projects)
      Array(agents).select { |agent| hidden_keys.include?(agent.project_key.to_s) }
    end

    def agent_visible?(agent, projects)
      !hidden_project_keys(projects).include?(agent.project_key.to_s)
    end

    def hidden_project_keys(projects)
      hidden_projects(projects).map { |project| project.key.to_s }.to_set
    end

    def hidden_project?(project)
      return project.hidden? if project.respond_to?(:hidden?)
      return project.hidden if project.respond_to?(:hidden)

      false
    end
  end
end
