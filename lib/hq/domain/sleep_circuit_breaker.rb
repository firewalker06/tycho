# frozen_string_literal: true

require "json"
require "securerandom"
require "time"

require_relative "shell_command_classifier"

module HQ
  class SleepCircuitBreaker
    THRESHOLD = 3
    SUPPORTED_ADAPTERS = %w[codex claude pi].freeze
    SHELL_TOOLS = %w[bash shell sh zsh exec command_execution].freeze
    BLOCKING_COMMANDS = %w[sleep usleep wait].freeze

    Invocation = Struct.new(:call_id, :tool_name, :command, :adapter, keyword_init: true)

    def initialize(agent_type:, threshold: THRESHOLD, clock: -> { Time.now })
      @adapter = HQ.harness_adapter(agent_type)
      @threshold = Integer(threshold)
      @clock = clock
      @seen_call_ids = {}
      @blocking_calls = []
      @shell_classifier = ShellCommandClassifier.new(blocking_commands: BLOCKING_COMMANDS)
    end

    def observe(line)
      invocations(line).each do |invocation|
        next if @seen_call_ids[invocation.call_id]

        @seen_call_ids[invocation.call_id] = true
        next unless blocking_wait?(invocation)

        @blocking_calls << invocation
        return incident(invocation) if @blocking_calls.length >= @threshold
      end
      nil
    end

    def supported?
      SUPPORTED_ADAPTERS.include?(@adapter)
    end

    private

    def invocations(line)
      return [] unless supported?

      event = JSON.parse(line.to_s)
      case @adapter
      when "codex" then codex_invocations(event)
      when "claude" then claude_invocations(event)
      when "pi" then pi_invocations(event)
      else []
      end
    rescue JSON::ParserError
      []
    end

    def codex_invocations(event)
      item = event["item"]
      return [] unless event["type"] == "item.started" && item.is_a?(Hash) &&
                       item["type"] == "command_execution"

      [Invocation.new(
        call_id: item["id"].to_s,
        tool_name: "command_execution",
        command: item["command"].to_s,
        adapter: @adapter
      )]
    end

    def claude_invocations(event)
      return [] unless event["type"] == "assistant"

      Array(event.dig("message", "content")).filter_map do |item|
        next unless item.is_a?(Hash) && item["type"] == "tool_use"

        Invocation.new(
          call_id: item["id"].to_s,
          tool_name: item["name"].to_s,
          command: command_from_arguments(item["input"]),
          adapter: @adapter
        )
      end
    end

    def pi_invocations(event)
      return [] unless event["type"] == "tool_execution_start"

      [Invocation.new(
        call_id: event["toolCallId"].to_s,
        tool_name: event["toolName"].to_s,
        command: command_from_arguments(event["args"]),
        adapter: @adapter
      )]
    end

    def command_from_arguments(arguments)
      return "" unless arguments.is_a?(Hash)

      arguments["command"].to_s
    end

    def blocking_wait?(invocation)
      return false if invocation.call_id.empty?
      return false unless SHELL_TOOLS.include?(invocation.tool_name.to_s.downcase)

      @shell_classifier.blocking_wait?(invocation.command)
    end

    def incident(invocation)
      now = @clock.call
      {
        "id" => SecureRandom.uuid,
        "reason" => "sleep_circuit_breaker",
        "observed_at" => now.utc.iso8601(6),
        "threshold" => @threshold,
        "blocking_call_count" => @blocking_calls.length,
        "trigger_call_id" => invocation.call_id,
        "adapter" => invocation.adapter
      }
    end
  end
end
