# frozen_string_literal: true

require "open3"
require "shellwords"
require "time"
require "timeout"

require_relative "../harness_registry"
require_relative "executable_resolver"

module HQ
  module HarnessVersion
    COMMAND_TIMEOUT = 2
    CACHE_TTL = 300
    DEFAULT_VERSION_ARGS = {
      "codex" => ["--version"],
      "claude" => ["--version"]
    }.freeze

    Snapshot = Struct.new(
      :harness, :adapter, :version, :raw_version, :checked_at, :command, :path, :source,
      keyword_init: true
    ) do
      def run_fields
        result = {
          "harness" => harness,
          "harness_adapter" => adapter,
          "harness_version" => version,
          "harness_raw_version" => raw_version,
          "harness_version_checked_at" => checked_at,
          "harness_version_command" => command_string,
          "harness_executable_path" => path,
          "harness_executable_source" => source
        }
        result.reject { |_key, value| value.to_s.empty? }
      end

      def readiness_fields
        result = {
          version: version,
          raw_version: raw_version,
          version_checked_at: checked_at&.iso8601,
          version_command: command_string
        }
        result.reject { |_key, value| value.to_s.empty? }
      end

      def command_string
        parts = Array(command).map(&:to_s).reject(&:empty?)
        parts.empty? ? nil : Shellwords.join(parts)
      end
    end

    module_function

    def for_agent(name)
      custom = HQ.custom_harness(name)
      return for_custom(custom) if custom

      for_builtin(name)
    end

    def for_builtin(name, resolution: ExecutableResolver.resolve_tool(name))
      harness = name.to_s
      command = version_command_for_builtin(harness, resolution)
      capture(
        harness: harness,
        adapter: harness,
        command: command,
        path: resolution&.path,
        source: resolution&.source
      )
    end

    def cached_for_builtin(name, resolution: ExecutableResolver.resolve_tool(name))
      cached(["builtin", name.to_s, resolution&.command.to_s, resolution&.path.to_s]) do
        for_builtin(name, resolution:)
      end
    end

    def for_custom(config)
      parts = custom_version_command(config)
      executable = executable_for(parts)
      resolution = executable ? ExecutableResolver.resolve(executable) : nil
      capture(
        harness: config.key,
        adapter: config.adapter,
        command: parts,
        path: resolution&.path,
        source: resolution&.source
      )
    end

    def cached_for_custom(config)
      cached(["custom", config.key.to_s, config.adapter.to_s, config.execution_command.to_s, config.version_command.to_s]) do
        for_custom(config)
      end
    end

    def cached(key)
      entry = cache[key]
      now = Time.now
      return entry[:value] if entry && entry[:expires_at] > now

      value = yield
      cache[key] = { value: value, expires_at: now + CACHE_TTL }
      value
    end

    def cache
      @cache ||= {}
    end

    def version_command_for_builtin(name, resolution)
      args = DEFAULT_VERSION_ARGS[name.to_s]
      return [] unless args

      command = resolution&.command.to_s
      command.empty? ? [] : [command] + args
    end

    def custom_version_command(config)
      explicit = config.version_command_parts
      return explicit unless explicit.empty?

      config.resolved_command_parts + ["--version"]
    end

    def capture(harness:, adapter:, command:, path:, source:)
      parts = Array(command).map(&:to_s).reject(&:empty?)
      raw = capture_output(parts) if runnable?(parts)
      Snapshot.new(
        harness: harness,
        adapter: adapter,
        version: normalize_version(raw),
        raw_version: raw,
        checked_at: parts.empty? ? nil : Time.now,
        command: parts,
        path: path,
        source: source
      )
    end

    def capture_output(parts)
      out = ""
      err = ""
      status = nil
      Timeout.timeout(COMMAND_TIMEOUT) do
        out, err, status = Open3.capture3(*parts)
      end
      return nil unless status&.success?

      text = "#{out}\n#{err}".lines.map(&:strip).reject(&:empty?).first
      text.to_s.empty? ? nil : text
    rescue StandardError
      nil
    end

    def runnable?(parts)
      executable = executable_for(parts)
      return false if executable.to_s.empty?

      executable_available?(executable)
    end

    def executable_for(parts)
      return nil if parts.empty?
      return parts.first unless File.basename(parts.first) == "env"

      parts.drop(1).find { |part| !part.include?("=") } || parts.first
    end

    def executable_available?(command)
      return File.file?(command) && File.executable?(command) if command.include?(File::SEPARATOR)

      ENV.fetch("PATH", "").split(File::PATH_SEPARATOR).any? do |dir|
        path = File.join(dir, command)
        File.file?(path) && File.executable?(path)
      end
    end

    def normalize_version(raw)
      text = raw.to_s.strip
      return nil if text.empty?

      text[/\d+(?:\.\d+)+(?:[-+][0-9A-Za-z.-]+)?/] || text
    end
  end
end
