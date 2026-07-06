# frozen_string_literal: true

require "shellwords"

module HQ
  BUILTIN_HARNESSES = %w[codex claude opencode].freeze
  HarnessCatalogConfig = Struct.new(:key, :models, :reasoning_efforts, keyword_init: true)

  HarnessConfig = Struct.new(:key, :adapter, :execution_command, keyword_init: true) do
    def command_parts
      case execution_command
      when Array
        execution_command.map(&:to_s).reject(&:empty?)
      else
        Shellwords.split(execution_command.to_s)
      end
    end

    def resolved_command_parts(path: ENV.fetch("PATH", ""))
      parts = command_parts
      index = executable_index(parts)
      return parts unless index

      parts[index] = resolve_executable(parts[index], path:) || parts[index]
      parts
    end

    def resolved_execution(path: ENV.fetch("PATH", ""))
      parts = resolved_command_parts(path:)
      env, command = split_env_prefix(parts)
      { command: command, env: env }
    end

    private

    def split_env_prefix(parts)
      return [{}, parts] unless parts.first == "env"

      env = {}
      index = 1
      while index < parts.length && parts[index].include?("=")
        key, value = parts[index].split("=", 2)
        env[key] = value
        index += 1
      end

      return [{}, parts] if index >= parts.length

      [env, parts[index..]]
    end

    def executable_index(parts)
      return nil if parts.empty?
      return 0 unless parts.first == "env"

      parts.each_with_index.drop(1).find { |part, _index| !part.include?("=") }&.last
    end

    def resolve_executable(command, path:)
      return command if command.include?(File::SEPARATOR) && File.executable?(command)

      path.split(File::PATH_SEPARATOR).map { |dir| File.join(dir, command) }.find do |candidate|
        File.file?(candidate) && File.executable?(candidate)
      end
    end
  end

  module_function

  def custom_harnesses=(configs)
    @custom_harnesses = Array(configs).each_with_object({}) do |config, result|
      result[config.key] = config if config.respond_to?(:key)
    end
  end

  def custom_harnesses
    @custom_harnesses ||= {}
  end

  def custom_harness(key)
    custom_harnesses[key.to_s]
  end

  def harness_adapter(key)
    custom_harness(key)&.adapter || key.to_s
  end

  def supported_harness?(key)
    value = key.to_s
    BUILTIN_HARNESSES.include?(value) || custom_harnesses.key?(value)
  end

  def harness_keys
    BUILTIN_HARNESSES + custom_harnesses.keys.sort
  end
end
