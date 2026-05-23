# frozen_string_literal: true

require "json"

require "dry/cli"
require "lipgloss"

require_relative "domain/app_project"
require_relative "domain/kamal_action"
require_relative "domain/scheduler"

module HQ
  module CLICommand
    COLORS = {
      accent: "#FF79C6",
      accent_alt: "#BD93F9",
      text: "#F8F8F2",
      text_muted: "#6272A4",
      notice: "#8BE9FD"
    }.freeze

    module Commands
      extend Dry::CLI::Registry

      module CommandMetadata
        def usage_template(value = nil)
          @usage_template = value if value
          @usage_template
        end
      end

      class App < Dry::CLI::Command
        desc "Manage projects with Kamal deployment"

        def call(**)
          exit CLICommand.usage("Missing app command", err: err)
        end
      end

      class ListApps < Dry::CLI::Command
        extend CommandMetadata

        desc "List projects with Kamal deployment"
        usage_template "app list"

        def call(**)
          exit CLICommand.list_kamal_actions(out: out)
        end
      end

      class AppStatus < Dry::CLI::Command
        extend CommandMetadata

        desc "Check this project's app status"
        argument :project_key, required: true, desc: "Project key"
        usage_template "app status %{project_key}"

        def call(project_key:, **)
          exit CLICommand.check_app_status(project_key, out: out, err: err)
        end
      end

      class AppAction < Dry::CLI::Command
        extend CommandMetadata

        argument :project_key, required: true, desc: "Project key"

        def self.action_name(value = nil, usage: nil)
          @action_name = value if value
          usage_template(usage) if usage
          @action_name
        end

        def call(project_key:, **)
          exit CLICommand.start_kamal_action(self.class.action_name, project_key, out: out, err: err)
        end
      end

      class DeployApp < AppAction
        desc "Deploy this project"
        action_name "deploy", usage: "app deploy %{project_key}"
      end

      class MaintenanceApp < AppAction
        desc "Put this project into maintenance mode"
        action_name "maintenance", usage: "app maintenance %{project_key}"
      end

      class LiveApp < AppAction
        desc "Resume live traffic for this project"
        action_name "live", usage: "app live %{project_key}"
      end

      register "app", App do |prefix|
        prefix.register "list", ListApps
        prefix.register "status", AppStatus
        prefix.register "deploy", DeployApp
        prefix.register "maintenance", MaintenanceApp
        prefix.register "live", LiveApp
      end

      class Project < Dry::CLI::Command
        desc "Manage project metadata"

        def call(**)
          exit CLICommand.usage("Missing project command", err: err)
        end
      end

      class ProjectUpdate < Dry::CLI::Command
        extend CommandMetadata

        desc "Update project metadata fields"
        argument :project_key, required: true, desc: "Project key"
        option :pr_url, desc: "Open pull request URL (pass empty string to clear)"
        usage_template "project update %{project_key} --pr-url <url>"

        def call(project_key:, **opts)
          exit CLICommand.update_project(project_key, opts, out: out, err: err)
        end
      end

      register "project", Project do |prefix|
        prefix.register "update", ProjectUpdate
      end

      class Schedule < Dry::CLI::Command
        desc "Manage scheduled agent runs"

        def call(**)
          exit CLICommand.usage("Missing schedule command", err: err)
        end
      end

      class ScheduleValidate < Dry::CLI::Command
        extend CommandMetadata

        desc "Validate schedule configuration"
        usage_template "schedule validate"

        def call(**)
          exit CLICommand.validate_schedules(out: out, err: err)
        end
      end

      class ScheduleList < Dry::CLI::Command
        extend CommandMetadata

        desc "List schedules"
        usage_template "schedule list"

        def call(**)
          exit CLICommand.list_schedules(out: out, err: err)
        end
      end

      class ScheduleRun < Dry::CLI::Command
        extend CommandMetadata

        desc "Run a schedule now"
        argument :schedule_key, required: true, desc: "Schedule key"
        usage_template "schedule run %{schedule_key}"

        def call(schedule_key:, **)
          exit CLICommand.run_schedule(schedule_key, out: out, err: err)
        end
      end

      class SchedulePause < Dry::CLI::Command
        extend CommandMetadata

        desc "Pause a schedule"
        argument :schedule_key, required: true, desc: "Schedule key"
        usage_template "schedule pause %{schedule_key}"

        def call(schedule_key:, **)
          exit CLICommand.pause_schedule(schedule_key, out: out, err: err)
        end
      end

      class ScheduleResume < Dry::CLI::Command
        extend CommandMetadata

        desc "Resume a schedule"
        argument :schedule_key, required: true, desc: "Schedule key"
        usage_template "schedule resume %{schedule_key}"

        def call(schedule_key:, **)
          exit CLICommand.resume_schedule(schedule_key, out: out, err: err)
        end
      end

      class ScheduleReload < Dry::CLI::Command
        extend CommandMetadata

        desc "Validate schedules for the next daemon tick"
        usage_template "schedule reload"

        def call(**)
          exit CLICommand.reload_schedules(out: out, err: err)
        end
      end

      register "schedule", Schedule do |prefix|
        prefix.register "validate", ScheduleValidate
        prefix.register "list", ScheduleList
        prefix.register "run", ScheduleRun
        prefix.register "pause", SchedulePause
        prefix.register "resume", ScheduleResume
        prefix.register "reload", ScheduleReload
      end

    end

    APP_COMMANDS = [
      Commands::ListApps,
      Commands::AppStatus,
      Commands::DeployApp,
      Commands::MaintenanceApp,
      Commands::LiveApp
    ].freeze
    PROJECT_COMMANDS = [
      Commands::ProjectUpdate
    ].freeze
    SCHEDULE_COMMANDS = [
      Commands::ScheduleValidate,
      Commands::ScheduleList,
      Commands::ScheduleRun,
      Commands::SchedulePause,
      Commands::ScheduleResume,
      Commands::ScheduleReload
    ].freeze
    RUNTIME_COMMANDS = [
      "  bin/tycho serve [--host 127.0.0.1] [--port 7373]",
      "  bin/tycho schedule daemon [--once] [--dry-run] [--interval SECONDS]"
    ].freeze
    ACTIONS = APP_COMMANDS.filter_map { |command| command.action_name if command.respond_to?(:action_name) }.freeze
    USAGE = [
      "Usage:",
      "  bin/tycho --help",
      *RUNTIME_COMMANDS,
      *APP_COMMANDS.map { |command| "  bin/tycho #{format(command.usage_template, project_key: "<project-key>")}" },
      *PROJECT_COMMANDS.map { |command| "  bin/tycho #{format(command.usage_template, project_key: "<project-key>")}" },
      *SCHEDULE_COMMANDS.map { |command| "  bin/tycho #{format(command.usage_template, schedule_key: "<schedule-key>")}" },
      "",
      "Run without a command to open the interactive Tycho TUI."
    ].join("\n").freeze

    module_function

    def run(argv, executable: nil)
      argv = Array(argv)
      return usage if argv.empty? || %w[--help -h].include?(argv.first)
      return serve(argv.drop(1), executable:) if argv.first == "serve"
      return schedule_daemon(argv.drop(2)) if argv[0] == "schedule" && argv[1] == "daemon"

      Dry::CLI.new(Commands).call(arguments: argv)
    rescue SystemExit => e
      e.status
    end

    def serve(argv, executable: nil)
      require_relative "serve_command"

      ServeCommand.run(argv, executable: executable || File.expand_path("../../bin/tycho", __dir__), command_prefix: ["serve"])
    end

    def schedule_daemon(argv)
      require_relative "schedule_daemon_command"

      ScheduleDaemonCommand.run(argv)
    end

    def list_kamal_actions(out: $stdout)
      projects = registry_projects.select(&:apps_enabled?)
      if projects.empty?
        out.puts "No projects with Kamal deployment configured."
        return 0
      end

      out.puts app_list_table(projects)
      0
    end

    def check_app_status(project_key, out: $stdout, err: $stderr)
      project = find_app_project(project_key)
      return failure("Unknown project: #{project_key}", err: err) unless project
      return failure("Project does not have Kamal deployment: #{project.key}", err: err) unless project.apps_enabled?

      project.refresh_metadata!
      project.check_health!
      out.puts app_status_table(project, action_status: action_status_for(project))
      0
    end

    def app_list_table(projects)
      headers = %w[Key Name Actions]
      rows = projects.map { |project| [project.key, project.name, ACTIONS.join(", ")] }
      Lipgloss::Table.new
        .headers(headers)
        .rows(rows)
        .border_style(Lipgloss::Style.new.foreground(COLORS[:accent_alt]))
        .style_func(rows: rows.length, columns: headers.length) do |row, column|
        if row == Lipgloss::Table::HEADER_ROW
          Lipgloss::Style.new.bold(true).foreground(COLORS[:accent])
        elsif column.zero?
          Lipgloss::Style.new.bold(true).foreground(COLORS[:notice])
        else
          Lipgloss::Style.new.foreground(COLORS[:text])
        end
      end.render
    end

    def app_status_table(project, action_status: nil)
      rows = [
        ["Key", project.key],
        ["Name", project.name],
        ["Path", project.path],
        ["Service", project.service || "n/a"],
        ["Image", project.image || "n/a"],
        ["Hosts", Array(project.hosts).empty? ? "n/a" : Array(project.hosts).join(", ")],
        ["Proxy", project.proxy_host || "n/a"],
        ["Health Path", project.healthcheck_path || "n/a"],
        ["App", project.app_status],
        ["Health", project.health_status],
        ["Latency", project.response_time ? "#{project.response_time}ms" : "n/a"],
        ["Action Log", project.action_log_path]
      ]
      if action_status
        rows.insert(-2, ["Last Action", action_status.fetch(:label)])
        rows.insert(-2, ["Last Action At", action_status.fetch(:started_at)])
      end
      Lipgloss::Table.new
        .rows(rows)
        .border_style(Lipgloss::Style.new.foreground(COLORS[:accent_alt]))
        .style_func(rows: rows.length, columns: 2) do |_row, column|
        if column.zero?
          Lipgloss::Style.new.bold(true).foreground(COLORS[:notice])
        else
          Lipgloss::Style.new.foreground(COLORS[:text])
        end
      end.render
    end

    def action_status_for(project)
      active = load_actions[project.key]
      if active
        active.poll!
        return {
          label: active.done? ? action_result_label(active) : "#{active.label} - running",
          started_at: active.started_at.strftime("%Y-%m-%d %H:%M:%S")
        }
      end

      last_action_status_from_log(project)
    end

    def last_action_status_from_log(project)
      return nil unless File.exist?(project.action_log_path)

      content = File.read(project.action_log_path)
      matches = content.to_enum(:scan, /^=== \[(.+?)\] ([a-z_]+) ===$/).map { Regexp.last_match }
      last = matches.last
      return nil unless last

      action = last[2].to_sym
      section = content[last.begin(0)..]
      {
        label: "#{KamalAction.label_for(action)} - #{action_status_label(project, section)}",
        started_at: last[1]
      }
    rescue StandardError
      nil
    end

    def action_status_label(project, section)
      status_path = "#{project.action_log_path}.status"
      if File.exist?(status_path)
        return File.read(status_path).to_i.zero? ? "success" : "failed"
      end

      return "failed" if section.match?(/\bERROR\b|\bexit status:\s*[1-9]\d*\b|failed to/i)
      return "success" if section.match?(/\bexit status 0\b|successful/i)

      "unknown"
    rescue StandardError
      "unknown"
    end

    def action_result_label(action)
      "#{action.label} - #{action.success? ? "success" : "failed"}"
    end

    def start_kamal_action(action_name, project_key, out: $stdout, err: $stderr)
      return usage("Missing project key") if project_key.to_s.strip.empty?

      project = find_app_project(project_key)
      return failure("Unknown project: #{project_key}", err: err) unless project
      return failure("Project does not have Kamal deployment: #{project.key}", err: err) unless project.apps_enabled?

      actions = load_actions
      active = actions[project.key]
      if active
        active.poll!
        return failure("#{project.key} already has an active action: #{active.label}", err: err) unless active.done?

        actions.delete(project.key)
      end

      action = KamalAction.new(
        project_key: project.key,
        project_name: project.name,
        project_path: project.path,
        action: action_name.to_sym
      )
      action.start!
      actions[project.key] = action
      save_actions(actions)
      out.puts "Started #{action.label} for #{project.key}."
      out.puts "Log: #{action.log_path}"
      0
    end

    def registry_projects
      require_relative "registry"

      Registry.new.projects.map { |config| AppProject.new(config) }
    end

    def update_project(project_key, opts, out: $stdout, err: $stderr)
      require_relative "registry"

      attrs = {}
      attrs[:pr_url] = opts[:pr_url] if opts.key?(:pr_url)
      return failure("No fields to update (pass --pr-url)", err: err) if attrs.empty?

      registry = Registry.new
      updated = registry.update_project!(project_key, attrs)
      return failure("Unknown project: #{project_key}", err: err) unless updated

      out.puts "Updated #{project_key}: #{attrs.map { |k, v| "#{k}=#{v.to_s.empty? ? "(cleared)" : v}" }.join(", ")}"
      0
    rescue StandardError => e
      failure("Failed to update #{project_key}: #{e.message}", err: err)
    end

    def validate_schedules(out: $stdout, err: $stderr)
      scheduler.validate!
      out.puts "Schedules valid."
      0
    rescue ScheduleRegistry::Error => e
      failure(e.message, err:)
    end

    def list_schedules(out: $stdout, err: $stderr)
      current_scheduler = scheduler
      rows = current_scheduler.list
      daemon = current_scheduler.daemon_state.to_hash
      out.puts schedule_daemon_line(daemon)
      if rows.empty?
        out.puts "No schedules configured."
      else
        out.puts schedule_list_table(rows)
      end
      0
    rescue ScheduleRegistry::Error => e
      failure(e.message, err:)
    end

    def schedule_daemon_line(daemon)
      status = daemon[:status].to_s.empty? ? "unknown" : daemon[:status]
      parts = ["Daemon: #{status}"]
      parts << "pid=#{daemon[:pid]}" if daemon[:pid]
      parts << "last_tick=#{daemon[:last_tick_finished_at]}" if daemon[:last_tick_finished_at]
      parts << "mode=#{daemon[:mode]}" if daemon[:mode]
      parts.join("  ")
    end

    def run_schedule(schedule_key, out: $stdout, err: $stderr)
      result = scheduler.run_now(schedule_key)
      schedule = result.fetch(:schedule)
      if result.fetch(:status) == :failed
        return failure("Schedule #{schedule.fetch(:key)} failed: #{result.fetch(:error)}", err:)
      end
      unless result.fetch(:status) == :started
        return failure("Schedule #{schedule.fetch(:key)} did not start: #{result.fetch(:status)}", err:)
      end

      agent = result[:agent]
      out.puts "Started schedule #{schedule.fetch(:key)}."
      out.puts "Agent: #{agent.key}" if agent
      out.puts "Next: #{schedule[:next_due_at] || "n/a"}"
      0
    rescue ScheduleRegistry::Error => e
      failure(e.message, err:)
    end

    def pause_schedule(schedule_key, out: $stdout, err: $stderr)
      schedule = scheduler.pause(schedule_key)
      out.puts "Paused #{schedule.fetch(:key)}."
      0
    rescue ScheduleRegistry::Error => e
      failure(e.message, err:)
    end

    def resume_schedule(schedule_key, out: $stdout, err: $stderr)
      schedule = scheduler.resume(schedule_key)
      out.puts "Resumed #{schedule.fetch(:key)}."
      out.puts "Next: #{schedule[:next_due_at] || "n/a"}"
      0
    rescue ScheduleRegistry::Error => e
      failure(e.message, err:)
    end

    def reload_schedules(out: $stdout, err: $stderr)
      scheduler.validate!
      out.puts "Schedules valid. The scheduler daemon reloads config on its next process start or tick."
      0
    rescue ScheduleRegistry::Error => e
      failure(e.message, err:)
    end

    def schedule_list_table(rows)
      headers = %w[Key Project Paused Next Last Agent Runs Skips]
      table_rows = rows.map do |row|
        [
          row[:key],
          row[:project_key],
          row[:paused] ? "yes" : "no",
          row[:next_due_at] || "n/a",
          row[:last_status] || "n/a",
          row[:last_target_key] || "n/a",
          row[:run_count].to_s,
          row[:skip_count].to_s
        ]
      end
      Lipgloss::Table.new
        .headers(headers)
        .rows(table_rows)
        .border_style(Lipgloss::Style.new.foreground(COLORS[:accent_alt]))
        .style_func(rows: table_rows.length, columns: headers.length) do |row, column|
        if row == Lipgloss::Table::HEADER_ROW
          Lipgloss::Style.new.bold(true).foreground(COLORS[:accent])
        elsif column.zero?
          Lipgloss::Style.new.bold(true).foreground(COLORS[:notice])
        else
          Lipgloss::Style.new.foreground(COLORS[:text])
        end
      end.render
    end

    def scheduler
      Scheduler.new
    end

    def find_app_project(project_key)
      registry_projects.find { |candidate| candidate.key == project_key.to_s }
    end

    def load_actions
      return {} unless File.exist?(ACTIONS_FILE)

      JSON.parse(File.read(ACTIONS_FILE)).each_with_object({}) do |hash, actions|
        action = KamalAction.from_hash(hash)
        actions[action.project_key] = action
      end
    rescue StandardError => e
      warn "Failed to load actions: #{e.message}"
      {}
    end

    def save_actions(actions)
      File.write(ACTIONS_FILE, JSON.pretty_generate(actions.values.map(&:to_hash)))
    end

    def usage(error = nil, err: $stderr)
      err.puts error if error
      err.puts USAGE
      error ? 64 : 0
    end

    def prompt_reference(project_key:)
      command_lines = APP_COMMANDS.map do |command|
        "- #{command.description}: `#{File.join(ROOT_DIR, "bin", "tycho")} #{format(command.usage_template, project_key:)}`"
      end

      [
        "Available Tycho commands for projects with Kamal deployment:",
        *command_lines,
        "Use these commands only when the user explicitly asks you to operate deployment or maintenance."
      ].join("\n")
    end

    def failure(message, err: $stderr)
      err.puts message
      1
    end
  end
end
