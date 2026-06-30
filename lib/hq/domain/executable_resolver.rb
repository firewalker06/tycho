# frozen_string_literal: true

require_relative "constants"

module HQ
  module ExecutableResolver
    Resolution = Struct.new(:name, :command, :path, :source, keyword_init: true) do
      def available?
        !path.to_s.empty?
      end
    end

    ENV_NAMES = {
      "claude" => "CLAUDE_BIN",
      "codex" => "CODEX_BIN",
      "opencode" => "OPENCODE_BIN",
      "mise" => "MISE_BIN",
      "tailscale" => "TAILSCALE_BIN"
    }.freeze

    module_function

    def resolve_tool(name)
      tool_name = name.to_s
      resolve(tool_name, env_name: ENV_NAMES[tool_name], fallback_paths: fallback_paths_for(tool_name))
    end

    def command_for_tool(name)
      resolve_tool(name).command
    end

    def resolve(command, env_name: nil, fallback_paths: [])
      name = command.to_s.strip
      configured = env_name ? HQ.env_present(env_name, "").to_s.strip : ""
      unless configured.empty?
        return Resolution.new(name: name, command: configured, path: executable_path(configured), source: "env")
      end

      Array(fallback_paths).each do |candidate|
        path = executable_path(candidate.to_s)
        return Resolution.new(name: name, command: path, path: path, source: "fallback") if path
      end

      path = executable_path(name)
      Resolution.new(name: name, command: path || name, path: path, source: path ? "path" : "missing")
    end

    def executable_path(command)
      value = command.to_s.strip
      return nil if value.empty?
      return value if value.include?(File::SEPARATOR) && File.file?(value) && File.executable?(value)

      ENV.fetch("PATH", "").split(File::PATH_SEPARATOR).each do |dir|
        path = File.join(dir, value)
        return path if File.file?(path) && File.executable?(path)
      end
      nil
    end

    def fallback_paths_for(name)
      case name.to_s
      when "claude", "codex", "opencode", "mise"
        [
          File.join(Dir.home, ".local", "bin", name.to_s),
          "/opt/homebrew/bin/#{name}",
          "/usr/local/bin/#{name}"
        ]
      else
        []
      end
    end
  end
end
