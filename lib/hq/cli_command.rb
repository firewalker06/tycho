# frozen_string_literal: true

require "json"
require "rbconfig"

require "dry/cli"
require "lipgloss"

require_relative "domain/app_project"
require_relative "domain/file_store"
require_relative "domain/kamal_action"
require_relative "domain/scheduler"
require_relative "domain/agent_store"

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

      class Agent < Dry::CLI::Command
        desc "Manage agents"

        def call(**)
          exit CLICommand.usage("Missing agent command", err: err)
        end
      end

      class AgentCreate < Dry::CLI::Command
        extend CommandMetadata

        desc "Create a new agent for a project"
        argument :project_key, required: true, desc: "Project key"
        argument :prompt, required: true, desc: "Initial prompt for the agent"
        option :model, desc: "Model override (e.g. claude-opus-4-5)"
        option :harness, desc: "Agent harness override (e.g. claude, codex, opencode)"
        option :name, desc: "Agent name override"
        option :template, desc: "Template key to use (defaults to project's first template)"
        option :run, type: :boolean, default: false, desc: "Start the agent immediately after creating"
        usage_template "agent create %{project_key} %{prompt}"

        def call(project_key:, prompt:, **opts)
          exit CLICommand.create_agent(project_key, prompt, opts, out: out, err: err)
        end
      end

      class AgentList < Dry::CLI::Command
        extend CommandMetadata

        desc "List managed agents"
        argument :project_key, required: false, desc: "Filter by project key"
        usage_template "agent list [%{project_key}]"

        def call(**opts)
          exit CLICommand.list_agents(opts[:project_key], out: out, err: err)
        end
      end

      class AgentStatus < Dry::CLI::Command
        extend CommandMetadata

        desc "Show status and metadata for an agent"
        argument :agent_key, required: true, desc: "Agent key"
        usage_template "agent status %{agent_key}"

        def call(agent_key:, **)
          exit CLICommand.agent_status(agent_key, out: out, err: err)
        end
      end

      class AgentRun < Dry::CLI::Command
        extend CommandMetadata

        desc "Start (or re-run) an existing agent"
        argument :agent_key, required: true, desc: "Agent key"
        usage_template "agent run %{agent_key}"

        def call(agent_key:, **)
          exit CLICommand.run_agent(agent_key, out: out, err: err)
        end
      end

      class AgentStop < Dry::CLI::Command
        extend CommandMetadata

        desc "Stop a running agent"
        argument :agent_key, required: true, desc: "Agent key"
        usage_template "agent stop %{agent_key}"

        def call(agent_key:, **)
          exit CLICommand.stop_agent(agent_key, out: out, err: err)
        end
      end

      class AgentLogs < Dry::CLI::Command
        extend CommandMetadata

        desc "Print agent log (raw stream by default)"
        argument :agent_key, required: true, desc: "Agent key"
        option :type, default: "raw", desc: "Log type: raw, conversation, system"
        option :follow, type: :boolean, default: false, desc: "Follow the log (like tail -f)"
        usage_template "agent logs %{agent_key}"

        def call(agent_key:, **opts)
          exit CLICommand.agent_logs(agent_key, opts, out: out, err: err)
        end
      end

      class AgentSend < Dry::CLI::Command
        extend CommandMetadata

        desc "Send a message to an agent and re-run it"
        argument :agent_key, required: true, desc: "Agent key"
        argument :message, required: true, desc: "Message to send"
        usage_template "agent send %{agent_key} %{message}"

        def call(agent_key:, message:, **)
          exit CLICommand.send_agent_message(agent_key, message, out: out, err: err)
        end
      end

      class AgentArchive < Dry::CLI::Command
        extend CommandMetadata

        desc "Archive an agent and move its logs"
        argument :agent_key, required: true, desc: "Agent key"
        usage_template "agent archive %{agent_key}"

        def call(agent_key:, **)
          exit CLICommand.archive_agent(agent_key, out: out, err: err)
        end
      end

      class AgentClone < Dry::CLI::Command
        extend CommandMetadata

        desc "Clone an existing agent"
        argument :agent_key, required: true, desc: "Agent key to clone"
        option :run, type: :boolean, default: false, desc: "Start the cloned agent immediately"
        usage_template "agent clone %{agent_key}"

        def call(agent_key:, **opts)
          exit CLICommand.clone_agent(agent_key, opts, out: out, err: err)
        end
      end

      register "agent", Agent do |prefix|
        prefix.register "create", AgentCreate
        prefix.register "list", AgentList
        prefix.register "status", AgentStatus
        prefix.register "run", AgentRun
        prefix.register "stop", AgentStop
        prefix.register "logs", AgentLogs
        prefix.register "send", AgentSend
        prefix.register "archive", AgentArchive
        prefix.register "clone", AgentClone
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
    AGENT_COMMANDS = [
      Commands::AgentCreate,
      Commands::AgentList,
      Commands::AgentStatus,
      Commands::AgentRun,
      Commands::AgentStop,
      Commands::AgentLogs,
      Commands::AgentSend,
      Commands::AgentArchive,
      Commands::AgentClone,
    ].freeze
    SCHEDULE_COMMANDS = [
      Commands::ScheduleValidate,
      Commands::ScheduleList,
      Commands::ScheduleRun,
      Commands::SchedulePause,
      Commands::ScheduleResume,
      Commands::ScheduleReload
    ].freeze
    COMMAND_NAME = "tycho"
    RUNTIME_COMMANDS = [
      "  #{COMMAND_NAME} serve [daemon] [--host 127.0.0.1] [--port 7373]",
      "  #{COMMAND_NAME} schedule daemon [--once] [--dry-run] [--interval SECONDS]",
      "  #{COMMAND_NAME} doctor"
    ].freeze
    ACTIONS = APP_COMMANDS.filter_map { |command| command.action_name if command.respond_to?(:action_name) }.freeze
    USAGE = [
      "Usage:",
      "  #{COMMAND_NAME} --help",
      *RUNTIME_COMMANDS,
      *APP_COMMANDS.map { |command| "  #{COMMAND_NAME} #{format(command.usage_template, project_key: "<project-key>")}" },
      *PROJECT_COMMANDS.map { |command| "  #{COMMAND_NAME} #{format(command.usage_template, project_key: "<project-key>")}" },
      *AGENT_COMMANDS.map { |command|
        template = command.usage_template
        "  #{COMMAND_NAME} #{format(template, project_key: "<project-key>", agent_key: "<agent-key>", prompt: "<prompt>", message: "<message>")}"
      },
      *SCHEDULE_COMMANDS.map { |command| "  #{COMMAND_NAME} #{format(command.usage_template, schedule_key: "<schedule-key>")}" },
      "",
      "Run without a command to open the interactive Tycho TUI."
    ].join("\n").freeze

    module_function

    def run(argv, executable: nil)
      argv = Array(argv)
      return usage if argv.empty? || %w[--help -h].include?(argv.first)
      return serve(argv.drop(1), executable:) if argv.first == "serve"
      return doctor(argv.drop(1)) if argv.first == "doctor"
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

    def doctor(argv, out: $stdout, err: $stderr)
      return usage("Unexpected doctor arguments: #{argv.join(" ")}", err:) unless Array(argv).empty?

      require "bubbletea"
      require "bubbles"

      box = Lipgloss::Style.new.border(:rounded).padding(0, 1).width(8).render("ok")
      progress = Bubbles::Progress.new(width: 10, gradient: %w[#000000 #FFFFFF]).view_as(0.5)
      native_lipgloss = native_lipgloss_features
      backend = lipgloss_backend_label

      if darwin_amd64? && native_lipgloss.any?
        err.puts "Tycho runtime check failed: native Lipgloss loaded on Intel macOS."
        err.puts "Loaded native feature(s): #{native_lipgloss.join(", ")}"
        err.puts "Expected the Ruby compatibility backend. Try reinstalling Tycho or unset TYCHO_LIPGLOSS_BACKEND=native."
        return 1
      end

      out.puts "Tycho doctor: ok"
      out.puts "Lipgloss backend: #{backend}"
      out.puts "Native Lipgloss loaded: #{native_lipgloss.empty? ? "no" : "yes"}"
      out.puts "Render smoke: #{Bubbles::ANSI.strip(box).lines.first&.chomp} / #{Bubbles::ANSI.strip(progress)}"
      0
    rescue StandardError => e
      err.puts "Tycho runtime check failed: #{e.class}: #{e.message}"
      1
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

    def create_agent(project_key, prompt, opts, out: $stdout, err: $stderr)
      require_relative "registry"
      require_relative "harness_registry"

      registry = Registry.new
      project = registry.projects.find { |p| p.key == project_key.to_s }
      return failure("Unknown project: #{project_key}", err: err) unless project

      harness = opts[:harness].to_s.strip.downcase
      harness = project.agent.to_s if harness.empty?
      unless HQ.supported_harness?(harness)
        return failure("Unsupported harness #{harness.inspect}. Supported: #{HQ.harness_keys.join(", ")}", err: err)
      end

      template_key = opts[:template].to_s.strip
      agent_store = AgentStore.new(registry.projects)
      agent = agent_store.create_from_template(project, template_key)

      name = opts[:name].to_s.strip
      name = agent.name if name.empty?
      model = opts[:model].to_s.strip
      model = nil if model.empty?

      agent.update!(
        name: name,
        template_key: agent.template_key,
        workspace: agent.workspace,
        prompt: prompt.strip,
        agent: harness,
        model: model,
        reasoning_effort: agent.reasoning_effort
      )
      agent_store.ensure_project_context_prompt!(agent, project)

      existing = agent_store.load
      existing.unshift(agent)
      agent_store.save(existing)

      out.puts "Created agent #{agent.key}"
      out.puts "  Name:    #{agent.name}"
      out.puts "  Project: #{agent.project_key}"
      out.puts "  Harness: #{agent.agent}"
      out.puts "  Model:   #{agent.model || "(project default)"}"
      out.puts "  Prompt:  #{agent.prompt.lines.first&.chomp}"

      if opts[:run]
        agent.start!
        # Persist started state (pid, status, started_at) back to disk.
        existing = agent_store.load
        idx = existing.index { |a| a.key == agent.key }
        existing[idx] = agent if idx
        agent_store.save(existing)
        if agent.running?
          out.puts "  Status:  running (pid #{agent.pid})"
          out.puts "  Log:     #{agent.raw_log_path}"
        else
          out.puts "  Status:  start failed — #{agent.last_run&.error || "unknown error"}"
          return 1
        end
      end

      0
    rescue StandardError => e
      failure("Failed to create agent: #{e.message}", err: err)
    end

    def list_agents(project_key, out: $stdout, err: $stderr)
      agents = load_all_agents
      agents = agents.select { |a| a.project_key == project_key.to_s } if project_key
      if agents.empty?
        out.puts project_key ? "No agents for project: #{project_key}" : "No agents found."
        return 0
      end
      headers = %w[Key Project Name Harness Status Runs]
      rows = agents.map do |a|
        [a.key, a.project_key, a.name, a.agent, a.status, a.run_count.to_s]
      end
      out.puts agent_table(headers, rows)
      0
    rescue StandardError => e
      failure("Failed to list agents: #{e.message}", err: err)
    end

    def agent_status(agent_key, out: $stdout, err: $stderr)
      agent = load_all_agents.find { |a| a.key == agent_key.to_s }
      return failure("Unknown agent: #{agent_key}", err: err) unless agent

      last = agent.last_run
      rows = [
        ["Key", agent.key],
        ["Name", agent.name],
        ["Project", agent.project_key],
        ["Harness", agent.agent],
        ["Model", agent.model || "(project default)"],
        ["Status", agent.status],
        ["PID", agent.pid ? agent.pid.to_s : "n/a"],
        ["Runs", agent.run_count.to_s],
        ["Started", agent.started_at ? agent.started_at.strftime("%Y-%m-%d %H:%M:%S") : "n/a"],
        ["Finished", agent.finished_at ? agent.finished_at.strftime("%Y-%m-%d %H:%M:%S") : "n/a"],
        ["Exit code", agent.last_exit_code ? agent.last_exit_code.to_s : "n/a"],
        ["Last run", last ? last.started_at&.strftime("%Y-%m-%d %H:%M:%S") || "n/a" : "n/a"],
        ["Workspace", agent.workspace],
        ["Log", agent.raw_log_path || "n/a"],
      ]
      table = Lipgloss::Table.new
        .rows(rows)
        .border_style(Lipgloss::Style.new.foreground(COLORS[:accent_alt]))
        .style_func(rows: rows.length, columns: 2) { |_row, column|
          column.zero? ? Lipgloss::Style.new.bold(true).foreground(COLORS[:notice]) : Lipgloss::Style.new.foreground(COLORS[:text])
        }
      out.puts table.render
      0
    rescue StandardError => e
      failure("Failed to get agent status: #{e.message}", err: err)
    end

    def run_agent(agent_key, out: $stdout, err: $stderr)
      agent = load_all_agents.find { |a| a.key == agent_key.to_s }
      return failure("Unknown agent: #{agent_key}", err: err) unless agent
      return failure("Agent #{agent_key} is already running", err: err) if agent.running?

      agent.start!
      save_agent_in_store(agent)
      if agent.running?
        out.puts "Started #{agent.key} (pid #{agent.pid})"
        out.puts "Log: #{agent.raw_log_path}"
      else
        out.puts "Failed to start #{agent.key}"
        return 1
      end
      0
    rescue StandardError => e
      failure("Failed to run agent: #{e.message}", err: err)
    end

    def stop_agent(agent_key, out: $stdout, err: $stderr)
      agent = load_all_agents.find { |a| a.key == agent_key.to_s }
      return failure("Unknown agent: #{agent_key}", err: err) unless agent
      return failure("Agent #{agent_key} is not running", err: err) unless agent.running?

      agent.stop!
      save_agent_in_store(agent)
      out.puts "Stopped #{agent.key}"
      0
    rescue StandardError => e
      failure("Failed to stop agent: #{e.message}", err: err)
    end

    def agent_logs(agent_key, opts, out: $stdout, err: $stderr)
      agent = load_all_agents.find { |a| a.key == agent_key.to_s }
      return failure("Unknown agent: #{agent_key}", err: err) unless agent

      log_path = case opts[:type].to_s
                 when "conversation" then agent.conversation_log_path
                 when "system" then agent.system_log_path
                 else agent.raw_log_path
                 end

      return failure("Log file not found: #{log_path}", err: err) unless log_path && File.exist?(log_path)

      if opts[:follow]
        exec("tail", "-f", log_path)
      else
        out.puts File.read(log_path)
      end
      0
    rescue StandardError => e
      failure("Failed to read agent logs: #{e.message}", err: err)
    end

    def send_agent_message(agent_key, message, out: $stdout, err: $stderr)
      agent = load_all_agents.find { |a| a.key == agent_key.to_s }
      return failure("Unknown agent: #{agent_key}", err: err) unless agent
      return failure("Agent #{agent_key} is already running", err: err) if agent.running?

      agent.add_user_message!(message)
      agent.start!
      save_agent_in_store(agent)
      if agent.running?
        out.puts "Message sent and agent started (pid #{agent.pid})"
        out.puts "Log: #{agent.raw_log_path}"
      else
        out.puts "Message saved but agent failed to start"
        return 1
      end
      0
    rescue StandardError => e
      failure("Failed to send message: #{e.message}", err: err)
    end

    def archive_agent(agent_key, out: $stdout, err: $stderr)
      agents = load_all_agents
      agent = agents.find { |a| a.key == agent_key.to_s }
      return failure("Unknown agent: #{agent_key}", err: err) unless agent
      return failure("Agent #{agent_key} is running — stop it first", err: err) if agent.running?

      archive_path = agent.archive_logs!
      remaining = agents.reject { |a| a.key == agent_key.to_s }
      agent_store_for_all.save(remaining)
      out.puts "Archived #{agent.key}"
      out.puts "Archive: #{archive_path}" if archive_path
      0
    rescue StandardError => e
      failure("Failed to archive agent: #{e.message}", err: err)
    end

    def clone_agent(agent_key, opts, out: $stdout, err: $stderr)
      require_relative "registry"

      registry = Registry.new
      agents = load_all_agents
      source = agents.find { |a| a.key == agent_key.to_s }
      return failure("Unknown agent: #{agent_key}", err: err) unless source

      store = AgentStore.new(registry.projects)
      clone = store.clone_agent(source, existing_agents: agents)

      project = registry.projects.find { |p| p.key == clone.project_key }
      store.ensure_project_context_prompt!(clone, project) if project

      agents.unshift(clone)
      store.save(agents)

      out.puts "Cloned #{source.key} → #{clone.key}"
      out.puts "  Name:    #{clone.name}"
      out.puts "  Harness: #{clone.agent}"
      out.puts "  Model:   #{clone.model || "(project default)"}"

      if opts[:run]
        clone.start!
        store.save(store.load.map { |a| a.key == clone.key ? clone : a })
        if clone.running?
          out.puts "  Status:  running (pid #{clone.pid})"
          out.puts "  Log:     #{clone.raw_log_path}"
        else
          out.puts "  Status:  start failed"
          return 1
        end
      end
      0
    rescue StandardError => e
      failure("Failed to clone agent: #{e.message}", err: err)
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
      result = scheduler.resume(schedule_key)
      if result.fetch(:status) == :failed
        schedule = result.fetch(:schedule)
        return failure("Schedule #{schedule.fetch(:key)} failed: #{result.fetch(:error)}", err:)
      end

      schedule = result.fetch(:schedule)
      out.puts "Resumed #{schedule.fetch(:key)}."
      out.puts "Agent: #{result[:agent].key}" if result[:agent]
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
      headers = %w[Key Project Status Next Last Agent Runs Skips]
      table_rows = rows.map do |row|
        [
          row[:key],
          row[:project_key],
          row[:status] || "scheduled",
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

    def darwin_amd64?
      cpu = RbConfig::CONFIG["host_cpu"].to_s
      os = RbConfig::CONFIG["host_os"].to_s
      os.include?("darwin") && cpu.match?(/\A(?:x86_64|amd64)\z/)
    end

    def lipgloss_backend_label
      defined?(Lipgloss::BACKEND) ? Lipgloss::BACKEND.to_s : "native"
    end

    def native_lipgloss_features
      $LOADED_FEATURES.grep(%r{/lipgloss/\d+\.\d+/lipgloss\.(?:bundle|so)\z})
    end

    def load_all_agents
      agent_store_for_all.load
    rescue StandardError
      []
    end

    def agent_store_for_all
      require_relative "registry"

      AgentStore.new(Registry.new.projects)
    end

    def save_agent_in_store(agent)
      agents = load_all_agents
      idx = agents.index { |a| a.key == agent.key }
      if idx
        agents[idx] = agent
      else
        agents.unshift(agent)
      end
      agent_store_for_all.save(agents)
    end

    def agent_table(headers, rows)
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

    def find_app_project(project_key)
      registry_projects.find { |candidate| candidate.key == project_key.to_s }
    end

    def load_actions
      return {} unless File.exist?(ACTIONS_FILE)

      FileStore.read_json(ACTIONS_FILE, fallback: []).each_with_object({}) do |hash, actions|
        action = KamalAction.from_hash(hash)
        actions[action.project_key] = action
      end
    rescue StandardError => e
      warn "Failed to load actions: #{e.message}"
      {}
    end

    def save_actions(actions)
      FileStore.write_json(ACTIONS_FILE, actions.values.map(&:to_hash))
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
