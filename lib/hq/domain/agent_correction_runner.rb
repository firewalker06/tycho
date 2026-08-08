# frozen_string_literal: true

require "fileutils"
require "json"
require "open3"
require_relative "agent_structured_result"
require_relative "agent_structured_output_validator"

module HQ
  class AgentCorrectionRunner
    SESSION_PLACEHOLDER = "__TYCHO_SESSION_ID__"
    PROMPT_PLACEHOLDER = "__TYCHO_CORRECTION_PROMPT__"
    VALIDATION_FAILURE_EXIT_CODE = 65

    def self.run_from_environment!
      config = JSON.parse(ENV.fetch("TYCHO_AGENT_RUNNER_CONFIG"))
      exit(new(config).run)
    rescue StandardError => e
      warn "Tycho agent runner failed: #{e.class}: #{e.message}"
      exit 1
    end

    def initialize(config, output: $stdout)
      @config = config
      @output = output
      schema = JSON.parse(File.read(config.fetch("schema_path")))
      @validator = AgentStructuredOutputValidator.new(schema:)
    end

    def run
      command = @config.fetch("initial_command")
      correction_limit = Integer(@config.fetch("correction_limit"))
      session_id = @config["session_id"].to_s

      (0..correction_limit).each do |attempt|
        lines, exit_code = execute(command)
        return exit_code unless exit_code.zero?

        session_id = discover_session_id(lines) if session_id.empty?
        candidate = candidate_for(lines)
        validation = @validator.validate(candidate)
        return 0 if validation.valid?

        emit_validation_event(validation.errors, attempt:, correction_limit:)
        if attempt >= correction_limit || session_id.empty?
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
      end
    end

    private

    def execute(command)
      FileUtils.rm_f(@config["last_message_path"]) unless @config["last_message_path"].to_s.empty?
      lines = []
      status = nil
      Open3.popen2e(*command) do |_stdin, stream, wait_thread|
        stream.each_line do |line|
          lines << line.chomp
          @output.write(line)
          @output.flush
        end
        status = wait_thread.value
      end
      [lines, status.exitstatus || 1]
    rescue SystemCallError => e
      warn e.message
      [lines, 127]
    end

    def candidate_for(lines)
      if @config.fetch("harness_adapter") == "codex"
        path = @config["last_message_path"].to_s
        return File.read(path) if !path.empty? && File.file?(path)
      end
      AgentStructuredResult.candidate_from_log_lines(lines)
    rescue StandardError
      nil
    end

    def discover_session_id(lines)
      Array(lines).each do |line|
        parsed = JSON.parse(line)
        id = if @config.fetch("harness_adapter") == "codex"
               parsed["thread_id"] || parsed["session_id"]
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
      @config.fetch("correction_command").map do |argument|
        argument.to_s
                .gsub(SESSION_PLACEHOLDER, session_id)
                .gsub(PROMPT_PLACEHOLDER, JSON.generate(feedback))
      end
    end

    def emit_validation_event(errors, attempt:, correction_limit:)
      emit(
        "type" => "tycho.structured_output.validation_failed",
        "correction_attempt" => attempt,
        "correction_limit" => correction_limit,
        "errors" => errors
      )
    end

    def preserve_invalid_response(raw_text)
      path = @config.fetch("invalid_response_path")
      FileUtils.mkdir_p(File.dirname(path))
      File.open(path, File::WRONLY | File::CREAT | File::TRUNC, 0o600) do |file|
        file.write(raw_text.to_s)
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
      @output.puts(JSON.generate(event))
      @output.flush
    end
  end
end
