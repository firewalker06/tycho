# frozen_string_literal: true

require "json"
require "securerandom"
require "shellwords"
require "time"

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

      shell_segments(invocation.command).any? do |segment|
        executable = unwrap_shell(segment).first.to_s
        BLOCKING_COMMANDS.include?(File.basename(executable).downcase) ||
          executable.casecmp("Start-Sleep").zero?
      end
    end

    def shell_segments(command)
      tokens = Shellwords.split(command.to_s)
      tokens = unwrap_shell(tokens)
      tokens.slice_before { |token| %w[&& || ;].include?(token) }.map do |segment|
        %w[&& || ;].include?(segment.first) ? segment.drop(1) : segment
      end.reject(&:empty?)
    rescue ArgumentError
      []
    end

    def unwrap_shell(tokens)
      result = Array(tokens).dup
      loop do
        executable = File.basename(result.first.to_s).downcase
        if executable == "env"
          result.shift
          result.shift while result.first.to_s.include?("=")
          next
        end
        break unless %w[sh bash zsh dash ksh].include?(executable)

        command_index = result.index { |token| token == "-c" || token.match?(/\A-[a-z]*c[a-z]*\z/i) }
        break unless command_index && result[command_index + 1]

        result = Shellwords.split(result[command_index + 1])
      end
      result
    rescue ArgumentError
      []
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
