# frozen_string_literal: true

require "yaml"
require "uri"
require_relative "harness_registry"
require_relative "domain/constants"
require_relative "domain/file_store"

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
    :response_style,
    keyword_init: true
  )
  GroupConfig = Struct.new(:name, :hidden, keyword_init: true)
  RemoteServerConfig = Struct.new(
    :key,
    :name,
    :url,
    :token,
    :token_env,
    keyword_init: true
  ) do
    def resolved_token
      env_name = token_env.to_s.strip
      return ENV[env_name].to_s unless env_name.empty?

      token.to_s
    end
  end
  ProjectConfig = Struct.new(
    :key,
    :name,
    :group,
    :path,
    :agent,
    :model,
    :reasoning_effort,
    :response_style,
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
    DEFAULT_SESSION_LOOP_SETTINGS = {
      interval_minutes: 10,
      end_time: "23:59",
      prompt_templates: [
        {
          key: "pull-request-review",
          name: "Wait for PR review",
          prompt: "Check the open pull request for new approvals, reviews, or comments. " \
                  "Address any actionable feedback, run the relevant checks, and update the pull request. " \
                  "If nothing requires action, return no_action_needed."
        }
      ]
    }.freeze

    attr_reader :path, :projects, :groups, :remote_servers, :system_prompts_path, :custom_harnesses,
                :harness_catalogs, :session_loop_settings

    def archived_projects_path
      default_archived_path
    end

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
      @harness_catalogs = build_harness_catalogs(data["harness_catalogs"])
      @session_loop_settings = build_session_loop_settings(data["session_loops"])
      @groups = build_groups(data["groups"])
      @remote_servers = build_remote_servers(data["remote_servers"])
      HQ.custom_harnesses = @custom_harnesses
      remove_instance_variable(:@normalized_system_prompts) if instance_variable_defined?(:@normalized_system_prompts)
      remove_instance_variable(:@system_prompt_templates) if instance_variable_defined?(:@system_prompt_templates)
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

    def add_project!(attrs)
      data = load_yaml(@path)
      projects = Array(data["projects"])
      key = attrs[:key].to_s.strip
      raise ConfigError, "Missing project key" if key.empty?
      raise ConfigError, "Duplicate project key: #{key}" if projects.any? { |p| p["key"].to_s == key }

      entry = { "key" => key, "name" => attrs[:name].to_s }
      entry["group"] = attrs[:group].to_s unless attrs[:group].to_s.strip.empty?
      entry["path"] = attrs[:path].to_s
      entry["agent"] = attrs[:agent].to_s unless attrs[:agent].to_s.strip.empty?
      %i[model reasoning_effort pr_url].each do |field|
        value = attrs[field]
        entry[field.to_s] = value.to_s unless value.to_s.strip.empty?
      end
      entry["response_style"] = attrs[:response_style] if attrs.key?(:response_style) && !attrs[:response_style].nil?
      entry["hidden"] = attrs[:hidden] if attrs.key?(:hidden) && !attrs[:hidden].nil?

      group = entry["group"].to_s
      insert_index = nil
      unless group.empty?
        last_in_group = projects.rindex { |p| p["group"].to_s == group }
        insert_index = last_in_group ? last_in_group + 1 : nil
      end
      insert_index ? projects.insert(insert_index, entry) : projects.push(entry)
      validate_project_entries!(projects)
      data["projects"] = projects
      write_yaml(@path, data)
      load!
      added = @projects.find { |p| p.key == key }
      HQ.hooks.publish("project.added", project_key: key, project_path: added&.path.to_s)
      key
    end

    def add_remote_server!(attrs)
      data = load_yaml(@path)
      servers = Array(data["remote_servers"])
      url = normalize_remote_server_url(attrs[:url] || attrs["url"])
      name = (attrs[:name] || attrs["name"]).to_s.strip
      key = (attrs[:key] || attrs["key"]).to_s.strip
      key = unique_remote_server_key(name, url, servers) if key.empty?
      entry = {
        "key" => key,
        "name" => name.empty? ? key : name,
        "url" => url
      }

      existing_index = servers.index do |server|
        server["key"].to_s == key || normalize_remote_server_url(server["url"]) == url
      rescue ConfigError
        false
      end
      if existing_index
        existing = servers[existing_index]
        entry["token"] = existing["token"] if existing.key?("token")
        entry["token_env"] = existing["token_env"] if existing.key?("token_env")
        servers[existing_index] = entry
      else
        servers << entry
      end

      build_remote_servers([entry])
      data["remote_servers"] = servers
      write_yaml(@path, data)
      load!
      @remote_servers.find { |server| server.key == key }
    end

    def remove_remote_server!(key)
      value = key.to_s.strip
      raise ConfigError, "Remote server key local is reserved for the current Tycho server" if value == "local"
      raise ConfigError, "Missing remote server key" if value.empty?

      data = load_yaml(@path)
      servers = Array(data["remote_servers"])
      next_servers = servers.reject { |server| server["key"].to_s == value }
      raise ConfigError, "Unknown remote server: #{value}" if next_servers.length == servers.length

      if next_servers.empty?
        data.delete("remote_servers")
      else
        data["remote_servers"] = next_servers
      end
      write_yaml(@path, data)
      load!
      value
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
        validate_project_entries!(projects)
        write_yaml(@path, data)
        load!
        HQ.hooks.publish("project.updated", project_key: project_key.to_s, fields: attrs.keys.map(&:to_s))
      end
      project
    end

    def update_harness_catalog!(harness_key, attrs)
      key = harness_key.to_s.strip.downcase
      raise ConfigError, "Missing harness key" if key.empty?
      unless HQ.supported_harness?(key)
        raise ConfigError, "Unsupported harness #{key.inspect}. Supported: #{HQ.harness_keys.join(", ")}"
      end

      data = load_yaml(@path)
      catalogs = data["harness_catalogs"].is_a?(Hash) ? data["harness_catalogs"] : {}
      entry = catalogs[key].is_a?(Hash) ? catalogs[key].dup : {}
      entry["models"] = normalize_catalog_values(attrs["models"] || attrs[:models], preserve_case: true)
      entry["reasoning_efforts"] = normalize_catalog_values(
        attrs["reasoning_efforts"] || attrs["reasoning_effort_suggestions"] || attrs[:reasoning_efforts],
        preserve_case: false
      )
      entry.delete("models") if entry["models"].empty?
      entry.delete("reasoning_efforts") if entry["reasoning_efforts"].empty?
      entry.empty? ? catalogs.delete(key) : catalogs[key] = entry
      data["harness_catalogs"] = catalogs
      data.delete("harness_catalogs") if catalogs.empty?

      write_yaml(@path, data)
      load!
      harness_catalog(key)
    end

    def harness_catalog(harness_key)
      @harness_catalogs[harness_key.to_s.strip.downcase]
    end

    def update_session_loop_settings!(attrs)
      settings = build_session_loop_settings(attrs, configured: true)
      data = load_yaml(@path)
      data["session_loops"] = {
        "interval_minutes" => settings.fetch(:interval_minutes),
        "end_time" => settings.fetch(:end_time),
        "prompt_templates" => settings.fetch(:prompt_templates).map do |template|
          {
            "key" => template.fetch(:key),
            "name" => template.fetch(:name),
            "prompt" => template.fetch(:prompt)
          }
        end
      }
      write_yaml(@path, data)
      load!
      @session_loop_settings
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

    def validate_project_entries!(entries)
      previous_projects = @projects
      @projects = build_projects(entries)
      validate!
    ensure
      @projects = previous_projects
    end

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

    def build_harness_catalogs(raw_catalogs)
      return {} unless raw_catalogs.is_a?(Hash)

      raw_catalogs.each_with_object({}) do |(raw_key, raw_entry), catalogs|
        key = raw_key.to_s.strip.downcase
        next if key.empty?

        entry = raw_entry.is_a?(Hash) ? raw_entry : {}
        catalogs[key] = HarnessCatalogConfig.new(
          key: key,
          models: normalize_catalog_values(entry["models"] || entry["model_suggestions"], preserve_case: true),
          reasoning_efforts: normalize_catalog_values(
            entry["reasoning_efforts"] || entry["reasoning_effort_suggestions"],
            preserve_case: false
          )
        )
      end
    end

    def build_session_loop_settings(raw_settings, configured: false)
      settings = raw_settings.is_a?(Hash) ? raw_settings : {}
      use_defaults = !configured && !raw_settings.is_a?(Hash)
      interval = settings["interval_minutes"] || settings[:interval_minutes]
      interval = DEFAULT_SESSION_LOOP_SETTINGS.fetch(:interval_minutes) if interval.to_s.strip.empty?
      interval = Integer(interval.to_s, 10)
      unless interval.between?(1, 59)
        raise ConfigError, "Session loop interval_minutes must be between 1 and 59"
      end

      end_time = (settings["end_time"] || settings[:end_time]).to_s.strip
      end_time = DEFAULT_SESSION_LOOP_SETTINGS.fetch(:end_time) if end_time.empty?
      unless end_time.match?(/\A(?:[01]\d|2[0-3]):[0-5]\d\z/)
        raise ConfigError, "Session loop end_time must use HH:MM in 24-hour local time"
      end

      raw_templates = settings.key?("prompt_templates") ? settings["prompt_templates"] : settings[:prompt_templates]
      raw_templates = DEFAULT_SESSION_LOOP_SETTINGS.fetch(:prompt_templates) if use_defaults || raw_templates.nil?
      templates = normalize_session_loop_templates(raw_templates)
      {
        interval_minutes: interval,
        end_time: end_time,
        prompt_templates: templates
      }
    rescue ArgumentError, TypeError
      raise ConfigError, "Session loop interval_minutes must be an integer between 1 and 59"
    end

    def normalize_session_loop_templates(raw_templates)
      seen = {}
      Array(raw_templates).filter_map.with_index do |raw_template, index|
        next unless raw_template.is_a?(Hash)

        name = (raw_template["name"] || raw_template[:name]).to_s.strip
        prompt = (raw_template["prompt"] || raw_template[:prompt]).to_s.strip
        next if name.empty? && prompt.empty?
        raise ConfigError, "Session loop prompt template ##{index + 1} requires a name" if name.empty?
        raise ConfigError, "Session loop prompt template #{name.inspect} requires a prompt" if prompt.empty?

        key = (raw_template["key"] || raw_template[:key]).to_s.strip.downcase
        key = name.downcase.gsub(/[^a-z0-9]+/, "-").gsub(/\A-+|-+\z/, "") if key.empty?
        key = "template-#{index + 1}" if key.empty?
        raise ConfigError, "Duplicate session loop prompt template key #{key.inspect}" if seen[key]

        seen[key] = true
        { key: key, name: name, prompt: prompt }
      end
    end

    def build_projects(raw_projects)
      Array(raw_projects).map do |project|
        key = fetch_key(project, "project")
        path = expand_path(project["path"])
        name = (project["name"] || File.basename(path)).to_s
        group_name = project["group"].to_s.strip
        hidden_config = hidden_value(project, "project #{key}")
        group_hidden = @groups[group_name]&.hidden
        hidden = hidden_config.nil? ? group_hidden == true : hidden_config == true
        ProjectConfig.new(
          key: key,
          name: name,
          group: group_name,
          path: path,
          agent: normalize_agent(project["agent"]),
          model: normalize_model(project["model"]),
          reasoning_effort: normalize_reasoning_effort(project["reasoning_effort"]),
          response_style: normalize_response_style(project["response_style"]),
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

    def validate!
      validate_uniqueness!(@custom_harnesses.map(&:key), "custom harness")
      validate_uniqueness!(@projects.map(&:key), "project")
      validate_uniqueness!(@remote_servers.map(&:key), "remote server")
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
      project_response_style = normalize_response_style(project["response_style"])

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
          ),
          response_style: normalize_response_style(
            template.key?("response_style") ? template["response_style"] : project_response_style
          )
        )
      end

      built_templates.sort_by { |template| [template.name.downcase, template.key.downcase] }
    end

    def build_remote_servers(raw_servers)
      Array(raw_servers).map do |server|
        key = fetch_key(server, "remote server")
        unless key.match?(/\A[a-zA-Z0-9][a-zA-Z0-9_-]*\z/)
          raise ConfigError, "Invalid remote server key #{key.inspect}; use letters, numbers, dashes, or underscores"
        end
        if key == "local"
          raise ConfigError, "Remote server key local is reserved for the current Tycho server"
        end

        url = server["url"].to_s.strip
        raise ConfigError, "Remote server #{key} must define url" if url.empty?

        parsed = URI.parse(url)
        unless %w[http https].include?(parsed.scheme) && parsed.host
          raise ConfigError, "Remote server #{key} url must be an http(s) URL"
        end
        unless parsed.userinfo.to_s.empty?
          raise ConfigError, "Remote server #{key} url must not include credentials"
        end

        RemoteServerConfig.new(
          key: key,
          name: server["name"].to_s.strip.empty? ? key : server["name"].to_s.strip,
          url: url.sub(%r{/+\z}, ""),
          token: server["token"].to_s,
          token_env: server["token_env"].to_s.strip
        )
      rescue URI::InvalidURIError => e
        raise ConfigError, "Invalid remote server #{key.inspect} url: #{e.message}"
      end
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

    def normalize_response_style(value)
      return false if value == false

      text = value.to_s.strip
      return nil if text.empty? || text.casecmp("default").zero?
      return false if %w[none disabled off false].include?(text.downcase)

      text
    end

    def normalize_catalog_values(values, preserve_case:)
      Array(values).flat_map { |value| value.to_s.lines }.map do |value|
        text = value.to_s.strip
        preserve_case ? text : text.downcase
      end.reject(&:empty?).uniq
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

    def normalize_remote_server_url(value)
      url = value.to_s.strip
      raise ConfigError, "Remote server must define url" if url.empty?

      parsed = URI.parse(url)
      unless %w[http https].include?(parsed.scheme) && parsed.host
        raise ConfigError, "Remote server url must be an http(s) URL"
      end
      unless parsed.userinfo.to_s.empty?
        raise ConfigError, "Remote server url must not include credentials"
      end

      url.sub(%r{/+\z}, "")
    rescue URI::InvalidURIError => e
      raise ConfigError, "Invalid remote server url: #{e.message}"
    end

    def unique_remote_server_key(name, url, servers)
      base = name.to_s.downcase.gsub(/[^a-z0-9_-]+/, "-").gsub(/\A[-_]+|[-_]+\z/, "")
      base = "remote-server" if base.empty?
      base = "remote-#{base}" if base == "local"
      existing_for_url = servers.find do |server|
        normalize_remote_server_url(server["url"]) == url
      rescue ConfigError
        false
      end
      return existing_for_url["key"].to_s unless existing_for_url.nil?

      keys = servers.map { |server| server["key"].to_s }
      return base unless keys.include?(base)

      index = 2
      candidate = "#{base}-#{index}"
      while keys.include?(candidate)
        index += 1
        candidate = "#{base}-#{index}"
      end
      candidate
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
      FileStore.write_yaml(path, data)
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
