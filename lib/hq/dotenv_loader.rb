# frozen_string_literal: true

module HQ
  module DotenvLoader
    module_function

    def load(path, env: ENV)
      return {} unless File.exist?(path)

      File.readlines(path).each_with_object({}) do |line, loaded|
        key, value = parse_line(line)
        next unless key
        next if env.key?(key)

        env[key] = value
        loaded[key] = value
      end
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
