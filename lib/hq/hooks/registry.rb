# frozen_string_literal: true

require "yaml"

require_relative "../domain/constants"

module HQ
  module Hooks
    class Registry
      DEFAULT_TIMEOUT_ASYNC = 10
      DEFAULT_TIMEOUT_BLOCKING = 30

      attr_reader :global_handlers, :project_handlers, :ruby_handlers

      def initialize
        @global_handlers = []
        @project_handlers = Hash.new { |h, k| h[k] = [] }
        @ruby_handlers = []
      end

      def load!(global_path: default_global_path, projects: [], ruby_dirs: default_ruby_dirs)
        @global_handlers = []
        @project_handlers = Hash.new { |h, k| h[k] = [] }
        @ruby_handlers = []

        load_global_yaml(global_path)
        load_project_hooks(projects)
        load_ruby_files(ruby_dirs, projects)

        HQ.logger.info("Hooks") do
          "Loaded #{@global_handlers.size} global, " \
            "#{@project_handlers.values.map(&:size).sum} project, " \
            "#{@ruby_handlers.size} ruby handlers"
        end
        self
      rescue StandardError => e
        HQ.logger.error("Hooks") { "Registry load failed: #{e.class}: #{e.message}" }
        self
      end

      def register_ruby_handler(pattern, project_key: nil, &block)
        @ruby_handlers << {
          type: :ruby,
          pattern: pattern.to_s,
          project_key: project_key,
          handler: block,
          blocking: false,
          timeout: DEFAULT_TIMEOUT_ASYNC
        }
      end

      def handlers_for(event, project_key: nil)
        matches = []
        @global_handlers.each { |h| matches << h if pattern_match?(h[:pattern], event) }
        if project_key && (list = @project_handlers[project_key.to_s])
          list.each { |h| matches << h if pattern_match?(h[:pattern], event) }
        end
        @ruby_handlers.each do |h|
          next unless pattern_match?(h[:pattern], event)
          next if h[:project_key] && h[:project_key].to_s != project_key.to_s

          matches << h
        end
        matches
      end

      private

      def default_global_path
        HQ.env_present("HOOKS_PATH", HQ.default_hooks_path)
      end

      def default_ruby_dirs
        [File.expand_path("~/.claude/hq-hooks")]
      end

      def load_global_yaml(path)
        return unless File.exist?(path)

        data = YAML.safe_load(File.read(path), permitted_classes: [Symbol], aliases: true) || {}
        hooks_section = data["hooks"] || {}
        hooks_section.each do |pattern, entries|
          Array(entries).each do |entry|
            @global_handlers << normalize_shell_entry(pattern.to_s, entry)
          end
        end
      end

      def load_project_hooks(projects)
        Array(projects).each do |project|
          key = project.respond_to?(:key) ? project.key.to_s : project["key"].to_s
          hooks_section = project.respond_to?(:hooks) ? project.hooks : project["hooks"]
          next unless hooks_section.is_a?(Hash)

          hooks_section.each do |pattern, entries|
            Array(entries).each do |entry|
              @project_handlers[key] << normalize_shell_entry(pattern.to_s, entry)
            end
          end
        end
      end

      def load_ruby_files(global_dirs, projects)
        files = []
        Array(global_dirs).each do |dir|
          next unless dir && File.directory?(dir)

          files.concat(Dir[File.join(dir, "*.rb")].sort)
        end
        Array(projects).each do |project|
          path = project.respond_to?(:path) ? project.path : project["path"]
          next unless path

          project_dir = File.join(path.to_s, ".hq", "hooks")
          next unless File.directory?(project_dir)

          files.concat(Dir[File.join(project_dir, "*.rb")].sort)
        end
        files.each do |file|
          load(file)
        rescue StandardError => e
          HQ.logger.error("Hooks") { "Failed to load #{file}: #{e.class}: #{e.message}" }
        end
      end

      def normalize_shell_entry(pattern, entry)
        entry = {} unless entry.is_a?(Hash)
        blocking = entry["blocking"] || entry[:blocking] || false
        timeout_raw = entry["timeout"] || entry[:timeout]
        timeout = timeout_raw ? Integer(timeout_raw) : (blocking ? DEFAULT_TIMEOUT_BLOCKING : DEFAULT_TIMEOUT_ASYNC)
        {
          type: :shell,
          pattern: pattern,
          command: (entry["command"] || entry[:command]).to_s,
          env: stringify_env(entry["env"] || entry[:env]),
          blocking: !!blocking,
          timeout: timeout
        }
      end

      def stringify_env(env)
        return {} unless env.is_a?(Hash)

        env.each_with_object({}) { |(k, v), result| result[k.to_s] = v.to_s }
      end

      def pattern_match?(pattern, event)
        return true if pattern == "*"
        return true if pattern == event

        parts = pattern.split(".")
        regex = parts.map.with_index do |part, index|
          trailing = index == parts.length - 1
          if part == "*"
            trailing ? ".+" : "[^.]+"
          else
            Regexp.escape(part)
          end
        end.join("\\.")
        Regexp.new("\\A#{regex}\\z").match?(event)
      end
    end
  end
end
