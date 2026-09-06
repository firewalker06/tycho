# frozen_string_literal: true

module HQ
  # Pure action contract shared by FRED's structured-output validator and its
  # server executor. Keep values simple: every argument key is present, while
  # nullable values have the action-specific meaning documented by the service.
  module PersonalAssistantActionCatalog
    READ_ONLY = %w[
      read_docs search_docs inspect_agents inspect_projects inspect_schedules
      inspect_agent_run inspect_agent_log
    ].freeze

    MUTATIONS = %w[
      install_or_update_tycho_skill create_agent message_agent start_agent stop_agent
      create_project update_project create_schedule pause_schedule resume_schedule
    ].freeze

    TYPES = (READ_ONLY + MUTATIONS).freeze

    ARGUMENTS = {
      "read_docs" => %w[path],
      "search_docs" => %w[query],
      "inspect_agents" => [],
      "inspect_projects" => [],
      "inspect_schedules" => [],
      "inspect_agent_run" => %w[agent_key],
      "inspect_agent_log" => %w[agent_key],
      "install_or_update_tycho_skill" => %w[harness action],
      "create_agent" => %w[project_key name prompt agent model reasoning_effort],
      "message_agent" => %w[agent_key prompt],
      "start_agent" => %w[agent_key],
      "stop_agent" => %w[agent_key],
      "create_project" => %w[key name path group agent model reasoning_effort],
      "update_project" => %w[project_key name group agent model reasoning_effort],
      "create_schedule" => %w[key name cron timezone project_key agent_name message system_message],
      "pause_schedule" => %w[schedule_key],
      "resume_schedule" => %w[schedule_key]
    }.freeze

    NULLABLE_ARGUMENTS = {
      "create_agent" => %w[agent model reasoning_effort],
      "create_project" => %w[group agent model reasoning_effort],
      # Null update values leave the existing project configuration unchanged.
      "update_project" => %w[name group agent model reasoning_effort],
      "create_schedule" => %w[system_message]
    }.freeze
  end
end
