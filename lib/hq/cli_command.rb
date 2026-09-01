# frozen_string_literal: true

require "json"
require "io/console"
require "open3"
require "rbconfig"
require "time"
require "uri"

require "dry/cli"
require "lipgloss"

require_relative "domain/project"
require_relative "domain/project_archiver"
require_relative "domain/file_store"
require_relative "domain/file_transaction"
require_relative "domain/github_api_client"
require_relative "domain/scheduler"
require_relative "domain/agent_store"
require_relative "domain/delegation_actor"
require_relative "domain/agent_archive_store"
require_relative "domain/usage_metrics"
require_relative "domain/server_identity"
require_relative "tycho_updater"

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

        def project_mutation_options(create:)
          option :path, desc: "Project directory (defaults to the current directory)" if create
          option :name, desc: create ? "Display name (defaults to the directory name)" : "Display name"
          option :group, desc: create ? "Project group" : "Project group (pass empty string to clear)"
          option :harness, desc: "Default agent harness"
          option :agent, desc: "Alias for --harness"
          option :model, desc: create ? "Default model override" : "Default model override (pass empty string to clear)"
          option :reasoning_effort,
                 desc: create ? "Default reasoning effort" : "Default reasoning effort (pass empty string to clear)"
          option :response_style, desc: "Response style path, default, or disabled"
          option :pr_url, desc: create ? "Open pull request URL" : "Open pull request URL (pass empty string to clear)"
          option :hidden, desc: "Visibility override: true, false, or inherit"
          option :json, type: :boolean, default: false, desc: "Print JSON"
        end

        def remote_options(json: true)
          option :server, desc: "Remote server key from hq.yml"
          option :json, type: :boolean, default: false, desc: "Print JSON" if json
        end
      end

      class Project < Dry::CLI::Command
        extend CommandMetadata

        desc "Manage project metadata"
        argument :project_key, required: false, desc: "Project key for quick creation"
        project_mutation_options(create: true)
        usage_template "project %{project_key} [options]"

        def call(project_key: nil, **opts)
          exit CLICommand.usage("Missing project command or project key", err: err) if project_key.to_s.empty?

          exit CLICommand.create_project(project_key, opts, out: out, err: err)
        end
      end

      class ProjectCreate < Dry::CLI::Command
        extend CommandMetadata

        desc "Create a project"
        argument :project_key, required: true, desc: "Project key"
        project_mutation_options(create: true)
        usage_template "project create %{project_key} [options]"

        def call(project_key:, **opts)
          exit CLICommand.create_project(project_key, opts, out: out, err: err)
        end
      end

      class ProjectShow < Dry::CLI::Command
        extend CommandMetadata

        desc "Show project configuration"
        argument :project_key, required: true, desc: "Project key"
        remote_options
        usage_template "project show %{project_key} [--server SERVER_KEY] [--json]"

        def call(project_key:, **opts)
          exit CLICommand.show_project(project_key, opts, out: out, err: err)
        end
      end

      class ProjectList < Dry::CLI::Command
        extend CommandMetadata

        desc "List projects"
        remote_options
        usage_template "project list [--server SERVER_KEY] [--json]"

        def call(**opts)
          exit CLICommand.list_projects(opts, out: out, err: err)
        end
      end

      class ProjectUpdate < Dry::CLI::Command
        extend CommandMetadata

        desc "Update project configuration"
        argument :project_key, required: true, desc: "Project key"
        project_mutation_options(create: false)
        usage_template "project update %{project_key} [options]"

        def call(project_key:, **opts)
          exit CLICommand.update_project(project_key, opts, out: out, err: err)
        end
      end

      class ProjectArchive < Dry::CLI::Command
        extend CommandMetadata

        desc "Archive a project and its managed agents"
        argument :project_key, required: true, desc: "Project key"
        option :json, type: :boolean, default: false, desc: "Print JSON"
        usage_template "project archive %{project_key} [--json]"

        def call(project_key:, **opts)
          exit CLICommand.archive_project(project_key, opts, out: out, err: err)
        end
      end

      register "project", Project do |prefix|
        prefix.register "create", ProjectCreate
        prefix.register "list", ProjectList
        prefix.register "show", ProjectShow
        prefix.register "update", ProjectUpdate
        prefix.register "archive", ProjectArchive
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
        option :model, desc: "Model override (e.g. claude-opus-4-8)"
        option :harness, desc: "Agent harness override (e.g. claude, codex, opencode)"
        option :name, desc: "Agent name override"
        option :template, desc: "Template key to use (defaults to project's first template)"
        option :run, type: :boolean, default: false, desc: "Start the agent immediately after creating"
        option :parent_agent, desc: "Originating parent agent key on the same Tycho server"
        option :root, type: :boolean, default: false,
                      desc: "Explicitly create an unrelated root agent"
        remote_options
        usage_template "agent create %{project_key} %{prompt} [--parent-agent KEY|--root] [--server SERVER_KEY] [--json]"

        def call(project_key:, prompt:, **opts)
          exit CLICommand.create_agent(project_key, prompt, opts, out: out, err: err)
        end
      end

      class AgentList < Dry::CLI::Command
        extend CommandMetadata

        desc "List managed agents"
        argument :project_key, required: false, desc: "Filter by project key"
        option :archived, type: :boolean, default: false, desc: "List archived agents only"
        option :include_archived, type: :boolean, default: false, desc: "Include archived agents with active agents"
        remote_options
        usage_template "agent list [%{project_key}] [--archived|--include-archived] [--server SERVER_KEY] [--json]"

        def call(**opts)
          exit CLICommand.list_agents(opts[:project_key], opts, out: out, err: err)
        end
      end

      class AgentStatus < Dry::CLI::Command
        extend CommandMetadata

        desc "Show status and metadata for an agent"
        argument :agent_key, required: true, desc: "Agent key"
        remote_options
        usage_template "agent status %{agent_key} [--server SERVER_KEY] [--json]"

        def call(agent_key:, **opts)
          exit CLICommand.agent_status(agent_key, opts, out: out, err: err)
        end
      end

      class AgentRun < Dry::CLI::Command
        extend CommandMetadata

        desc "Start (or re-run) an existing agent"
        argument :agent_key, required: true, desc: "Agent key"
        option :parent_agent, desc: "Attach the originating parent before this run"
        remote_options
        usage_template "agent run %{agent_key} [--server SERVER_KEY] [--json]"

        def call(agent_key:, **opts)
          exit CLICommand.run_agent(agent_key, opts, out: out, err: err)
        end
      end

      class AgentStop < Dry::CLI::Command
        extend CommandMetadata

        desc "Stop a running agent"
        argument :agent_key, required: true, desc: "Agent key"
        remote_options
        usage_template "agent stop %{agent_key} [--server SERVER_KEY] [--json]"

        def call(agent_key:, **opts)
          exit CLICommand.stop_agent(agent_key, opts, out: out, err: err)
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
        option :parent_agent, desc: "Attach the originating parent before this run"
        remote_options
        usage_template "agent send %{agent_key} %{message} [--server SERVER_KEY] [--json]"

        def call(agent_key:, message:, **opts)
          exit CLICommand.send_agent_message(agent_key, message, opts, out: out, err: err)
        end
      end

      class AgentArchive < Dry::CLI::Command
        extend CommandMetadata

        desc "Archive an agent and move its logs"
        argument :agent_key, required: true, desc: "Agent key"
        remote_options
        usage_template "agent archive %{agent_key} [--server SERVER_KEY] [--json]"

        def call(agent_key:, **opts)
          exit CLICommand.archive_agent(agent_key, opts, out: out, err: err)
        end
      end

      class AgentFinalize < Dry::CLI::Command
        desc "Finalize a completed managed run and deliver delegation callbacks"
        argument :agent_key, required: true, desc: "Agent key"

        def call(agent_key:, **)
          exit CLICommand.finalize_agent(agent_key, out: out, err: err)
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
        prefix.register "finalize", AgentFinalize
        prefix.register "clone", AgentClone
      end

      class Memory < Dry::CLI::Command
        desc "Retrieve memory handoffs"

        def call(**)
          exit CLICommand.usage("Missing memory command", err: err)
        end
      end

      class MemoryHandoffs < Dry::CLI::Command
        extend CommandMetadata

        desc "Print successful Second Brain handoffs with Tycho provenance"
        remote_options
        usage_template "memory handoffs [--server SERVER_KEY] [--json]"

        def call(**opts)
          exit CLICommand.memory_handoffs(opts, out: out, err: err)
        end
      end

      register "memory", Memory do |prefix|
        prefix.register "handoffs", MemoryHandoffs
      end

      class Server < Dry::CLI::Command
        desc "Manage remote server credentials"

        def call(**)
          exit CLICommand.usage("Missing server command", err: err)
        end
      end

      class ServerLogin < Dry::CLI::Command
        extend CommandMetadata

        desc "Save a remote server credential"
        argument :server_key, required: true, desc: "Remote server key"
        option :no_verify, type: :boolean, default: false, desc: "Save without contacting the server"
        usage_template "server login SERVER_KEY [--no-verify]"

        def call(server_key:, **opts)
          exit CLICommand.server_login(server_key, opts, input: $stdin, out: out, err: err)
        end
      end

      class ServerLogout < Dry::CLI::Command
        extend CommandMetadata

        desc "Delete a Tycho-stored remote server credential"
        argument :server_key, required: true, desc: "Remote server key"
        usage_template "server logout SERVER_KEY"

        def call(server_key:, **)
          exit CLICommand.server_logout(server_key, out: out, err: err)
        end
      end

      class ServerStatus < Dry::CLI::Command
        extend CommandMetadata

        desc "Show remote server credential metadata"
        argument :server_key, required: false, desc: "Remote server key"
        option :json, type: :boolean, default: false, desc: "Print JSON"
        usage_template "server status [SERVER_KEY] [--json]"

        def call(server_key: nil, **opts)
          exit CLICommand.server_status(server_key, opts, out: out, err: err)
        end
      end

      class ServerVerify < Dry::CLI::Command
        extend CommandMetadata

        desc "Verify the active credential for a remote server"
        argument :server_key, required: true, desc: "Remote server key"
        usage_template "server verify SERVER_KEY"

        def call(server_key:, **)
          exit CLICommand.server_verify(server_key, out: out, err: err)
        end
      end

      class ServerMigrate < Dry::CLI::Command
        extend CommandMetadata

        desc "Move inline hq.yml tokens into the credential store"
        argument :server_key, required: false, desc: "Remote server key"
        option :all, type: :boolean, default: false, desc: "Migrate every inline remote token"
        usage_template "server migrate [SERVER_KEY | --all]"

        def call(server_key: nil, **opts)
          exit CLICommand.server_migrate(server_key, opts, out: out, err: err)
        end
      end

      register "server", Server do |prefix|
        prefix.register "login", ServerLogin
        prefix.register "logout", ServerLogout
        prefix.register "status", ServerStatus
        prefix.register "verify", ServerVerify
        prefix.register "migrate", ServerMigrate
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

      class Github < Dry::CLI::Command
        desc "Manage GitHub authentication"

        def call(**)
          exit CLICommand.usage("Missing github command", err: err)
        end
      end

      class GithubLogin < Dry::CLI::Command
        extend CommandMetadata

        desc "Connect the Tycho GitHub App"
        usage_template "github login"

        def call(**)
          exit CLICommand.github_login(out: out, err: err)
        end
      end

      class GithubStatus < Dry::CLI::Command
        extend CommandMetadata

        desc "Show GitHub authentication status"
        usage_template "github status"

        def call(**)
          exit CLICommand.github_status(out: out, err: err)
        end
      end

      class GithubLogout < Dry::CLI::Command
        extend CommandMetadata

        desc "Delete the local Tycho GitHub App session"
        usage_template "github logout"

        def call(**)
          exit CLICommand.github_logout(out: out, err: err)
        end
      end

      register "github", Github do |prefix|
        prefix.register "login", GithubLogin
        prefix.register "status", GithubStatus
        prefix.register "logout", GithubLogout
      end

      class Debug < Dry::CLI::Command
        desc "Run diagnostics"

        def call(**)
          exit CLICommand.usage("Missing debug command", err: err)
        end
      end

      class DebugClaude < Dry::CLI::Command
        extend CommandMetadata

        desc "Run Claude diagnostics through Tycho's harness process path"
        option :run_agent, type: :boolean, default: false, desc: "Create and run a disposable Claude managed agent"
        usage_template "debug claude [--run-agent]"

        def call(**opts)
          exit CLICommand.debug_claude(opts, out: out, err: err)
        end
      end

      register "debug", Debug do |prefix|
        prefix.register "claude", DebugClaude
      end

      class Metrics < Dry::CLI::Command
        desc "Query or backfill usage metrics"

        def call(**)
          exit CLICommand.usage("Missing metrics command", err: err)
        end
      end

      class MetricsQuery < Dry::CLI::Command
        extend CommandMetadata

        desc "Query normalized run and native-session usage metrics"
        option :from, desc: "Inclusive range start (date/time)"
        option :to, desc: "Exclusive range end (date/time)"
        option :timezone, default: "UTC", desc: "IANA timezone for offset-free boundaries"
        option :group, desc: "Group filter (comma-separated)"
        option :project, desc: "Project filter (comma-separated)"
        option :agent, desc: "Agent filter (comma-separated)"
        option :harness, desc: "Harness filter (comma-separated)"
        option :model, desc: "Configured or observed model filter (comma-separated)"
        option :status, desc: "Run status filter (comma-separated)"
        remote_options
        usage_template "metrics query [--from TIME] [--to TIME] [--timezone ZONE] [filters] [--json]"

        def call(**opts)
          exit CLICommand.query_metrics(opts, out: out, err: err)
        end
      end

      class MetricsBackfill < Dry::CLI::Command
        extend CommandMetadata

        desc "Idempotently backfill normalized usage metrics"
        option :timezone, desc: "IANA timezone for legacy offset-free run headers"
        option :durable_only, type: :boolean, default: false, desc: "Do not inspect legacy raw telemetry"
        remote_options
        usage_template "metrics backfill [--timezone ZONE] [--durable-only] [--json]"

        def call(**opts)
          exit CLICommand.backfill_metrics(opts, out: out, err: err)
        end
      end

      register "metrics", Metrics do |prefix|
        prefix.register "query", MetricsQuery
        prefix.register "backfill", MetricsBackfill
      end
    end

    PROJECT_COMMANDS = [
      Commands::Project,
      Commands::ProjectCreate,
      Commands::ProjectList,
      Commands::ProjectShow,
      Commands::ProjectUpdate,
      Commands::ProjectArchive
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
    GITHUB_COMMANDS = [
      Commands::GithubLogin,
      Commands::GithubStatus,
      Commands::GithubLogout
    ].freeze
    SERVER_COMMANDS = [
      Commands::ServerLogin,
      Commands::ServerLogout,
      Commands::ServerStatus,
      Commands::ServerVerify,
      Commands::ServerMigrate
    ].freeze
    DEBUG_COMMANDS = [
      Commands::DebugClaude
    ].freeze
    METRICS_COMMANDS = [
      Commands::MetricsQuery,
      Commands::MetricsBackfill
    ].freeze
    COMMAND_NAME = "tycho"
    RUNTIME_COMMANDS = [
      "  #{COMMAND_NAME} serve [daemon] [--host 127.0.0.1] [--port 7373]",
      "  #{COMMAND_NAME} schedule daemon [--once] [--dry-run] [--interval SECONDS]",
      "  #{COMMAND_NAME} restart",
      "  #{COMMAND_NAME} update",
      "  #{COMMAND_NAME} doctor"
    ].freeze
    USAGE = [
      "Usage:",
      "  #{COMMAND_NAME} --help",
      *RUNTIME_COMMANDS,
      *PROJECT_COMMANDS.map { |command| "  #{COMMAND_NAME} #{format(command.usage_template, project_key: "<project-key>")}" },
      *AGENT_COMMANDS.map { |command|
        template = command.usage_template
        "  #{COMMAND_NAME} #{format(template, project_key: "<project-key>", agent_key: "<agent-key>", prompt: "<prompt>", message: "<message>")}"
      },
      *SCHEDULE_COMMANDS.map { |command| "  #{COMMAND_NAME} #{format(command.usage_template, schedule_key: "<schedule-key>")}" },
      *GITHUB_COMMANDS.map { |command| "  #{COMMAND_NAME} #{command.usage_template}" },
      *SERVER_COMMANDS.map { |command| "  #{COMMAND_NAME} #{command.usage_template}" },
      *METRICS_COMMANDS.map { |command| "  #{COMMAND_NAME} #{command.usage_template}" },
      *DEBUG_COMMANDS.map { |command| "  #{COMMAND_NAME} #{command.usage_template}" },
      "",
      "Run without a command to open the interactive Tycho TUI."
    ].join("\n").freeze

    module_function

    def run(argv, executable: nil)
      argv = Array(argv)
      return usage if argv.empty? || %w[--help -h].include?(argv.first)
      return serve(argv.drop(1), executable:) if argv.first == "serve"
      return restart(argv.drop(1), executable:) if argv.first == "restart"
      return update(argv.drop(1), executable:) if argv.first == "update"
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

    def restart(argv, executable: nil, restarter: nil)
      return usage("Unexpected restart arguments: #{argv.join(" ")}") unless Array(argv).empty?

      (restarter || HQ::CLI.method(:restart!)).call([], executable || File.expand_path("../../bin/tycho", __dir__))
      0
    end

    def update(argv, executable: nil, out: $stdout, err: $stderr, updater: nil)
      return usage("Unexpected update arguments: #{argv.join(" ")}", err:) unless Array(argv).empty?

      result = (updater || TychoUpdater.new(executable: executable || $PROGRAM_NAME)).update!
      out.puts result.fetch(:detail)
      out.puts "Restart Tycho Remote and the scheduler daemon through their existing controls to load the update."
      0
    rescue TychoUpdater::Error => e
      failure(e.message, err:)
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
      github = GitHubAPIClient.new.capability
      github_status = github[:enabled] ? "enabled via #{github[:source]}" : "disabled (connect GitHub App or run `gh auth login`)"
      out.puts "GitHub PR review: #{github_status}"
      0
    rescue StandardError => e
      err.puts "Tycho runtime check failed: #{e.class}: #{e.message}"
      1
    end

    def github_login(out: $stdout, err: $stderr, auth: GitHubAuth.default, sleeper: Kernel.method(:sleep))
      device = auth.start_device_flow
      out.puts "Connect the Tycho GitHub App"
      out.puts "Open: #{device.fetch(:verification_uri)}"
      out.puts "Code: #{device.fetch(:user_code)}"
      out.puts "Waiting for GitHub authorization..."
      interval = device.fetch(:interval, 5).to_i
      loop do
        sleeper.call([interval, 1].max)
        result = auth.poll_device_flow(device.fetch(:id))
        if result[:status] == "authenticated"
          account = result[:account].to_s
          out.puts(account.empty? ? "GitHub connected." : "GitHub connected as @#{account}.")
          return 0
        end
        interval = result.fetch(:retry_after, interval).to_i
      end
    rescue GitHubAuth::Error => e
      failure(e.message, err:)
    rescue Interrupt
      failure("GitHub login cancelled.", err:)
    end

    def query_metrics(opts = {}, out: $stdout, err: $stderr)
      return remote_query_metrics(opts, out:, err:) if remote_requested?(opts)

      result = UsageMetrics.query(metric_filters(opts))
      print_metrics(result, json: opts[:json], out:)
      0
    rescue ArgumentError => e
      failure(e.message, err:)
    end

    def backfill_metrics(opts = {}, out: $stdout, err: $stderr)
      return remote_backfill_metrics(opts, out:, err:) if remote_requested?(opts)

      result = UsageMetrics.backfill({
        "timezone" => opts[:timezone],
        "include_raw" => opts[:durable_only] != true
      })
      print_backfill(result, json: opts[:json], out:)
      0
    rescue ArgumentError, ConfigError => e
      failure(e.message, err:)
    end

    def github_status(out: $stdout, err: $stderr, auth: GitHubAuth.default)
      github = auth.capability
      out.puts "GitHub provider: #{github[:source]}"
      out.puts "Tycho GitHub App: #{github.dig(:app, :authenticated) ? "connected" : github.dig(:app, :configured) ? "ready to connect" : "not configured"}"
      out.puts "Account: @#{github.dig(:app, :account)}" unless github.dig(:app, :account).to_s.empty?
      out.puts "Expires: #{github.dig(:app, :expires_at)}" unless github.dig(:app, :expires_at).to_s.empty?
      out.puts "GitHub CLI: #{github.dig(:gh, :authenticated) ? "authenticated" : github.dig(:gh, :available) ? "not authenticated" : "not installed"}"
      github[:enabled] ? 0 : 1
    rescue GitHubAuth::Error => e
      failure(e.message, err:)
    end

    def github_logout(out: $stdout, err: $stderr, auth: GitHubAuth.default)
      auth.logout
      out.puts "Tycho GitHub App session removed."
      0
    rescue GitHubAuth::Error => e
      failure(e.message, err:)
    end

    def server_login(server_key, opts = {}, input: $stdin, out: $stdout, err: $stderr)
      registry, config, resolver = remote_credential_context(server_key, err: err)
      return 1 unless config
      unless config.token_env.to_s.empty?
        return failure(
          "Remote server #{config.key} uses external credential #{config.token_env}; " \
          "update that environment variable or remove token_env before storing a Tycho credential",
          err: err
        )
      end

      err.print "Token for #{config.key}: "
      token = if input.respond_to?(:tty?) && input.tty? && input.respond_to?(:noecho)
                input.noecho(&:gets)
              else
                input.gets
              end
      err.puts
      token = token.to_s.chomp
      return failure("Remote token is required", err: err) if token.empty?

      unless opts[:no_verify]
        credential = resolver.transient(config, token)
        RemoteCLIClient.new(config, credential_resolver: resolver, credential: credential).request("GET", "/agents")
      end
      resolver.save(config, token: token, verified: !opts[:no_verify])
      state = opts[:no_verify] ? "unverified" : "verified"
      out.puts "Stored #{state} credential for #{config.key} in #{resolver.store.path}"
      0
    rescue RemoteCLIClient::Error, RemoteCredentialResolver::Error, ConfigError => e
      failure(e.message, err: err)
    ensure
      token = nil
    end

    def server_logout(server_key, out: $stdout, err: $stderr)
      _registry, config, resolver = remote_credential_context(server_key, err: err)
      return 1 unless config

      removed = resolver.store.delete_token(config.key)
      out.puts(removed ? "Removed stored credential for #{config.key}." : "No stored credential for #{config.key}.")
      unless config.token_env.to_s.empty?
        state = ENV[config.token_env].to_s.empty? ? "not set" : "still active"
        out.puts "External source #{config.token_env} is #{state}; Tycho did not change it."
      end
      0
    rescue ConfigError => e
      failure(e.message, err: err)
    end

    def server_status(server_key = nil, opts = {}, out: $stdout, err: $stderr)
      require_relative "registry"
      require_relative "domain/remote_credential_store"

      registry = Registry.new
      configs = Array(registry.remote_servers)
      unless server_key.to_s.empty?
        configs = configs.select { |config| config.key == server_key.to_s }
        return failure("Unknown remote server: #{server_key}", err: err) if configs.empty?
      end
      store = RemoteCredentialStore.new(registry: registry)
      resolver = RemoteCredentialResolver.new(store: store, warning: ->(_message) {})
      statuses = configs.map { |config| remote_credential_status(config, resolver) }

      if opts[:json]
        value = server_key.to_s.empty? ? statuses : statuses.first
        out.puts JSON.pretty_generate(value)
      elsif statuses.empty?
        out.puts "No remote servers configured."
      else
        rows = statuses.map do |status|
          [status[:key], status[:source], status[:state], status[:origin] || "—", status[:token_env] || "—"]
        end
        out.puts agent_table(%w[Key Source State Origin Token-env], rows)
      end
      0
    rescue ConfigError => e
      failure(e.message, err: err)
    end

    def server_verify(server_key, out: $stdout, err: $stderr)
      _registry, config, resolver = remote_credential_context(server_key, err: err)
      return 1 unless config

      credential = resolver.resolve(config, allow_rejected: true, allow_origin_change: true)
      return failure("Remote server #{config.key} has no credential to verify", err: err) if credential.token.to_s.empty?
      if credential.source == "inline"
        return failure("Run `tycho server migrate #{config.key}` before verifying its inline credential", err: err)
      end

      RemoteCLIClient.new(config, credential_resolver: resolver, credential: credential).request("GET", "/agents")
      out.puts "Verified #{credential.source} credential for #{config.key} at #{resolver.canonical_origin(config.url)}"
      0
    rescue RemoteCLIClient::Error, RemoteCredentialResolver::Error, ConfigError => e
      failure(e.message, err: err)
    end

    def server_migrate(server_key = nil, opts = {}, out: $stdout, err: $stderr)
      require_relative "registry"
      require_relative "domain/remote_credential_store"

      return failure("Choose SERVER_KEY or --all, not both", err: err) if opts[:all] && !server_key.to_s.empty?
      return failure("Missing SERVER_KEY or --all", err: err) unless opts[:all] || !server_key.to_s.empty?

      registry = Registry.new
      configs = if opts[:all]
                  Array(registry.remote_servers).select { |config| !config.token.to_s.empty? }
                else
                  config = Array(registry.remote_servers).find { |candidate| candidate.key == server_key.to_s }
                  return failure("Unknown remote server: #{server_key}", err: err) unless config
                  return failure("Remote server #{config.key} has no inline token to migrate", err: err) if config.token.to_s.empty?
                  [config]
                end
      resolver = RemoteCredentialResolver.new(store: RemoteCredentialStore.new(registry: registry))
      configs.each do |config|
        resolver.save(config, token: config.token, verified: false)
        registry.remove_remote_server_inline_token!(config.key)
        out.puts "Migrated #{config.key} to #{resolver.store.path} (unverified)."
      end
      out.puts "No inline remote tokens found." if configs.empty?
      0
    rescue ConfigError => e
      failure(e.message, err: err)
    end

    def remote_credential_context(server_key, err:)
      require_relative "registry"
      require_relative "domain/remote_cli_client"
      require_relative "domain/remote_credential_store"

      registry = Registry.new
      config = Array(registry.remote_servers).find { |candidate| candidate.key == server_key.to_s }
      unless config
        failure("Unknown remote server: #{server_key}", err: err)
        return [registry, nil, nil]
      end
      store = RemoteCredentialStore.new(registry: registry)
      resolver = RemoteCredentialResolver.new(store: store, warning: ->(message) { err.puts message })
      [registry, config, resolver]
    end

    def remote_credential_status(config, resolver)
      origin = resolver.canonical_origin(config.url)
      stored = resolver.store.metadata(config.key)
      token_env = config.token_env.to_s.strip
      source, metadata, state = if !token_env.empty?
                                  external = stored.fetch("external", {})
                                  external_state = ENV[token_env].to_s.empty? ? "missing" : external.fetch("state", "unverified")
                                  ["external", external, external_state]
                                elsif !resolver.store.stored(config.key)["token"].to_s.empty?
                                  item = stored.fetch("stored", {})
                                  ["stored", item, item.fetch("state", "unverified")]
                                elsif !config.token.to_s.empty?
                                  ["inline", {}, "legacy"]
                                else
                                  ["none", {}, "missing"]
                                end
      bound_origin = metadata["origin"]
      state = "origin_mismatch" if bound_origin && bound_origin != origin
      {
        key: config.key,
        name: config.name,
        url: config.url,
        origin: bound_origin || origin,
        source: source,
        state: state,
        token_env: token_env.empty? ? nil : token_env,
        verified_at: metadata["verified_at"],
        rejected_at: metadata["rejected_at"],
        updated_at: metadata["updated_at"]
      }
    end

    def debug_claude(opts = {}, out: $stdout, err: $stderr)
      return debug_claude_agent(out: out, err: err) if opts[:run_agent]

      require_relative "domain/executable_resolver"
      require_relative "domain/managed_agent"

      resolution = ExecutableResolver.resolve_tool("claude")
      unless resolution.available?
        return failure("Claude executable not found. Set TYCHO_CLAUDE_BIN or install claude.", err: err)
      end

      command = [resolution.command, "auth", "status"]
      stdout, stderr, status = Open3.capture3(
        diagnostic_harness_environment,
        RbConfig.ruby, "-e", diagnostic_runner_script, *command,
        chdir: Dir.pwd
      )

      out.puts "Tycho Claude auth diagnostic"
      out.puts "Claude executable: #{resolution.command} (#{resolution.source})"
      out.puts "Runner: #{RbConfig.ruby} -e <tycho harness runner>"
      out.puts "Command: #{command.join(" ")}"
      out.puts
      out.puts "Relevant parent environment:"
      rows = diagnostic_environment_rows
      if rows.empty?
        out.puts "  (none)"
      else
        rows.each { |key, value| out.puts "  #{key}=#{value}" }
      end
      out.puts
      out.puts "Harness environment overrides:"
      diagnostic_harness_environment_rows(diagnostic_harness_environment).each do |key, value|
        out.puts "  #{key}=#{value}"
      end
      out.puts
      out.puts "stdout:"
      out.puts stdout.to_s.empty? ? "  (empty)" : indent(stdout)
      out.puts
      out.puts "stderr:"
      out.puts stderr.to_s.empty? ? "  (empty)" : indent(stderr)
      out.puts
      out.puts "Exit status: #{status.exitstatus}"
      status.success? ? 0 : status.exitstatus.to_i
    rescue StandardError => e
      failure("Failed to run Claude auth diagnostic: #{e.class}: #{e.message}", err: err)
    end

    def debug_claude_agent(out: $stdout, err: $stderr)
      require_relative "registry"
      require_relative "harness_registry"

      registry = Registry.new
      project = debug_project(registry)
      return failure("No project available for Claude debug agent.", err: err) unless project
      return failure("Claude harness is not available in this Tycho configuration.", err: err) unless HQ.supported_harness?("claude")

      agent_store = AgentStore.new(registry.projects)
      agent = agent_store.create_from_template(project, "custom")
      agent.update!(
        name: "Claude debug agent",
        template_key: agent.template_key,
        workspace: agent.workspace,
        prompt: "Reply with OK",
        agent: "claude",
        model: nil,
        reasoning_effort: nil
      )
      agent_store.ensure_project_context_prompt!(agent, project)

      agents = agent_store.load
      agents.unshift(agent)
      agent_store.save(agents)

      agent = agent_store.start_agent!(agent.key)
      started = agent.running? || agent.last_run

      out.puts "Tycho Claude managed-agent diagnostic"
      out.puts "Agent: #{agent.key}"
      out.puts "Project: #{agent.project_key}"
      out.puts "Harness: #{agent.agent}"
      out.puts "Model: #{agent.model || "(claude default)"}"
      out.puts "Reasoning effort: #{agent.reasoning_effort || "(claude default)"}"
      out.puts "Log: #{agent.raw_log_path}"

      unless started && agent.pid
        out.puts "Status: start failed"
        return 1
      end

      out.puts "Started: pid #{agent.pid}"
      wait_for_debug_agent(agent)
      save_agent_in_store(agent)

      out.puts "Final status: #{agent.status}"
      out.puts "Exit code: #{agent.last_exit_code.nil? ? "n/a" : agent.last_exit_code}"
      out.puts "Summary: #{agent.last_summary}"
      agent.status == "succeeded" ? 0 : 1
    rescue StandardError => e
      failure("Failed to run Claude managed-agent diagnostic: #{e.class}: #{e.message}", err: err)
    end

    def registry_projects
      require_relative "registry"

      Registry.new.projects.map { |config| Project.new(config) }
    end

    def debug_project(registry)
      projects = registry.projects
      cwd = File.expand_path(Dir.pwd)
      projects.find { |project| project.key == "tycho" } ||
        projects.find { |project| File.expand_path(project.path.to_s) == cwd } ||
        projects.first
    end

    def wait_for_debug_agent(agent, timeout: 20)
      deadline = Time.now + timeout.to_f
      while agent.running? && Time.now < deadline
        sleep 0.2
      end
      agent.poll!
      agent
    end

    def diagnostic_runner_script
      <<~RUBY
        result = system(*ARGV)
        child = $?
        exit(child ? child.exitstatus.to_i : (result ? 0 : 1))
      RUBY
    end

    def diagnostic_harness_environment
      agent = ManagedAgent.new(
        key: "diagnostic",
        name: "Diagnostic",
        project_key: "diagnostic",
        template_key: "custom",
        workspace: Dir.pwd,
        prompt: "diagnostic",
        agent: "claude"
      )
      agent.send(:external_process_environment, {})
    end

    def diagnostic_environment_rows
      ENV.keys
        .select { |key| diagnostic_environment_key?(key) }
        .sort
        .map { |key| [key, diagnostic_environment_value(key)] }
    end

    def diagnostic_harness_environment_rows(env)
      env.keys
        .select { |key| diagnostic_environment_key?(key) }
        .sort
        .map { |key| [key, env[key].nil? ? "(unset)" : diagnostic_environment_value(key, env[key])] }
    end

    def diagnostic_environment_key?(key)
      key.start_with?("ANTHROPIC", "CLAUDE", "AWS", "GOOGLE", "VERTEX", "BEDROCK") ||
        %w[BUNDLE_BIN_PATH BUNDLE_GEMFILE BUNDLER_VERSION GEM_HOME GEM_PATH RUBYLIB RUBYOPT TYCHO_CLAUDE_BIN].include?(key)
    end

    def diagnostic_environment_value(key, raw_value = ENV[key])
      value = raw_value.to_s
      return "(empty)" if value.empty?

      if key.match?(/KEY|TOKEN|SECRET|PASSWORD|CREDENTIAL/i)
        "(set, #{value.length} chars)"
      else
        value
      end
    end

    def indent(text, prefix = "  ")
      text.to_s.each_line.map { |line| "#{prefix}#{line}" }.join
    end

    def create_project(project_key, opts, out: $stdout, err: $stderr)
      require_relative "registry"
      require_relative "harness_registry"

      key = project_key.to_s.strip
      return failure("Project key is required", err: err) if key.empty?

      path = opts[:path].to_s.strip
      path = Dir.pwd if path.empty?
      path = File.expand_path(path)
      return failure("Project path does not exist: #{path}", err: err) unless File.directory?(path)

      name = opts[:name].to_s.strip
      name = File.basename(path) if name.empty?
      name = key if name.empty? || name == File::SEPARATOR
      harness = project_harness_option(opts, default: HQ.harness_keys.first)
      attrs = {
        key: key,
        name: name,
        path: path,
        agent: harness
      }
      copy_project_option!(attrs, opts, :group)
      copy_project_option!(attrs, opts, :model)
      copy_project_option!(attrs, opts, :reasoning_effort)
      copy_project_option!(attrs, opts, :pr_url)
      attrs[:response_style] = project_response_style_option(opts[:response_style]) if opts.key?(:response_style)
      attrs[:hidden] = project_hidden_option(opts[:hidden]) if opts.key?(:hidden)

      registry = Registry.new
      registry.add_project!(attrs)
      config = registry.projects.find { |project| project.key == key }
      payload = project_config_payload(config)
      print_project_result(payload, json: opts[:json], out: out, action: "Created")
      0
    rescue StandardError => e
      failure("Failed to create #{project_key}: #{e.message}", err: err)
    end

    def show_project(project_key, opts = {}, out: $stdout, err: $stderr)
      return remote_show_project(project_key, opts, out:, err:) if remote_requested?(opts)

      require_relative "registry"

      registry = Registry.new
      config = registry.projects.find { |project| project.key == project_key.to_s }
      return failure("Unknown project: #{project_key}", err: err) unless config

      print_project_result(project_config_payload(config), json: opts[:json], out: out)
      0
    rescue StandardError => e
      failure("Failed to show #{project_key}: #{e.message}", err: err)
    end

    def list_projects(opts = {}, out: $stdout, err: $stderr)
      return remote_list_projects(opts, out:, err:) if remote_requested?(opts)

      payload = registry_projects.map do |project|
        project.refresh_metadata!
        {
          key: project.key,
          name: project.name,
          group: project.group.empty? ? nil : project.group,
          path: project.path,
          status: project.status
        }
      end
      print_project_list(payload, json: opts[:json], out: out)
      0
    rescue StandardError => e
      failure("Failed to list projects: #{e.message}", err: err)
    end

    def update_project(project_key, opts, out: $stdout, err: $stderr)
      require_relative "registry"
      require_relative "harness_registry"

      attrs = {}
      %i[name group model reasoning_effort pr_url].each { |field| copy_project_option!(attrs, opts, field) }
      attrs[:agent] = project_harness_option(opts) if opts.key?(:harness) || opts.key?(:agent)
      attrs[:response_style] = project_response_style_option(opts[:response_style]) if opts.key?(:response_style)
      attrs[:hidden] = project_hidden_option(opts[:hidden]) if opts.key?(:hidden)
      return failure("No fields to update", err: err) if attrs.empty?

      registry = Registry.new
      updated = registry.update_project!(project_key, attrs)
      return failure("Unknown project: #{project_key}", err: err) unless updated

      config = registry.projects.find { |project| project.key == project_key.to_s }
      print_project_result(project_config_payload(config), json: opts[:json], out: out, action: "Updated")
      0
    rescue StandardError => e
      failure("Failed to update #{project_key}: #{e.message}", err: err)
    end

    def archive_project(project_key, opts = {}, out: $stdout, err: $stderr)
      require_relative "registry"

      registry = Registry.new
      config = registry.projects.find { |candidate| candidate.key == project_key.to_s }
      return failure("Unknown project: #{project_key}", err: err) unless config

      payload = project_config_payload(config)
      archived = ProjectArchiver.new(registry:).archive(project_key)

      result = {
        project: payload,
        archived_agent_keys: archived.archived_agent_keys,
        project_log_archive: archived.project_log_archive,
        agent_log_archives: archived.agent_log_archives
      }
      if opts[:json]
        out.puts JSON.pretty_generate(result)
      else
        out.puts "Archived project #{project_key}"
        out.puts "Project logs: #{archived.project_log_archive}" if archived.project_log_archive
        unless archived.archived_agent_keys.empty?
          out.puts "Archived agents: #{archived.archived_agent_keys.join(", ")}"
        end
      end
      0
    rescue StandardError => e
      failure("Failed to archive #{project_key}: #{e.message}", err: err)
    end

    def copy_project_option!(attrs, opts, field)
      return unless opts.key?(field)

      value = opts[field]
      value = nil if value.is_a?(String) && value.strip.empty?
      attrs[field] = value
    end

    def project_harness_option(opts, default: nil)
      harness = opts[:harness].to_s.strip.downcase
      agent = opts[:agent].to_s.strip.downcase
      if !harness.empty? && !agent.empty? && harness != agent
        raise ArgumentError, "--harness and --agent must match when both are provided"
      end

      selected = harness.empty? ? agent : harness
      selected = default.to_s if selected.empty?
      unless HQ.supported_harness?(selected)
        raise ArgumentError, "Unsupported harness #{selected.inspect}. Supported: #{HQ.harness_keys.join(", ")}"
      end
      selected
    end

    def project_response_style_option(value)
      text = value.to_s.strip
      return nil if text.empty? || %w[default global inherit].include?(text.downcase)
      return false if %w[none disabled off false].include?(text.downcase)

      text
    end

    def project_hidden_option(value)
      case value.to_s.strip.downcase
      when "true", "yes", "on", "1", "hidden" then true
      when "false", "no", "off", "0", "visible" then false
      when "inherit", "default", "nil", "null", "" then nil
      else
        raise ArgumentError, "--hidden must be true, false, or inherit"
      end
    end

    def project_config_payload(config)
      project = Project.new(config)
      project.refresh_metadata!
      {
        key: project.key,
        name: project.name,
        group: project.group.empty? ? nil : project.group,
        path: project.path,
        harness: config.agent,
        model: config.model,
        reasoning_effort: config.reasoning_effort,
        response_style: config.response_style,
        pr_url: config.pr_url,
        hidden: project.hidden?,
        hidden_override: config.hidden_config,
        visibility_source: project.visibility_source,
        git: {
          branch: project.branch,
          commit: project.commit_hash,
          dirty_files: project.dirty_files
        }
      }
    end

    def print_project_result(payload, json:, out:, action: nil)
      return out.puts(JSON.pretty_generate(payload)) if json

      out.puts "#{action} project #{payload.fetch(:key)}" if action
      rows = [
        ["Key", payload[:key]],
        ["Name", payload[:name]],
        ["Group", payload[:group] || "(none)"],
        ["Path", payload[:path]],
        ["Harness", payload[:harness]],
        ["Model", payload[:model] || "(harness default)"],
        ["Reasoning effort", payload[:reasoning_effort] || "(harness default)"],
        ["Response style", project_response_style_label(payload[:response_style])],
        ["PR URL", payload[:pr_url] || "(none)"],
        ["Visibility", payload[:hidden] ? "hidden (#{payload[:visibility_source]})" : "visible (#{payload[:visibility_source]})"],
        ["Branch", payload.dig(:git, :branch) || "n/a"],
        ["Commit", payload.dig(:git, :commit) || "n/a"],
        ["Dirty files", payload.dig(:git, :dirty_files).to_i.to_s]
      ]
      table = Lipgloss::Table.new
        .rows(rows)
        .border_style(Lipgloss::Style.new.foreground(COLORS[:accent_alt]))
        .style_func(rows: rows.length, columns: 2) { |_row, column|
          column.zero? ? Lipgloss::Style.new.bold(true).foreground(COLORS[:notice]) : Lipgloss::Style.new.foreground(COLORS[:text])
        }
      out.puts table.render
    end

    def project_response_style_label(value)
      return "disabled" if value == false
      return "global default" if value.nil?

      value.to_s
    end

    def create_agent(project_key, prompt, opts, out: $stdout, err: $stderr)
      opts = create_delegation_options(opts)
      return remote_create_agent(project_key, prompt, opts, out:, err:) if remote_requested?(opts)

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
      agent = persist_agents_with_parent!(agent_store, existing, agent, opts, creating: true)
      agent_store.accept_prompt_from!(agent, actor: opts.fetch(:actor), agents: existing) if agent.delegation_parent

      if opts[:run]
        agent = agent_store.start_agent!(agent.key)
        unless agent.running?
          out.puts "Status: start failed — #{agent.last_run&.error || "unknown error"}" unless opts[:json]
          return 1
        end
      end

      print_created_agent(agent_cli_payload(agent), json: opts[:json], out: out)
      0
    rescue StandardError => e
      failure("Failed to create agent: #{e.message}", err: err)
    end

    def create_delegation_options(opts)
      opts = opts.dup
      parent_key = opts[:parent_agent].to_s.strip
      root = opts[:root] == true
      raise ArgumentError, "Choose either --parent-agent or --root" if root && !parent_key.empty?

      parent_key = "" if root
      opts.merge(
        parent_agent: parent_key.empty? ? nil : parent_key,
        actor: delegation_actor(parent_key)
      )
    end

    def list_agents(project_key, opts = {}, out: $stdout, err: $stderr)
      return failure("Choose either --archived or --include-archived", err: err) if opts[:archived] && opts[:include_archived]
      return remote_list_agents(project_key, opts, out:, err:) if remote_requested?(opts)

      active_agents = opts[:archived] ? [] : load_all_agents
      archived_agents = if opts[:archived] || opts[:include_archived]
                          AgentArchiveStore.new.all.map(&:agent).sort_by { |agent| agent.archived_at || Time.at(0) }.reverse
                        else
                          []
                        end
      agents = active_agents + archived_agents
      agents = agents.select { |a| a.project_key == project_key.to_s } if project_key
      archive_fields = opts[:archived] || opts[:include_archived]
      relationship_context = agent_cli_relationship_context
      payload = agents.map do |agent|
        agent_cli_payload(
          agent,
          delegation: agent_cli_delegation(agent, relationship_context: relationship_context),
          archive_fields: archive_fields
        )
      end
      if opts[:json]
        out.puts JSON.pretty_generate(payload)
        return 0
      end
      if agents.empty?
        out.puts project_key ? "No agents for project: #{project_key}" : "No agents found."
        return 0
      end
      headers = archive_fields ? %w[Key Project Name Parent Harness State Status Runs] : %w[Key Project Name Parent Harness Status Runs]
      rows = agents.map do |a|
        row = [a.key, a.project_key, a.name, a.delegation_parent&.fetch("agent_key", nil) || "-", a.agent]
        row << (a.archived? ? "archived" : "active") if archive_fields
        row + [a.status, a.run_count.to_s]
      end
      out.puts agent_table(headers, rows)
      0
    rescue StandardError => e
      failure("Failed to list agents: #{e.message}", err: err)
    end

    def agent_status(agent_key, opts = {}, out: $stdout, err: $stderr)
      return remote_agent_status(agent_key, opts, out:, err:) if remote_requested?(opts)

      agent = load_all_agents.find { |a| a.key == agent_key.to_s } || AgentArchiveStore.new.find(agent_key)&.agent
      return failure("Unknown agent: #{agent_key}", err: err) unless agent

      print_agent_status(agent_cli_payload(agent, archive_fields: agent.archived?), json: opts[:json], out: out)
      0
    rescue StandardError => e
      failure("Failed to get agent status: #{e.message}", err: err)
    end

    def memory_handoffs(opts = {}, out: $stdout, err: $stderr)
      return remote_memory_handoffs(opts, out:, err:) if remote_requested?(opts)

      projects = registry_projects.each_with_object({}) do |project, result|
        result[project.key] = project.group if %w[Personal Cookpad].include?(project.group.to_s)
      end
      runs = load_all_agents.flat_map do |agent|
        next [] unless projects.key?(agent.project_key)

        agent.runs.filter_map do |run|
          handoff = MemoryHandoff.normalize(run.metadata.is_a?(Hash) ? run.metadata["memory_handoff"] : nil)
          next unless run.run_id.to_s.strip != "" && run.finished_at && run.status == "success" && handoff

          {
            run_id: run.run_id,
            finished_at: run.finished_at.iso8601,
            status: run.status,
            project: agent.project_key,
            metadata: { memory_handoff: handoff }
          }
        end
      end
      payload = {
        server: ServerIdentity.load.fetch("id"),
        projects: projects,
        runs: runs.sort_by { |run| [run[:finished_at], run[:run_id]] }
      }
      print_memory_handoffs(payload, json: opts[:json], out:)
      0
    rescue StandardError => e
      failure("Failed to get memory handoffs: #{e.message}", err: err)
    end

    def run_agent(agent_key, opts = {}, out: $stdout, err: $stderr)
      opts = opts.merge(actor: delegation_actor(opts[:parent_agent]))
      return remote_agent_action(agent_key, "start", opts, out:, err:) if remote_requested?(opts)

      store = agent_store_for_all
      agents = store.load
      agent = agents.find { |a| a.key == agent_key.to_s }
      return archived_agent_failure(agent_key, err:) if !agent && archived_agent?(agent_key)
      return failure("Unknown agent: #{agent_key}", err: err) unless agent
      return failure("Agent #{agent_key} is already running", err: err) if agent.running?

      agent = persist_agents_with_parent!(store, agents, agent, opts)
      store.accept_prompt_from!(agent, actor: opts.fetch(:actor), agents: agents) if agent.delegation_parent
      agent = store.start_agent!(agent.key)
      if agent.running?
        print_started_agent(agent_cli_payload(agent), json: opts[:json], out: out)
      else
        out.puts "Failed to start #{agent.key}"
        return 1
      end
      0
    rescue StandardError => e
      failure("Failed to run agent: #{e.message}", err: err)
    end

    def stop_agent(agent_key, opts = {}, out: $stdout, err: $stderr)
      return remote_agent_action(agent_key, "stop", opts, out:, err:) if remote_requested?(opts)

      agent = load_all_agents.find { |a| a.key == agent_key.to_s }
      return archived_agent_failure(agent_key, err:) if !agent && archived_agent?(agent_key)
      return failure("Unknown agent: #{agent_key}", err: err) unless agent
      return failure("Agent #{agent_key} is not running", err: err) unless agent.running?

      agent = agent_store_for_all.stop_agent!(agent.key)
      print_simple_agent_action("Stopped", agent_cli_payload(agent), json: opts[:json], out: out)
      0
    rescue StandardError => e
      failure("Failed to stop agent: #{e.message}", err: err)
    end

    def agent_logs(agent_key, opts, out: $stdout, err: $stderr)
      agent = load_all_agents.find { |a| a.key == agent_key.to_s } || AgentArchiveStore.new.find(agent_key)&.agent
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

    def send_agent_message(agent_key, message, opts = {}, out: $stdout, err: $stderr)
      opts = opts.merge(actor: delegation_actor(opts[:parent_agent]))
      return remote_send_agent_message(agent_key, message, opts, out:, err:) if remote_requested?(opts)

      store = agent_store_for_all
      agents = store.load
      agent = agents.find { |a| a.key == agent_key.to_s }
      return archived_agent_failure(agent_key, err:) if !agent && archived_agent?(agent_key)
      return failure("Unknown agent: #{agent_key}", err: err) unless agent
      return failure("Agent #{agent_key} is already running", err: err) if agent.running?

      agent = persist_agents_with_parent!(store, agents, agent, opts)
      store.accept_prompt_from!(agent, actor: opts.fetch(:actor), agents: agents)
      agent.add_user_message!(message, metadata: agent.message_author_metadata(opts.fetch(:actor)))
      store.save(agents)
      agent = store.start_agent!(agent.key)
      if agent.running?
        print_sent_agent(agent_cli_payload(agent), json: opts[:json], out: out)
      else
        out.puts "Message saved but agent failed to start"
        return 1
      end
      0
    rescue StandardError => e
      failure("Failed to send message: #{e.message}", err: err)
    end

    def archive_agent(agent_key, opts = {}, out: $stdout, err: $stderr)
      return remote_archive_agent(agent_key, opts, out:, err:) if remote_requested?(opts)

      agents = load_all_agents
      agent = agents.find { |a| a.key == agent_key.to_s }
      return archived_agent_failure(agent_key, err:) if !agent && archived_agent?(agent_key)
      return failure("Unknown agent: #{agent_key}", err: err) unless agent
      return failure("Agent #{agent_key} is running — stop it first", err: err) if agent.running?

      archive_path = agent_store_for_all.archive_agent!(agent.key)
      result = { archived: true, agent_key: agent.key, archive_path: archive_path }.compact
      if opts[:json]
        out.puts JSON.pretty_generate(result)
      else
        out.puts "Archived #{agent.key}"
        out.puts "Archive: #{archive_path}" if archive_path
      end
      0
    rescue StandardError => e
      failure("Failed to archive agent: #{e.message}", err: err)
    end

    def finalize_agent(agent_key, out: $stdout, err: $stderr)
      store = agent_store_for_all
      target = store.mutate do |agents, _events|
        candidate = agents.find { |agent| agent.key == agent_key.to_s }
        candidate&.poll!
        store.delegation_coordinator.process!(agents)
        candidate
      end
      return failure("Unknown agent: #{agent_key}", err:) unless target

      out.puts "Finalized #{target.key}"
      0
    rescue StandardError => e
      failure("Failed to finalize agent: #{e.message}", err:)
    end

    def clone_agent(agent_key, opts, out: $stdout, err: $stderr)
      require_relative "registry"

      registry = Registry.new
      agents = load_all_agents
      source = agents.find { |a| a.key == agent_key.to_s }
      return archived_agent_failure(agent_key, err:) if !source && archived_agent?(agent_key)
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
        clone = store.start_agent!(clone.key)
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

    def remote_requested?(opts)
      !opts[:server].to_s.strip.empty?
    end

    def metric_filters(opts)
      %i[from to timezone group project agent harness model status].each_with_object({}) do |key, result|
        value = opts[key]
        result[key.to_s] = value unless value.to_s.strip.empty?
      end
    end

    def print_metrics(result, json:, out:)
      if json
        out.puts JSON.pretty_generate(result)
        return
      end

      summary = result.fetch("summary")
      rows = [
        ["Run starts", summary.fetch("run_starts").to_s],
        ["Managed agents", summary.fetch("managed_agents").to_s],
        ["Native sessions", summary.fetch("distinct_native_sessions").to_s],
        ["Average runs/session", format_metric_number(summary["average_runs_per_session"])],
        ["Known estimated cost", format_metric_cost(summary["known_estimated_cost_usd"])],
        ["Median priced session", format_metric_cost(summary["median_priced_session_cost_usd"])],
        ["Maximum priced session", format_metric_cost(summary["max_priced_session_cost_usd"])],
        ["Priced / unpriced runs", "#{summary.fetch("priced_run_count")} / #{summary.fetch("unpriced_run_count")}"],
        ["Priced coverage", format_metric_percent(summary["priced_run_coverage"])]
      ]
      out.puts agent_table(%w[Metric Value], rows)
      out.puts "Range: #{result.dig("query", "from") || "unbounded"} <= start < " \
               "#{result.dig("query", "to") || "unbounded"} (#{result.dig("query", "timezone")})"
      out.puts "Costs are estimates, not invoices. Sessions with any unpriced run are excluded from median/max."
    end

    def print_backfill(result, json:, out:)
      if json
        out.puts JSON.pretty_generate(result)
        return
      end

      rows = %w[created updated unchanged manifest_run_count raw_fallback_run_count skipped_run_count].map do |key|
        [key.tr("_", " ").capitalize, result.fetch(key, 0).to_s]
      end
      out.puts agent_table(%w[Backfill Count], rows)
      Array(result["warnings"]).each { |warning| out.puts "Warning: #{warning}" }
    end

    def format_metric_number(value)
      value.nil? ? "unknown" : format("%.2f", value)
    end

    def format_metric_cost(value)
      value.nil? ? "unknown" : format("$%.4f estimated", value)
    end

    def format_metric_percent(value)
      value.nil? ? "unknown" : format("%.1f%%", value * 100)
    end

    def remote_query_metrics(opts, out:, err:)
      query = URI.encode_www_form(metric_filters(opts))
      path = query.empty? ? "/metrics" : "/metrics?#{query}"
      result = remote_client(opts[:server]).request("GET", path)
      print_metrics(result, json: opts[:json], out:)
      0
    rescue RemoteCLIClient::Error, ArgumentError => e
      failure(e.message, err:)
    end

    def remote_backfill_metrics(opts, out:, err:)
      result = remote_client(opts[:server]).request(
        "POST",
        "/metrics/backfill",
        body: { "timezone" => opts[:timezone], "durable_only" => opts[:durable_only] == true }
      )
      print_backfill(result, json: opts[:json], out:)
      0
    rescue RemoteCLIClient::Error, ArgumentError => e
      failure(e.message, err:)
    end

    def remote_client(server_key)
      require_relative "registry"
      require_relative "domain/remote_cli_client"

      RemoteCLIClient.from_registry(server_key, registry: Registry.new)
    end

    def remote_show_project(project_key, opts, out:, err:)
      payload = remote_client(opts[:server]).request("GET", remote_resource_path("projects", project_key)).fetch("project")
      print_project_result(remote_project_detail(payload), json: opts[:json], out: out)
      0
    rescue RemoteCLIClient::Error, KeyError => e
      failure(e.message, err: err)
    end

    def remote_list_projects(opts, out:, err:)
      payload = remote_client(opts[:server]).request("GET", "/projects").fetch("projects").map do |project|
        remote_project_list_item(project)
      end
      print_project_list(payload, json: opts[:json], out: out)
      0
    rescue RemoteCLIClient::Error, KeyError => e
      failure(e.message, err: err)
    end

    def remote_create_agent(project_key, prompt, opts, out:, err:)
      body = {
        "project_key" => project_key.to_s,
        "prompt" => prompt.to_s,
        "start" => opts[:run] == true
      }
      body["parent_agent_key"] = opts[:parent_agent].to_s.strip unless opts[:parent_agent].to_s.strip.empty?
      {
        name: "name",
        template: "template_key",
        harness: "agent",
        model: "model"
      }.each do |option, field|
        value = opts[option].to_s.strip
        body[field] = value unless value.empty?
      end
      payload = remote_client(opts[:server]).request("POST", "/agents", body: body).fetch("agent")
      print_created_agent(remote_agent_payload(payload), json: opts[:json], out: out)
      0
    rescue RemoteCLIClient::Error, KeyError => e
      failure(e.message, err: err)
    end

    def remote_list_agents(project_key, opts, out:, err:)
      client = remote_client(opts[:server])
      agents = opts[:archived] ? [] : client.request("GET", "/agents").fetch("agents")
      if opts[:archived] || opts[:include_archived]
        page = 1
        loop do
          query = URI.encode_www_form({ page: page, per_page: 100 })
          response = client.request("GET", "/agents/archived", query: query)
          agents.concat(response.fetch("agents"))
          page = response.dig("pagination", "next_page")
          break unless page
        end
      end
      agents = agents.select { |agent| agent["project_key"] == project_key.to_s } if project_key
      archive_fields = opts[:archived] || opts[:include_archived]
      agents = agents.map { |agent| remote_agent_payload(agent, archive_fields: archive_fields) }
      if opts[:json]
        out.puts JSON.pretty_generate(agents)
      elsif agents.empty?
        out.puts project_key ? "No agents for project: #{project_key}" : "No agents found."
      else
        rows = agents.map do |agent|
          row = [agent["key"], agent["project_key"], agent["name"],
                 agent.dig("delegation", "parent", "agent_key") || "-", agent["agent"]]
          row << (agent["archived"] ? "archived" : "active") if archive_fields
          row + [agent["status"], agent["run_count"].to_s]
        end
        headers = archive_fields ? %w[Key Project Name Parent Harness State Status Runs] : %w[Key Project Name Parent Harness Status Runs]
        out.puts agent_table(headers, rows)
      end
      0
    rescue RemoteCLIClient::Error, KeyError => e
      failure(e.message, err: err)
    end

    def remote_agent_status(agent_key, opts, out:, err:)
      payload = remote_client(opts[:server]).request("GET", remote_resource_path("agents", agent_key)).fetch("agent")
      payload = remote_agent_payload(payload, archive_fields: payload["archived"] == true)
      print_agent_status(payload, json: opts[:json], out: out)
      0
    rescue RemoteCLIClient::Error, KeyError => e
      failure(e.message, err: err)
    end

    def remote_memory_handoffs(opts, out:, err:)
      payload = remote_client(opts[:server]).request("GET", "/memory-handoffs")
      print_memory_handoffs(payload, json: opts[:json], out:)
      0
    rescue RemoteCLIClient::Error, KeyError => e
      failure(e.message, err: err)
    end

    def remote_agent_action(agent_key, action, opts, out:, err:)
      client = remote_client(opts[:server])
      current = client.request("GET", remote_resource_path("agents", agent_key)).fetch("agent")
      if action == "start" && current["running"]
        return failure("Agent #{agent_key} is already running", err: err)
      end
      if action == "stop" && !current["running"]
        return failure("Agent #{agent_key} is not running", err: err)
      end

      body = {}
      body["parent_agent_key"] = opts[:parent_agent].to_s.strip unless opts[:parent_agent].to_s.strip.empty?
      payload = client
        .request("POST", "#{remote_resource_path("agents", agent_key)}/#{action}", body: body)
        .fetch("agent")
      payload = remote_agent_payload(payload)
      if action == "start"
        print_started_agent(payload, json: opts[:json], out: out)
      else
        print_simple_agent_action("Stopped", payload, json: opts[:json], out: out)
      end
      0
    rescue RemoteCLIClient::Error, KeyError => e
      failure(e.message, err: err)
    end

    def remote_send_agent_message(agent_key, message, opts, out:, err:)
      client = remote_client(opts[:server])
      current = client.request("GET", remote_resource_path("agents", agent_key)).fetch("agent")
      return failure("Agent #{agent_key} is already running", err: err) if current["running"]

      payload = client
        .request(
          "POST",
          "#{remote_resource_path("agents", agent_key)}/messages",
          body: {
            "prompt" => message.to_s,
            "start" => true,
            "parent_agent_key" => opts[:parent_agent].to_s.strip
          }.reject { |_key, value| value.to_s.empty? }
        )
        .fetch("agent")
      payload = remote_agent_payload(payload)
      print_sent_agent(payload, json: opts[:json], out: out)
      0
    rescue RemoteCLIClient::Error, KeyError => e
      failure(e.message, err: err)
    end

    def remote_archive_agent(agent_key, opts, out:, err:)
      payload = remote_client(opts[:server])
        .request("POST", "#{remote_resource_path("agents", agent_key)}/archive")
      payload = {
        "archived" => payload["archived"],
        "agent_key" => payload["agent_key"],
        "archive_path" => payload["archive_path"]
      }.compact
      if opts[:json]
        out.puts JSON.pretty_generate(payload)
      else
        out.puts "Archived #{payload["agent_key"] || agent_key}"
        out.puts "Archive: #{payload["archive_path"]}" unless payload["archive_path"].to_s.empty?
      end
      0
    rescue RemoteCLIClient::Error => e
      failure(e.message, err: err)
    end

    def remote_resource_path(root, key)
      encoded = URI.encode_www_form_component(key.to_s).gsub("+", "%20")
      "/#{root}/#{encoded}"
    end

    def remote_project_detail(payload)
      {
        key: payload["key"],
        name: payload["name"],
        group: payload["group"],
        path: payload["path"],
        harness: payload["agent"],
        model: payload["model"],
        reasoning_effort: payload["reasoning_effort"],
        response_style: nil,
        pr_url: payload["pr_url"],
        hidden: false,
        visibility_source: "remote server",
        git: {
          branch: payload["branch"],
          commit: payload["commit_hash"],
          dirty_files: payload["dirty_files"]
        }
      }
    end

    def remote_project_list_item(payload)
      {
        "key" => payload["key"],
        "name" => payload["name"],
        "group" => payload["group"],
        "path" => payload["path"],
        "status" => payload["status"]
      }
    end

    def remote_agent_payload(payload, archive_fields: false)
      result = {
        "key" => payload["key"],
        "name" => payload["name"],
        "project_key" => payload["project_key"],
        "schedule_key" => payload["schedule_key"],
        "agent" => payload["agent"],
        "model" => payload["model"],
        "status" => payload["status"],
        "running" => payload["running"],
        "pid" => payload["pid"],
        "run_count" => payload["run_count"],
        "started_at" => payload["started_at"],
        "finished_at" => payload["finished_at"],
        "last_exit_code" => payload["last_exit_code"],
        "last_run_at" => payload["started_at"],
        "workspace" => payload["workspace"],
        "log_path" => payload["log_path"],
        "prompt" => payload["prompt"],
        "archived" => payload["archived"] == true,
        "archive_path" => payload["archive_path"],
        "delegation" => payload["delegation"]
      }
      result["archived_at"] = payload["archived_at"] if archive_fields
      result
    end

    def print_project_list(payload, json:, out:)
      return out.puts(JSON.pretty_generate(payload)) if json

      if payload.empty?
        out.puts "No projects found."
        return
      end
      rows = payload.map do |project|
        value = project.transform_keys(&:to_s)
        [value["key"], value["name"], value["group"] || "(none)", value["status"] || "n/a", value["path"]]
      end
      out.puts agent_table(%w[Key Name Group Status Path], rows)
    end

    def agent_cli_payload(agent, delegation: nil, archive_fields: false)
      last = agent.last_run
      result = {
        key: agent.key,
        name: agent.name,
        project_key: agent.project_key,
        schedule_key: agent.schedule_key,
        agent: agent.agent,
        model: agent.model,
        status: agent.status,
        running: agent.running?,
        pid: agent.pid,
        run_count: agent.run_count,
        started_at: agent.started_at&.iso8601,
        finished_at: agent.finished_at&.iso8601,
        last_exit_code: agent.last_exit_code,
        last_run_at: last&.started_at&.iso8601,
        workspace: agent.workspace,
        log_path: agent.raw_log_path,
        prompt: agent.prompt,
        archived: agent.archived?,
        archive_path: agent.archive_path,
        delegation: delegation || agent_cli_delegation(agent)
      }
      result[:archived_at] = agent.archived_at&.iso8601 if archive_fields
      result
    end

    def print_created_agent(payload, json:, out:)
      return out.puts(JSON.pretty_generate(payload)) if json

      value = payload.transform_keys(&:to_s)
      out.puts "Created agent #{value["key"]}"
      out.puts "  Name:    #{value["name"]}"
      out.puts "  Project: #{value["project_key"]}"
      out.puts "  Harness: #{value["agent"]}"
      out.puts "  Model:   #{value["model"] || "(project default)"}"
      out.puts "  Prompt:  #{value["prompt"].to_s.lines.first&.chomp}"
      out.puts "  Started by: #{value.dig("delegation", "parent", "agent_key")}" if value.dig("delegation", "parent")
      if value["running"]
        out.puts "  Status:  running (pid #{value["pid"]})"
        out.puts "  Log:     #{value["log_path"]}"
      end
    end

    def print_agent_status(payload, json:, out:)
      return out.puts(JSON.pretty_generate(payload)) if json

      value = payload.transform_keys(&:to_s)
      rows = [
        ["Key", value["key"]],
        ["Name", value["name"]],
        ["Project", value["project_key"]],
        ["Schedule key", value["schedule_key"] || "n/a"],
        ["Archived", value["archived"] ? "yes" : "no"],
        ["Started by", value.dig("delegation", "parent", "name") ||
          value.dig("delegation", "parent", "agent_key") || "n/a"],
        ["Delegated agents", Array(value.dig("delegation", "children")).map do |child|
          child["name"] || child[:name] || child["agent_key"] || child[:agent_key]
        end.join(", ").then { |names| names.empty? ? "n/a" : names }],
        ["Harness", value["agent"]],
        ["Model", value["model"] || "(project default)"],
        ["Status", value["status"]],
        ["PID", value["pid"] || "n/a"],
        ["Runs", value["run_count"].to_i.to_s],
        ["Started", display_timestamp(value["started_at"])],
        ["Finished", display_timestamp(value["finished_at"])],
        ["Exit code", value["last_exit_code"].nil? ? "n/a" : value["last_exit_code"].to_s],
        ["Last run", display_timestamp(value["last_run_at"] || value["started_at"])],
        ["Workspace", value["workspace"]],
        ["Log", value["log_path"] || "n/a"]
      ]
      rows.insert(5, ["Archived at", display_timestamp(value["archived_at"])]) if value["archived"]
      out.puts detail_table(rows)
    end

    def print_memory_handoffs(payload, json:, out:)
      return out.puts(JSON.pretty_generate(payload)) if json

      value = payload.transform_keys(&:to_s)
      runs = Array(value["runs"])
      out.puts "Server: #{value["server"]}"
      out.puts "No memory handoffs found." if runs.empty?
      return if runs.empty?

      rows = runs.map do |run|
        handoff = run["metadata"] || run[:metadata] || {}
        handoff = handoff["memory_handoff"] || handoff[:memory_handoff] || {}
        [run["run_id"] || run[:run_id], run["finished_at"] || run[:finished_at], run["project"] || run[:project], handoff["outcome"] || handoff[:outcome]]
      end
      out.puts agent_table(%w[Run Finished Project Outcome], rows)
    end

    def print_started_agent(payload, json:, out:)
      return out.puts(JSON.pretty_generate(payload)) if json

      value = payload.transform_keys(&:to_s)
      out.puts "Started #{value["key"]} (pid #{value["pid"]})"
      out.puts "Log: #{value["log_path"]}"
    end

    def print_sent_agent(payload, json:, out:)
      return out.puts(JSON.pretty_generate(payload)) if json

      value = payload.transform_keys(&:to_s)
      out.puts "Message sent and agent started (pid #{value["pid"]})"
      out.puts "Log: #{value["log_path"]}"
    end

    def print_simple_agent_action(action, payload, json:, out:)
      return out.puts(JSON.pretty_generate(payload)) if json

      value = payload.transform_keys(&:to_s)
      out.puts "#{action} #{value["key"]}"
    end

    def display_timestamp(value)
      return "n/a" if value.to_s.empty?

      Time.parse(value.to_s).strftime("%Y-%m-%d %H:%M:%S")
    rescue ArgumentError
      value.to_s
    end

    def detail_table(rows)
      Lipgloss::Table.new
        .rows(rows)
        .border_style(Lipgloss::Style.new.foreground(COLORS[:accent_alt]))
        .style_func(rows: rows.length, columns: 2) { |_row, column|
          column.zero? ? Lipgloss::Style.new.bold(true).foreground(COLORS[:notice]) : Lipgloss::Style.new.foreground(COLORS[:text])
        }
        .render
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

    def persist_agents_with_parent!(store, agents, child, opts, creating: false)
      store.persist_with_delegation!(
        agents:,
        child:,
        parent_key: opts[:parent_agent],
        creating:,
        actor: opts[:actor]
      )
    end

    def delegation_actor(parent_key)
      key = parent_key.to_s.strip
      return DelegationActor.user_actor if key.empty?

      DelegationActor.parent_actor(key)
    end

    def agent_cli_delegation(agent, relationship_context: nil)
      relationship_context ||= agent_cli_relationship_context
      relationships = {
        "parent" => relationship_context.fetch(:parents)[agent.key],
        "children" => relationship_context.fetch(:children).fetch(agent.key, [])
      }
      relation = relationships.fetch("parent")
      {
        parent: relation ? agent_cli_delegation_reference(relation, "parent") : nil,
        children: relationships.fetch("children").map do |child_relation|
          agent_cli_delegation_reference(child_relation, "child")
        end
      }
    end

    def agent_cli_delegation_reference(relation, side)
      relation.fetch(side).merge(
        "relationship_id" => relation.fetch("id"),
        "connected" => relation["connected"] != false,
        "owner" => relation.fetch("owner", "parent"),
        "ownership_generation" => relation.fetch("ownership_generation", 1),
        "ownership_changed_at" => relation["ownership_changed_at"],
        "connection_changed_at" => relation["connection_changed_at"]
      ).compact
    end

    def agent_cli_relationship_context
      agent_store_for_all.delegation_coordinator.relationship_index
    end

    def archived_agent?(agent_key)
      !AgentArchiveStore.new.find(agent_key).nil?
    end

    def archived_agent_failure(agent_key, err:)
      failure("Archived agent is read-only: #{agent_key}", err: err)
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

    def usage(error = nil, err: $stderr)
      err.puts error if error
      err.puts USAGE
      error ? 64 : 0
    end

    def failure(message, err: $stderr)
      err.puts message
      1
    end
  end
end
