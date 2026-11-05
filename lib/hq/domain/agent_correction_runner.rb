# frozen_string_literal: true

require "fileutils"
require "json"
require_relative "agent_prompt_transport"
require_relative "agent_structured_result"
require_relative "agent_structured_output_validator"

module HQ
  class AgentCorrectionRunner
    SESSION_PLACEHOLDER = "__TYCHO_SESSION_ID__"
    PROMPT_PLACEHOLDER = "__TYCHO_CORRECTION_PROMPT__"
    VALIDATION_FAILURE_EXIT_CODE = 65

    def self.run_from_stdin!
      config = JSON.parse(STDIN.binmode.read.force_encoding(Encoding::UTF_8))
      exit(new(config).run)
    rescue StandardError => e
      warn "Tycho agent runner failed: #{e.class}: #{e.message}"
      exit 1
    end

    def initialize(config, output: $stdout)
      @config = config
      @output = output
      @output.binmode
      schema = JSON.parse(File.binread(config.fetch("schema_path")).force_encoding(Encoding::UTF_8))
      @validator = AgentStructuredOutputValidator.new(schema:)
    end

    def run
      command = @config.fetch("initial_command")
      input = @config["initial_stdin"]
      correction_limit = Integer(@config.fetch("correction_limit"))
      session_id = @config["session_id"].to_s

      (0..correction_limit).each do |attempt|
        lines, exit_code = execute(command, input)
        return exit_code unless exit_code.zero?

        session_id = discover_session_id(lines) if session_id.empty?
        candidate = candidate_for(lines)
        validation = @validator.validate(candidate)
        return 0 if validation.valid?

        will_retry = attempt < correction_limit && !session_id.empty?
        emit_validation_event(validation.errors, attempt:, correction_limit:, will_retry:)
        unless will_retry
          errors = validation.errors.dup
          if session_id.empty? && attempt < correction_limit
            errors << {
              "code" => "session_unavailable",
              "path" => "$",
              "message" => "Native session ID was not available for correction"
            }
          end
          preserve_invalid_response(validation.raw_text)
          emit_exhausted_result(errors, correction_limit:)
          return VALIDATION_FAILURE_EXIT_CODE
        end

        command = correction_command(session_id, validation.errors, attempt:, correction_limit:)
        input = @correction_input
      end
    end

    private

    def execute(command, input = nil)
      FileUtils.rm_f(@config["last_message_path"]) unless @config["last_message_path"].to_s.empty?
      lines = []
      status = nil
      stream, child_output = IO.pipe
      stream.binmode
      prompt_input = AgentPromptTransport.input(input)
      pid = Process.spawn(*command, in: prompt_input || File::NULL, out: child_output, err: [:child, :out])
      prompt_input&.close
      acknowledge_native_start!(pid)
      child_output.close
      stream.each_line do |line|
        lines << line.dup.force_encoding(Encoding::UTF_8).chomp
        @output.write(line.b)
        @output.flush
      end
      _waited_pid, status = Process.wait2(pid)
      [lines, status.exitstatus || 1]
    rescue SystemCallError => e
      warn e.message
      [lines, 127]
    ensure
      prompt_input&.close unless prompt_input&.closed?
      stream&.close unless stream&.closed?
      child_output&.close unless child_output&.closed?
      begin
        Process.wait(pid) if pid && !status
      rescue Errno::ECHILD
        nil
      end
    end

    def acknowledge_native_start!(pid)
      path = ENV["TYCHO_NATIVE_STARTED_PATH"].to_s
      return if path.empty? || File.exist?(path)

      FileUtils.mkdir_p(File.dirname(path))
      temporary = "#{path}.tmp-#{Process.pid}"
      File.write(temporary, pid.to_s)
      File.rename(temporary, path)
    ensure
      FileUtils.rm_f(temporary) if defined?(temporary) && temporary
    end

    def candidate_for(lines)
      if @config.fetch("harness_adapter") == "codex"
        path = @config["last_message_path"].to_s
        return File.binread(path).force_encoding(Encoding::UTF_8) if !path.empty? && File.file?(path)
      end
      AgentStructuredResult.candidate_from_log_lines(lines)
    rescue StandardError
      nil
    end

    def discover_session_id(lines)
      adapter = @config.fetch("harness_adapter")
      Array(lines).each do |line|
        parsed = JSON.parse(line)
        id = if adapter == "codex"
               parsed["thread_id"] || parsed["session_id"]
             elsif adapter == "opencode"
               parsed["sessionID"] || parsed.dig("part", "sessionID")
             elsif adapter == "pi"
               parsed["id"] if parsed["type"] == "session"
             elsif adapter == "agy"
               AgentStructuredResult.agy_conversation_id(parsed)
             else
               parsed["session_id"] || parsed.dig("session", "id")
             end
        return id.to_s unless id.to_s.empty?
      rescue JSON::ParserError
        next
      end
      ""
    end

    def correction_command(session_id, errors, attempt:, correction_limit:)
      feedback = {
        "type" => "structured_output_validation_error",
        "correction_attempt" => attempt + 1,
        "correction_limit" => correction_limit,
        "errors" => errors,
        "instruction" => "Return one complete corrected JSON payload matching the configured schema. Include every required field."
      }
      @correction_input = @config["prompt_transport"] == "stdin" ? JSON.generate(feedback).encode(Encoding::UTF_8) : nil
      @config.fetch("correction_command").map do |argument|
        argument.to_s
                .gsub(SESSION_PLACEHOLDER, session_id)
                .gsub(PROMPT_PLACEHOLDER, JSON.generate(feedback).encode(Encoding::UTF_8))
      end
    end

    def emit_validation_event(errors, attempt:, correction_limit:, will_retry:)
      emit(
        "type" => "tycho.structured_output.validation_failed",
        "response_attempt" => attempt + 1,
        "next_correction_attempt" => will_retry ? attempt + 1 : nil,
        "correction_limit" => correction_limit,
        "will_retry" => will_retry,
        "errors" => errors
      )
    end

    def preserve_invalid_response(raw_text)
      path = @config.fetch("invalid_response_path")
      FileUtils.mkdir_p(File.dirname(path))
      File.open(path, File::WRONLY | File::CREAT | File::TRUNC, 0o600) do |file|
        file.binmode
        file.write(raw_text.to_s.b)
      end
      File.chmod(0o600, path)
    end

    def emit_exhausted_result(errors, correction_limit:)
      diagnostic_path = @config.fetch("invalid_response_path")
      summary = "Structured output validation failed after #{correction_limit} correction " \
                "#{correction_limit == 1 ? 'attempt' : 'attempts'}. " \
                "Inspect #{diagnostic_path} and the validation events in the system log, then rerun the agent."
      structured_output = {
        "status" => "failed",
        "summary" => summary,
        "inquiry" => nil,
        "attachments" => nil
      }
      emit(
        "type" => "tycho.structured_output.validation_exhausted",
        "errors" => errors,
        "diagnostic_path" => diagnostic_path,
        "structured_output" => structured_output
      )
    end

    def emit(event)
      @output.write(JSON.generate(event).encode(Encoding::UTF_8).b + "\n".b)
      @output.flush
    end
  end
end
