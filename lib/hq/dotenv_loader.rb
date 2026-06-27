# frozen_string_literal: true

module HQ
  module DotenvLoader
    module_function

    def load_defaults(root:, env: ENV)
      load_files(default_paths(root: root, env: env), env: env)
    end

    def default_paths(root:, env: ENV)
      [
        File.expand_path(".env", root),
        File.join(tycho_home(env: env), ".env")
      ].uniq
    end

    def load_files(paths, env: ENV)
      protected_keys = env.keys.to_h { |key| [key, true] }
      Array(paths).each_with_object({}) do |path, loaded|
        loaded.merge!(load(path, env: env, protected_keys: protected_keys, override_loaded: true))
      end
    end

    def load(path, env: ENV, protected_keys: nil, override_loaded: false)
      return {} unless File.exist?(path)

      protected_keys ||= env.keys.to_h { |key| [key, true] }
      File.readlines(path).each_with_object({}) do |line, loaded|
        key, value = parse_line(line)
        next unless key
        next if protected_keys[key]
        next if env.key?(key) && !override_loaded

        env[key] = value
        loaded[key] = value
      end
    end

    def tycho_home(env: ENV)
      value = env["TYCHO_HOME"].to_s
      value = File.join(Dir.home, ".tycho") if value.empty?
      File.expand_path(value)
    end

    def parse_line(line)
      stripped = line.to_s.strip
      return nil if stripped.empty? || stripped.start_with?("#")

      stripped = stripped.sub(/\Aexport\s+/, "")
      key, value = stripped.split("=", 2)
      return nil if value.nil?

      key = key.to_s.strip
      return nil unless key.match?(/\A[A-Za-z_][A-Za-z0-9_]*\z/)

      [key, unquote(value.to_s.strip)]
    end

    def unquote(value)
      return value[1...-1] if value.length >= 2 && value.start_with?('"') && value.end_with?('"')
      return value[1...-1] if value.length >= 2 && value.start_with?("'") && value.end_with?("'")

      value
    end
  end
end
