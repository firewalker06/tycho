# frozen_string_literal: true

require "time"

require_relative "command_runner"
require_relative "harness_catalog"
require_relative "harness_execution"

module HQ
  class HarnessAuthCheck
    Result = Struct.new(:state, :detail, :checked_at, keyword_init: true) do
      def to_h
        { state:, detail:, checked_at: checked_at.utc.iso8601 }
      end
    end

    TIMEOUT = 8
    STATES = %w[authenticated unauthenticated unknown].freeze

    def initialize(runner: CommandRunner, clock: -> { Time.now })
      @runner = runner
      @clock = clock
    end

    def check(adapter:, command:, environment: {})
      command = Array(command).map(&:to_s).reject(&:empty?)
      return result("unknown", "Authentication check unavailable: no executable command") if command.empty?

      case adapter.to_s
      when "codex", "claude"
        status_check(command, environment:)
      when "opencode"
        opencode_check(command, environment:)
      when "pi"
        pi_check(command, environment:)
      else
        result("unknown", "Authentication check unavailable for this adapter")
      end
    rescue SystemCallError
      result("unknown", "Authentication check could not start")
    end

    private

    def status_check(command, environment:)
      capture = run(command + %w[auth status], environment:)
      return unavailable_result if capture.timed_out?
      return result("authenticated", "Authentication check succeeded") if capture.success?

      text = "#{capture.stdout}\n#{capture.stderr}".downcase
      return unavailable_result if text.match?(/unknown command|unrecognized command|invalid command|not found/)

      result("unauthenticated", "Authentication check reported no active account")
    end

    def opencode_check(command, environment:)
      capture = run(command + %w[auth list], environment:)
      return unavailable_result if capture.timed_out?
      return result("unauthenticated", "Authentication check could not read provider status") unless capture.success?

      providers = HarnessCatalog.opencode_auth_providers_from_output(capture.stdout)
      providers.empty? ? result("unauthenticated", "No authenticated providers found") :
        result("authenticated", "Authenticated providers found")
    end

    def pi_check(command, environment:)
      capture = run(command + ["--list-models"], environment:)
      return unavailable_result if capture.timed_out?
      return result("unauthenticated", "Authentication check could not list models") unless capture.success?

      rows = HarnessCatalog.pi_model_rows_from_output(capture.stdout)
      rows.empty? ? result("unauthenticated", "No authenticated providers found") :
        result("authenticated", "Authenticated providers found")
    end

    def run(command, environment:)
      @runner.capture(command, timeout: TIMEOUT, environment: HarnessExecution.command_environment(environment))
    end

    def unavailable_result
      result("unknown", "Authentication check is unavailable for this harness")
    end

    def result(state, detail)
      Result.new(state:, detail:, checked_at: @clock.call)
    end
  end
end
