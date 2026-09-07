# frozen_string_literal: true

require "json"
require_relative "../harness_registry"
require_relative "../utf8_text"
require_relative "command_runner"
require_relative "executable_resolver"
require_relative "harness_execution"

module HQ
  module HarnessCatalog
    REASONING_EFFORT_ORDER = %w[minimal low medium high xhigh max].freeze
    CLAUDE_MODEL_SUGGESTIONS = %w[
      claude-fable-5
      claude-opus-5
      claude-opus-4-8
      claude-sonnet-5
      claude-haiku-4-5
    ].freeze
    CLAUDE_REASONING_EFFORTS = %w[low medium high xhigh max].freeze
    COMMAND_TIMEOUT = 2
    OPENCODE_COMMAND_TIMEOUT = 6
    PI_COMMAND_TIMEOUT = 6
    PI_REASONING_EFFORTS = %w[off minimal low medium high xhigh].freeze

    module_function

    def for_builtin(name, resolution)
      cache_key = ["builtin", name.to_s, resolution&.command.to_s, resolution&.path.to_s]
      catalog_cache[cache_key] ||= build_builtin_catalog(
        name,
        resolution,
        command_prefix: resolution ? [resolution.command] : [],
        environment: HarnessExecution.environment
      )
    end

    def for_custom(config, execution: nil, resolution: nil)
      execution ||= config.resolved_execution
      command_prefix = execution.fetch(:command)
      resolution ||= custom_resolution(command_prefix)
      environment = HarnessExecution.environment(execution.fetch(:env))
      cache_key = [
        "custom", config.key.to_s, config.adapter.to_s, command_prefix, execution.fetch(:env),
        resolution&.command.to_s, resolution&.path.to_s
      ]
      catalog_cache[cache_key] ||= build_custom_catalog(
        config,
        resolution,
        command_prefix:,
        environment:
      )
    end

    def build_builtin_catalog(name, resolution, command_prefix:, environment: {})
      case name.to_s
      when "codex"
        codex_catalog(resolution, command_prefix:, environment:)
      when "claude"
        claude_catalog(resolution, command_prefix:, environment:)
      when "opencode"
        opencode_catalog(resolution, command_prefix:, environment:)
      when "pi"
        pi_catalog(resolution, command_prefix:, environment:)
      else
        empty_catalog
      end
    end

    def build_custom_catalog(config, resolution, command_prefix:, environment: {})
      case config.adapter.to_s
      when "codex"
        codex_catalog(resolution, command_prefix:, environment:)
      when "claude"
        claude_compatible_catalog(source: "claude-compatible defaults")
      when "opencode"
        opencode_catalog(resolution, command_prefix:, environment:)
      when "pi"
        pi_catalog(resolution, command_prefix:, environment:)
      else
        empty_catalog
      end
    end

    def catalog_cache
      @catalog_cache ||= {}
    end

    def clear_cache!
      catalog_cache.clear
    end

    def codex_catalog(resolution, command_prefix: nil, environment: {})
      unless resolution&.available?
        return {
          model_suggestions: [],
          reasoning_effort_suggestions: REASONING_EFFORT_ORDER - ["max"],
          catalog_source: "codex defaults"
        }
      end

      command_prefix ||= [resolution.command]
      data = capture_json(command_prefix + %w[debug models], environment:) ||
             capture_json(command_prefix + %w[debug models --bundled], environment:)
      return empty_catalog.merge(catalog_source: "codex debug models unavailable") unless data

      model_rows = if data.is_a?(Hash)
                     Array(data["models"] || data[:models] || data.values.find { |value| value.is_a?(Array) })
                   else
                     Array(data)
                   end.select { |item| item.is_a?(Hash) }
      suggestions = model_rows.filter_map do |item|
        slug = item["slug"].to_s.strip
        next if slug.empty?
        next if item["visibility"].to_s == "hide"

        efforts = Array(item["supported_reasoning_levels"]).filter_map do |level|
          level.is_a?(Hash) ? level["effort"].to_s.strip : nil
        end.reject(&:empty?)

        {
          value: slug,
          label: item["display_name"].to_s.empty? ? slug : item["display_name"].to_s,
          default_reasoning_effort: empty_to_nil(item["default_reasoning_level"]),
          reasoning_efforts: sort_efforts(efforts)
        }
      end

      {
        model_suggestions: suggestions,
        reasoning_effort_suggestions: sort_efforts(suggestions.flat_map { |item| item[:reasoning_efforts] }),
        catalog_source: "codex debug models"
      }
    end

    def claude_catalog(resolution, command_prefix: nil, environment: {})
      command_prefix ||= resolution ? [resolution.command] : []
      efforts = resolution&.available? ? claude_help_efforts(command_prefix, environment:) : []
      claude_compatible_catalog(
        reasoning_efforts: efforts.empty? ? CLAUDE_REASONING_EFFORTS : efforts,
        source: efforts.empty? ? "claude defaults" : "claude --help"
      )
    end

    def claude_compatible_catalog(reasoning_efforts: CLAUDE_REASONING_EFFORTS, source:)
      {
        model_suggestions: CLAUDE_MODEL_SUGGESTIONS.map { |model| { value: model, label: model } },
        reasoning_effort_suggestions: reasoning_efforts,
        catalog_source: source
      }
    end

    def opencode_catalog(resolution, command_prefix: nil, environment: {})
      unless resolution&.available?
        return {
          model_suggestions: [],
          reasoning_effort_suggestions: REASONING_EFFORT_ORDER,
          catalog_source: "opencode defaults",
          auth_providers: []
        }
      end

      command_prefix ||= [resolution.command]
      model_rows = opencode_model_rows(command_prefix, environment:)
      source = model_rows.empty? ? "opencode models unavailable" : "opencode models"
      {
        model_suggestions: model_rows,
        reasoning_effort_suggestions: REASONING_EFFORT_ORDER,
        catalog_source: source,
        auth_providers: opencode_auth_providers(command_prefix, environment:)
      }
    end

    def pi_catalog(resolution, command_prefix: nil, environment: {})
      base = {
        reasoning_effort_suggestions: PI_REASONING_EFFORTS,
        auth_ready: false,
        auth_providers: [],
        capabilities: [
          "JSON event streaming",
          "native session resume",
          "model and thinking selection",
          "Agent Skills discovery"
        ],
        safety_gaps: [
          "Pi has tool allowlists but no sandbox equivalent to Tycho workspace-write or read-only modes",
          "Pi has no native JSON Schema output flag; Tycho validates and corrects the final response"
        ]
      }
      return base.merge(model_suggestions: [], catalog_source: "pi defaults") unless resolution&.available?

      command_prefix ||= [resolution.command]
      rows = pi_model_rows(command_prefix, environment:)
      base.merge(
        model_suggestions: rows,
        catalog_source: rows.empty? ? "pi --list-models unavailable or unauthenticated" : "pi --list-models",
        auth_ready: !rows.empty?,
        auth_providers: rows.filter_map { |item| item[:provider] }.uniq,
        version: pi_version(command_prefix, environment:)
      )
    end

    def claude_help_efforts(command_prefix, environment: {})
      out, err, success = capture_command_output(Array(command_prefix) + ["--help"], environment:)
      return [] unless success

      text = "#{out}\n#{err}"
      match = text.match(/--effort\s+<[^>]+>.*?\(([^)]+)\)/m)
      return [] unless match

      match[1].split(/,\s*/).map { |value| value.strip.downcase }.reject(&:empty?)
    rescue StandardError
      []
    end

    def capture_json(command, environment: {})
      out, _err, success = capture_command_output(command, environment:)
      return nil unless success

      JSON.parse(Utf8Text.normalize(out, replacement: "?"))
    rescue StandardError
      nil
    end

    def opencode_model_rows(command_prefix, environment: {})
      out = capture_stdout(Array(command_prefix) + ["models"], timeout: OPENCODE_COMMAND_TIMEOUT, environment:)
      return [] if out.to_s.empty?

      out.lines.filter_map do |line|
        text = strip_terminal_control(line).strip
        next if text.empty? || text.start_with?("Provider", "MODEL", "─", "-")

        value = text.split(/\s+/).find { |part| part.include?("/") }
        value ||= text.split(/\s+/).first
        next if value.to_s.empty? || value == "ID"

        { value: value, label: value }
      end.uniq { |item| item[:value] }
    end

    def opencode_auth_providers(command_prefix, environment: {})
      out = capture_stdout(Array(command_prefix) + %w[auth list], timeout: OPENCODE_COMMAND_TIMEOUT, environment:)
      return [] if out.to_s.empty?

      out.lines.filter_map do |line|
        text = strip_terminal_control(line).strip
        text = text.sub(/\A[●○◐◯]\s*/, "")
        next if text.empty? || text.start_with?("┌", "│", "└", "─", "-") || text.match?(/\A(provider|name)\b/i)

        text.split(/\s+/).first&.downcase
      end.uniq
    end

    def pi_model_rows(command_prefix, environment: {})
      out = capture_stdout(Array(command_prefix) + ["--list-models"], timeout: PI_COMMAND_TIMEOUT, environment:)
      return [] if out.to_s.empty?

      out.lines.filter_map do |line|
        text = strip_terminal_control(line).strip
        next if text.empty? || text.match?(/\Aprovider\s+model\b/i) || text.match?(/\A[-─\s]+\z/)
        next if text.match?(/\A(?:no models?|authentication|authenticate|error)\b/i)

        provider, model = text.split(/\s+/, 3)
        next if provider.to_s.empty? || model.to_s.empty?

        value = "#{provider}/#{model}"
        { value: value, label: value, provider: provider }
      end.uniq { |item| item[:value] }
    end

    def pi_version(command_prefix, environment: {})
      output = capture_stdout(Array(command_prefix) + ["--version"], timeout: COMMAND_TIMEOUT, environment:).strip
      output.empty? ? nil : output.lines.first.strip
    end

    def capture_stdout(command, timeout: COMMAND_TIMEOUT, environment: {})
      out, _err, success = capture_command_output(command, timeout:, environment:)
      success ? Utf8Text.normalize(out, replacement: "?") : ""
    rescue StandardError
      ""
    end

    def capture_command_output(command, timeout: COMMAND_TIMEOUT, environment: {})
      result = CommandRunner.capture(command, timeout:, environment:)
      [result.stdout, result.stderr, result.success?]
    end

    def custom_resolution(command_prefix)
      command = Array(command_prefix).first.to_s
      command.empty? ? nil : ExecutableResolver.resolve(command)
    end

    def strip_terminal_control(text)
      text.to_s.gsub(/\e\[[0-9;?]*[ -\/]*[@-~]/, "")
    end

    def sort_efforts(values)
      values = Array(values).map { |value| value.to_s.strip.downcase }.reject(&:empty?).uniq
      values.sort_by { |value| [REASONING_EFFORT_ORDER.index(value) || 99, value] }
    end

    def empty_catalog
      {
        model_suggestions: [],
        reasoning_effort_suggestions: [],
        catalog_source: nil
      }
    end

    def empty_to_nil(value)
      text = value.to_s.strip
      text.empty? ? nil : text
    end
  end
end
