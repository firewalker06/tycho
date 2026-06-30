# frozen_string_literal: true

module HQ
  class AgentCommandBuilder
    def initialize(agent:, harness_adapter:, workspace:, sandbox_mode:, model:, reasoning_effort:,
                   session_id:, session_bootstrapped:, prompt:, codex_executable:, claude_command_prefix:,
                   opencode_executable:, last_message_file_path:, result_schema_path:, claude_result_schema:)
      @agent = agent
      @harness_adapter = harness_adapter
      @workspace = workspace
      @sandbox_mode = sandbox_mode
      @model = model
      @reasoning_effort = reasoning_effort
      @session_id = session_id.to_s
      @session_bootstrapped = session_bootstrapped
      @prompt = prompt
      @codex_executable = codex_executable
      @claude_command_prefix = claude_command_prefix
      @opencode_executable = opencode_executable
      @last_message_file_path = last_message_file_path
      @result_schema_path = result_schema_path
      @claude_result_schema = claude_result_schema
    end

    def build
      return build_claude_command if claude_like_agent?
      return build_codex_command if codex_agent?
      return build_opencode_command if opencode_agent?

      raise "Unsupported managed-agent harness #{@agent.inspect}"
    end

    def interactive
      return build_interactive_claude_like_command(command_prefix: @claude_command_prefix) if claude_like_agent?
      return build_interactive_codex_command if codex_agent?
      return build_interactive_opencode_command if opencode_agent?

      raise "Unsupported managed-agent harness #{@agent.inspect}"
    end

    def claude_session_arguments
      if @session_id.empty?
        []
      elsif @session_bootstrapped
        ["--resume", @session_id]
      else
        ["--session-id", @session_id]
      end
    end

    private

    def build_codex_command
      command = [@codex_executable, "exec"]
      command << "resume" unless @session_id.empty?
      command.concat(model_arguments)
      command.concat(codex_reasoning_effort_arguments)
      if @sandbox_mode == "danger-full-access"
        command << "--dangerously-bypass-approvals-and-sandbox"
      else
        command << "--full-auto"
        command.concat(["--sandbox", @sandbox_mode]) if @session_id.empty?
      end
      command << "--json"
      if @session_id.empty? && File.exist?(@result_schema_path)
        command.concat(["--output-schema", @result_schema_path, "-o", @last_message_file_path])
      else
        command.concat(["-o", @last_message_file_path])
      end
      command << "--skip-git-repo-check"
      command.concat(["-C", @workspace]) if @session_id.empty?
      command << @session_id unless @session_id.empty?
      command << "--"
      command << @prompt
      { command: command }
    end

    def build_claude_command
      build_claude_like_command(command_prefix: @claude_command_prefix)
    end

    def build_opencode_command
      command = [@opencode_executable, "run", "--format", "json", "--dir", @workspace]
      command.concat(model_arguments)
      command.concat(opencode_variant_arguments)
      command << "--dangerously-skip-permissions" if @sandbox_mode == "danger-full-access"
      command.concat(["--session", @session_id]) unless @session_id.empty?
      command << @prompt
      { command: command }
    end

    def build_interactive_codex_command
      command = [@codex_executable]
      command.concat(model_arguments)
      command.concat(codex_reasoning_effort_arguments)
      if @sandbox_mode == "danger-full-access"
        command << "--dangerously-bypass-approvals-and-sandbox"
      else
        command << "--full-auto"
        command.concat(["--sandbox", @sandbox_mode])
      end
      command.concat(["-C", @workspace])
      if @session_id.empty?
        { command: command }
      else
        { command: command + ["resume", @session_id] }
      end
    end

    def build_interactive_claude_like_command(command_prefix:, env: {})
      command = command_prefix.dup
      command.concat(model_arguments)
      command.concat(claude_effort_arguments)
      command << "--dangerously-skip-permissions" if @sandbox_mode == "danger-full-access"
      command.concat(["--resume", @session_id]) unless @session_id.empty?
      { command: command, env: env }
    end

    def build_interactive_opencode_command
      command = [@opencode_executable, "run", "--interactive", "--dir", @workspace]
      command.concat(model_arguments)
      command.concat(opencode_variant_arguments)
      command << "--dangerously-skip-permissions" if @sandbox_mode == "danger-full-access"
      command.concat(["--session", @session_id]) unless @session_id.empty?
      { command: command }
    end

    def build_claude_like_command(command_prefix:, env: {})
      command = command_prefix.dup
      command.concat(model_arguments)
      command.concat(claude_effort_arguments)
      command << "--dangerously-skip-permissions" if @sandbox_mode == "danger-full-access"
      command.concat(["--print", "--output-format", "stream-json", "--verbose"])
      command.concat(claude_session_arguments)
      command.concat(["--json-schema", @claude_result_schema]) if @claude_result_schema
      command << @prompt
      { command: command, env: env }
    end

    def model_arguments
      @model.to_s.empty? ? [] : ["--model", @model]
    end

    def codex_reasoning_effort_arguments
      @reasoning_effort.to_s.empty? ? [] : ["-c", "model_reasoning_effort=\"#{@reasoning_effort}\""]
    end

    def claude_effort_arguments
      @reasoning_effort.to_s.empty? ? [] : ["--effort", @reasoning_effort]
    end

    def opencode_variant_arguments
      @reasoning_effort.to_s.empty? ? [] : ["--variant", @reasoning_effort]
    end

    def claude_like_agent?
      @harness_adapter == "claude"
    end

    def codex_agent?
      @harness_adapter == "codex"
    end

    def opencode_agent?
      @harness_adapter == "opencode"
    end
  end
end
