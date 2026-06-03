# frozen_string_literal: true

require "yaml"
require_relative "harness_registry"
require_relative "domain/constants"

module HQ
  class ConfigError < StandardError; end

  AgentTemplateConfig = Struct.new(
    :key,
    :name,
    :prompt,
    :sandbox_mode,
    :agent,
    :model,
    :reasoning_effort,
    keyword_init: true
  )
  GroupConfig = Struct.new(:name, :hidden, keyword_init: true)
  ProjectConfig = Struct.new(
    :key,
    :name,
    :group,
    :path,
    :apps,
    :agent,
    :model,
    :reasoning_effort,
    :agent_templates,
    :hooks,
    :pr_url,
    :hidden,
    :hidden_config,
    :group_hidden,
    keyword_init: true
  )

  class Registry
    DEFAULT_PATH = HQ.default_config_path
    DEFAULT_ARCHIVED_BASENAME = "hq.archived.yml"

    attr_reader :path, :projects, :groups, :system_prompts_path, :custom_harnesses

    def initialize(path: HQ.env_present("CONFIG_PATH", DEFAULT_PATH), system_prompts_path: nil)
      @path = File.expand_path(path)
      default_prompts_path = if @path == File.expand_path(DEFAULT_PATH)
                               HQ.default_system_prompts_path(@path)
                             else
                               default_system_prompts_path(@path)
                             end
      @system_prompts_path = File.expand_path(system_prompts_path || HQ.env_present("SYSTEM_PROMPTS_PATH", default_prompts_path))
      @projects = []
      @groups = {}
      @system_prompts = {}
      load!
    end

    def load!
      data = load_yaml(@path)
      @system_prompts = load_yaml(@system_prompts_path, optional: true)
      @custom_harnesses = build_custom_harnesses(data["custom_harnesses"])
      @groups = build_groups(data["groups"])
      HQ.custom_harnesses = @custom_harnesses
      remove_instance_variable(:@normalized_system_prompts) if instance_variable_defined?(:@normalized_system_prompts)
      remove_instance_variable(:@system_prompt_templates) if instance_variable_defined?(:@system_prompt_templates)
      write_yaml(@path, data) if persist_detected_apps!(data)
      @projects = build_projects(data["projects"] || [])
      validate!
      HQ.logger.info("Config") { "Loaded #{@projects.size} projects" }
      HQ.hooks.publish("config.loaded", path: @path, project_count: @projects.size)
      @projects.each do |project|
        HQ.hooks.publish("project.loaded", project_key: project.key, project_path: project.path)
      end
    rescue Errno::ENOENT
      raise ConfigError, "Config file not found: #{@path}"
    rescue Psych::SyntaxError => e
      raise ConfigError, "Invalid YAML in #{e.file}: #{e.message}"
    end

    def self.kamal_app?(project_path)
      path = project_path.to_s
      return false if path.empty?

      File.exist?(File.join(path, "config", "deploy.yml"))
    end

    def add_project!(attrs)
      data = load_yaml(@path)
      projects = Array(data["projects"])
      key = attrs[:key].to_s.strip
      raise ConfigError, "Missing project key" if key.empty?
      raise ConfigError, "Duplicate project key: #{key}" if projects.any? { |p| p["key"].to_s == key }

      entry = { "key" => key, "name" => attrs[:name].to_s }
      entry["group"] = attrs[:group].to_s unless attrs[:group].to_s.strip.empty?
      entry["path"] = attrs[:path].to_s
      entry["apps"] = attrs[:apps] == true unless attrs[:apps].nil?
      entry["agent"] = attrs[:agent].to_s unless attrs[:agent].to_s.strip.empty?

      group = entry["group"].to_s
      insert_index = nil
      unless group.empty?
        last_in_group = projects.rindex { |p| p["group"].to_s == group }
        insert_index = last_in_group ? last_in_group + 1 : nil
      end
      insert_index ? projects.insert(insert_index, entry) : projects.push(entry)
      data["projects"] = projects
      write_yaml(@path, data)
      load!
      added = @projects.find { |p| p.key == key }
      HQ.hooks.publish("project.added", project_key: key, project_path: added&.path.to_s)
      key
    end

    def update_group_hidden!(group_name, hidden)
      name = group_name.to_s.strip
      raise ConfigError, "Missing group name" if name.empty?

      data = load_yaml(@path)
      groups = data["groups"].is_a?(Hash) ? data["groups"] : {}
      entry = groups[name]
      entry = {} unless entry.is_a?(Hash)

      if hidden.nil?
        entry.delete("hidden")
      else
        entry["hidden"] = hidden ? true : false
      end

      if entry.empty?
        groups.delete(name)
      else
        groups[name] = entry
      end
      data["groups"] = groups unless groups.empty?
      data.delete("groups") if groups.empty?

      write_yaml(@path, data)
      load!
      HQ.hooks.publish("group.updated", group: name, fields: ["hidden"])
      groups[name]
    end

    def update_project_hidden!(project_key, hidden)
      data = load_yaml(@path)
      projects = Array(data["projects"])
      project = projects.find { |item| item["key"].to_s == project_key.to_s }
      return nil unless project

      if hidden.nil?
        project.delete("hidden")
      else
        project["hidden"] = hidden ? true : false
      end

      write_yaml(@path, data)
      load!
      HQ.hooks.publish("project.updated", project_key: project_key.to_s, fields: ["hidden"])
      project
    end

    def update_project!(project_key, attrs)
      data = load_yaml(@path)
      projects = Array(data["projects"])
      project = projects.find { |p| p["key"].to_s == project_key.to_s }
      return nil unless project

      changed = false
      attrs.each do |field, value|
        field = field.to_s
        value = value.to_s.strip if value.is_a?(String)
        if value.nil? || (value.is_a?(String) && value.empty?)
          changed = true if project.key?(field)
          project.delete(field)
        elsif project[field] != value
          project[field] = value
          changed = true
        end
      end

      if changed
        write_yaml(@path, data)
        load!
        HQ.hooks.publish("project.updated", project_key: project_key.to_s, fields: attrs.keys.map(&:to_s))
      end
      project
    end

    def archive_project!(project_key, archived_path: nil)
      data = load_yaml(@path)
      projects = Array(data["projects"])
      project_index = projects.index { |project| project["key"].to_s == project_key.to_s }
      return nil unless project_index

      project = projects.delete_at(project_index)
      data["projects"] = projects

      target_path = archived_path || default_archived_path
      archived = load_yaml(target_path, optional: true)
      archived["projects"] = Array(archived["projects"]).reject { |item| item["key"].to_s == project_key.to_s }
      archived["projects"] << project

      write_yaml(@path, data)
      write_yaml(target_path, archived)
      HQ.hooks.publish("project.archived", project_key: project_key.to_s)
      project
    end

    private

    def build_groups(raw_groups)
      return {} unless raw_groups.is_a?(Hash)

      raw_groups.each_with_object({}) do |(name, attrs), groups|
        group_name = name.to_s.strip
        next if group_name.empty?

        hidden = if attrs.is_a?(Hash)
                   hidden_value(attrs, "group #{group_name}")
                 else
                   normalize_hidden(attrs, "group #{group_name}")
                 end
        groups[group_name] = GroupConfig.new(name: group_name, hidden: hidden)
      end
    end

    def build_custom_harnesses(raw_harnesses)
      Array(raw_harnesses).map do |harness|
        key = fetch_key(harness, "custom harness").downcase
        if BUILTIN_HARNESSES.include?(key)
          raise ConfigError, "Custom harness #{key.inspect} conflicts with built-in harnesses: #{BUILTIN_HARNESSES.join(", ")}"
        end

        adapter = harness["adapter"].to_s.strip.downcase
        unless adapter == "claude"
          raise ConfigError, "Unsupported adapter #{adapter.inspect} for custom harness #{key}. Supported adapters: claude"
        end

        execution_command = harness["execution_command"]
        unless execution_command.is_a?(String) || execution_command.is_a?(Array)
          raise ConfigError, "Custom harness #{key} must define execution_command as a string or list"
        end

        config = HarnessConfig.new(key: key, adapter: adapter, execution_command: execution_command)
        if config.command_parts.empty?
          raise ConfigError, "Custom harness #{key} execution_command cannot be empty"
        end

        config
      end
    end

    def build_projects(raw_projects)
      Array(raw_projects).map do |project|
        key = fetch_key(project, "project")
        path = expand_path(project["path"])
        name = (project["name"] || File.basename(path)).to_s
        apps_enabled = apps_enabled_for(project)
        group_name = project["group"].to_s.strip
        hidden_config = hidden_value(project, "project #{key}")
        group_hidden = @groups[group_name]&.hidden
        hidden = hidden_config.nil? ? group_hidden == true : hidden_config == true
        ProjectConfig.new(
          key: key,
          name: name,
          group: group_name,
          path: path,
          apps: apps_enabled,
          agent: normalize_agent(project["agent"]),
          model: normalize_model(project["model"]),
          reasoning_effort: normalize_reasoning_effort(project["reasoning_effort"]),
          agent_templates: build_agent_templates(
            project,
            project_key: key,
            project_name: name,
            project_path: path
          ),
          hooks: project["hooks"].is_a?(Hash) ? project["hooks"] : nil,
          pr_url: project["pr_url"].to_s.strip.empty? ? nil : project["pr_url"].to_s.strip,
          hidden: hidden,
          hidden_config: hidden_config,
          group_hidden: group_hidden
        )
      end
    end

    def hidden_value(hash, label)
      return nil unless hash.is_a?(Hash) && hash.key?("hidden")

      normalize_hidden(hash["hidden"], label)
    end

    def normalize_hidden(value, label)
      return nil if value.nil?
      return value if [true, false].include?(value)

      normalized = value.to_s.strip.downcase
      return true if %w[true yes on 1].include?(normalized)
      return false if %w[false no off 0].include?(normalized)
      return nil if %w[inherit default nil null].include?(normalized)

      raise ConfigError, "Invalid hidden value for #{label}: #{value.inspect}"
    end

    def apps_enabled_for(project)
      return Registry.kamal_app?(expand_path(project["path"])) unless project.key?("apps")

      value = project["apps"]
      return value if [true, false].include?(value)
      return false if value.nil?

      normalized = value.to_s.strip.downcase
      return true if %w[true yes on 1].include?(normalized)
      return false if %w[false no off 0].include?(normalized)

      !!value
    end

    def persist_detected_apps!(data)
      projects = Array(data["projects"])
      changed = false
      projects.each do |project|
        next if project.key?("apps")

        project["apps"] = Registry.kamal_app?(expand_path(project["path"]))
        changed = true
      end
      changed
    end

    def validate!
      validate_uniqueness!(@custom_harnesses.map(&:key), "custom harness")
      validate_uniqueness!(@projects.map(&:key), "project")
      @projects.each do |project|
        raise ConfigError, "Project path is missing for #{project.key}" if project.path.to_s.empty?
        if project.agent_templates.empty?
          raise ConfigError,
                "Project #{project.key} must define at least one agent template"
        end

        template_keys = project.agent_templates.map(&:key)
        duplicates = template_keys.group_by(&:itself).select { |_, values| values.length > 1 }.keys
        unless duplicates.empty?
          raise ConfigError,
                "Duplicate agent template keys for #{project.key}: #{duplicates.join(", ")}"
        end
      end
    end

    def build_agent_templates(project, project_key:, project_name:, project_path:)
      templates = system_prompt_templates
      templates = [default_template(project)] if templates.empty?
      project_agent = normalize_agent(project["agent"])
      project_model = normalize_model(project["model"])
      project_reasoning_effort = normalize_reasoning_effort(project["reasoning_effort"])

      built_templates = templates.map.with_index(1) do |template, index|
        prompt = resolve_template_prompt(
          template,
          index:,
          project_key:,
          project_name:,
          project_path:,
          project_group: project["group"].to_s.strip
        )
        AgentTemplateConfig.new(
          key: (template["key"] || "template-#{index}").to_s,
          name: (template["name"] || humanize_template_key(template["key"]) || "Template #{index}").to_s,
          prompt: prompt.to_s.strip,
          sandbox_mode: (template["sandbox_mode"] || "danger-full-access").to_s,
          agent: normalize_agent(template["agent"] || project_agent),
          model: normalize_model(template.key?("model") ? template["model"] : project_model),
          reasoning_effort: normalize_reasoning_effort(
            template.key?("reasoning_effort") ? template["reasoning_effort"] : project_reasoning_effort
          )
        )
      end

      built_templates.sort_by { |template| [template.name.downcase, template.key.downcase] }
    end

    def default_template(project)
      {
        "key" => "default",
        "name" => "Default",
        "prompt" => "Work inside #{expand_path(project["path"])}. Inspect the repository, identify the highest-value next task, implement it if safe, run the relevant checks, and summarize the result.",
        "sandbox_mode" => "danger-full-access",
        "agent" => normalize_agent(project["agent"]),
        "model" => normalize_model(project["model"]),
        "reasoning_effort" => normalize_reasoning_effort(project["reasoning_effort"])
      }
    end

    def normalize_model(value)
      text = value.to_s.strip
      text.empty? ? nil : text
    end

    def normalize_reasoning_effort(value)
      text = value.to_s.strip.downcase
      text.empty? ? nil : text
    end

    def normalize_agent(agent)
      value = agent.to_s.strip.downcase
      return "codex" if value.empty?
      return value if HQ.supported_harness?(value)

      raise ConfigError, "Unsupported agent #{agent.inspect}. Supported agents: #{HQ.harness_keys.join(", ")}"
    end

    def validate_uniqueness!(keys, label)
      duplicates = keys.group_by(&:itself).select { |_, values| values.length > 1 }.keys
      return if duplicates.empty?

      raise ConfigError, "Duplicate #{label} keys: #{duplicates.join(", ")}"
    end

    def fetch_key(hash, label)
      key = hash["key"].to_s.strip
      raise ConfigError, "Missing #{label} key" if key.empty?

      key
    end

    def expand_path(path)
      return "" if path.to_s.strip.empty?

      File.expand_path(path.to_s)
    end

    def resolve_template_prompt(template, index:, project_key:, project_name:, project_path:, project_group:)
      inline_prompt = template["prompt"]
      return inline_prompt.to_s.strip unless inline_prompt.nil?

      prompt_key = (template["system_prompt"] || template["key"] || "template-#{index}").to_s
      prompt = prompt_for(prompt_key:)
      return "" if prompt.nil?

      interpolate_prompt(
        prompt,
        prompt_key:,
        project_key:,
        project_name:,
        project_path:,
        project_group:
      )
    end

    def prompt_for(prompt_key:)
      normalized_system_prompts[prompt_key]
    end

    def system_prompt_templates
      return @system_prompt_templates if defined?(@system_prompt_templates)

      @system_prompt_templates = @system_prompts.map do |prompt_key, prompt|
        if prompt.is_a?(Hash)
          prompt.each_with_object({ "key" => prompt_key.to_s }) do |(key, value), result|
            next if %w[prompt content].include?(key.to_s)

            result[key.to_s] = value
          end
        else
          { "key" => prompt_key.to_s }
        end
      end
    end

    def interpolate_prompt(prompt, prompt_key:, project_key:, project_name:, project_path:, project_group:)
      format(
        prompt.to_s.strip,
        project_key:,
        project_name:,
        project_path:,
        project_group:,
        workspace: project_path
      )
    rescue KeyError => e
      raise ConfigError,
            "Invalid interpolation for system prompt #{prompt_key.inspect} in project #{project_key}: #{e.message}"
    end

    def load_yaml(path, optional: false)
      return {} if optional && !File.exist?(path)

      YAML.safe_load(File.read(path), permitted_classes: [Symbol], aliases: true) || {}
    end

    def write_yaml(path, data)
      File.write(path, YAML.dump(data))
    end

    def normalized_system_prompts
      return @normalized_system_prompts if defined?(@normalized_system_prompts)

      @normalized_system_prompts = @system_prompts.each_with_object({}) do |(prompt_key, prompt), prompts|
        prompt_value = if prompt.is_a?(Hash)
                         prompt["prompt"] || prompt["content"] || prompt[:prompt] || prompt[:content]
                       else
                         prompt
                       end
        prompts[prompt_key.to_s] = prompt_value.to_s
      end
    end

    def humanize_template_key(key)
      words = key.to_s.split(/[-_]/).reject(&:empty?)
      return nil if words.empty?

      words.map { |word| acronym(word) || word.capitalize }.join(" ")
    end

    def acronym(word)
      return "PR" if word.casecmp("pr").zero?

      nil
    end

    def default_system_prompts_path(config_path)
      File.expand_path("system_prompts.yml", File.dirname(config_path))
    end

    def default_archived_path
      File.join(File.dirname(@path), DEFAULT_ARCHIVED_BASENAME)
    end
  end
end
