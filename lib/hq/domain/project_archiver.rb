# frozen_string_literal: true

require_relative "../registry"
require_relative "agent_store"
require_relative "file_transaction"
require_relative "project"
require_relative "scheduler"

module HQ
  class ProjectArchiver
    Result = Struct.new(
      :project, :archived_agent_keys, :project_log_archive, :agent_log_archives,
      keyword_init: true
    )

    def initialize(registry:, agent_store: nil, scheduler: nil)
      @registry = registry
      @agent_store = agent_store || AgentStore.new(registry.projects)
      @scheduler = scheduler || Scheduler.new(registry:)
    end

    def archive(project_key, now: Time.now)
      config = @registry.projects.find { |candidate| candidate.key == project_key.to_s }
      raise ArgumentError, "Unknown project: #{project_key}" unless config

      project = Project.new(config)
      agents = @agent_store.load
      project_agents = agents.select { |agent| agent.project_key == project.key }
      running = project_agents.select(&:running?)
      unless running.empty?
        raise ArgumentError, "Project #{project.key} has running agents: #{running.map(&:key).join(", ")}"
      end

      FileTransaction.run(transaction_paths) do |transaction|
        project_archive = project.archive_logs!(now:)
        restore_project_logs(transaction, project, project_archive)
        agent_archives = project_agents.filter_map do |agent|
          original_paths = agent.log_files.select { |path| File.exist?(path) }
          destination = agent.archive_logs!
          restore_agent_logs(transaction, original_paths, destination)
          @scheduler.reconcile_archived_agent!(agent.key, archived_agent: agent, now:)
          destination
        end
        @registry.archive_project!(project.key)
        @agent_store.save(agents.reject { |agent| agent.project_key == project.key })
        Result.new(
          project: config,
          archived_agent_keys: project_agents.map(&:key),
          project_log_archive: project_archive,
          agent_log_archives: agent_archives
        )
      end
    end

    private

    def transaction_paths
      [
        @registry.path,
        @registry.archived_projects_path,
        AGENTS_FILE,
        SCHEDULES_FILE,
        SCHEDULES_STATE_FILE
      ]
    end

    def restore_project_logs(transaction, project, destination)
      return unless destination

      transaction.on_rollback do
        FileUtils.mkdir_p(File.dirname(project.log_dir))
        FileUtils.mv(destination, project.log_dir) if File.exist?(destination)
      end
    end

    def restore_agent_logs(transaction, original_paths, destination)
      return unless destination

      transaction.on_rollback do
        original_paths.each do |path|
          archived = File.join(destination, File.basename(path))
          next unless File.exist?(archived)

          FileUtils.mkdir_p(File.dirname(path))
          FileUtils.mv(archived, path)
        end
        Dir.rmdir(destination) if Dir.exist?(destination) && Dir.empty?(destination)
      end
    end
  end
end
