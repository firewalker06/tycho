# frozen_string_literal: true

require "json"
require "open3"
require "rbconfig"

require "dry/cli"
require "lipgloss"

require_relative "domain/project"
require_relative "domain/file_store"
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
        option :model, desc: "Model override (e.g. claude-opus-4-8)"
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
    end

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
    DEBUG_COMMANDS = [
      Commands::DebugClaude
    ].freeze
    COMMAND_NAME = "tycho"
    RUNTIME_COMMANDS = [
      "  #{COMMAND_NAME} serve [daemon] [--host 127.0.0.1] [--port 7373]",
      "  #{COMMAND_NAME} schedule daemon [--once] [--dry-run] [--interval SECONDS]",
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
      *DEBUG_COMMANDS.map { |command| "  #{COMMAND_NAME} #{command.usage_template}" },
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

      started = agent.start!
      save_agent_in_store(agent)

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
