# frozen_string_literal: true

require "json"
require "open3"
require "timeout"

require_relative "../harness_registry"
require_relative "executable_resolver"

module HQ
  module HarnessCatalog
    REASONING_EFFORT_ORDER = %w[minimal low medium high xhigh max].freeze
    CLAUDE_MODEL_SUGGESTIONS = %w[default best sonnet opus haiku opusplan].freeze
    CLAUDE_REASONING_EFFORTS = %w[low medium high xhigh max].freeze
    COMMAND_TIMEOUT = 2

    module_function

    def for_builtin(name, resolution)
      cache_key = ["builtin", name.to_s, resolution&.command.to_s, resolution&.path.to_s]
      catalog_cache[cache_key] ||= build_builtin_catalog(name, resolution)
    end

    def for_custom(config)
      cache_key = ["custom", config.key.to_s, config.adapter.to_s, config.execution_command.to_s]
      catalog_cache[cache_key] ||= build_custom_catalog(config)
    end

    def build_builtin_catalog(name, resolution)
      case name.to_s
      when "codex"
        codex_catalog(resolution)
      when "claude"
        claude_catalog(resolution)
      when "opencode"
        opencode_catalog(resolution)
      else
        empty_catalog
      end
    end

    def build_custom_catalog(config)
      case config.adapter.to_s
      when "claude"
        claude_compatible_catalog(source: "claude-compatible defaults")
      else
        empty_catalog
      end
    end

    def catalog_cache
      @catalog_cache ||= {}
    end

    def codex_catalog(resolution)
      unless resolution&.available?
        return {
          model_suggestions: [],
          reasoning_effort_suggestions: REASONING_EFFORT_ORDER - ["max"],
          catalog_source: "codex defaults"
        }
      end

      data = capture_json([resolution.command, "debug", "models"]) ||
             capture_json([resolution.command, "debug", "models", "--bundled"])
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

    def claude_catalog(resolution)
      efforts = resolution&.available? ? claude_help_efforts(resolution.command) : []
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

    def opencode_catalog(resolution)
      unless resolution&.available?
        return {
          model_suggestions: [],
          reasoning_effort_suggestions: REASONING_EFFORT_ORDER,
          catalog_source: "opencode defaults",
          auth_providers: []
        }
      end

      model_rows = opencode_model_rows(resolution.command)
      source = model_rows.empty? ? "opencode models unavailable" : "opencode models"
      {
        model_suggestions: model_rows,
        reasoning_effort_suggestions: REASONING_EFFORT_ORDER,
        catalog_source: source,
        auth_providers: opencode_auth_providers(resolution.command)
      }
    end

    def claude_help_efforts(command)
      _out, err, status = nil
      out = ""
      with_quiet_open3_timeout do
        Timeout.timeout(COMMAND_TIMEOUT) do
          out, err, status = Open3.capture3(command, "--help")
        end
      end
      return [] unless status.success?

      text = "#{out}\n#{err}"
      match = text.match(/--effort\s+<[^>]+>.*?\(([^)]+)\)/m)
      return [] unless match

      match[1].split(/,\s*/).map { |value| value.strip.downcase }.reject(&:empty?)
    rescue StandardError
      []
    end

    def capture_json(command)
      out = ""
      status = nil
      with_quiet_open3_timeout do
        Timeout.timeout(COMMAND_TIMEOUT) do
          out, _err, status = Open3.capture3(*command)
        end
      end
      return nil unless status.success?

      JSON.parse(out)
    rescue StandardError
      nil
    end

    def opencode_model_rows(command)
      out = capture_stdout([command, "models"])
      return [] if out.to_s.empty?

      out.lines.filter_map do |line|
        text = line.strip
        next if text.empty? || text.start_with?("Provider", "MODEL", "─", "-")

        value = text.split(/\s+/).find { |part| part.include?("/") }
        value ||= text.split(/\s+/).first
        next if value.to_s.empty? || value == "ID"

        { value: value, label: value }
      end.uniq { |item| item[:value] }
    end

    def opencode_auth_providers(command)
      out = capture_stdout([command, "auth", "list"])
      return [] if out.to_s.empty?

      out.lines.filter_map do |line|
        text = line.strip
        next if text.empty? || text.match?(/\A(provider|name)\b/i)

        text.split(/\s+/).first
      end.uniq
    end

    def capture_stdout(command)
      out = ""
      status = nil
      with_quiet_open3_timeout do
        Timeout.timeout(COMMAND_TIMEOUT) do
          out, _err, status = Open3.capture3(*command)
        end
      end
      status.success? ? out : ""
    rescue StandardError
      ""
    end

    def with_quiet_open3_timeout
      previous = Thread.report_on_exception
      Thread.report_on_exception = false
      yield
    ensure
      Thread.report_on_exception = previous
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
