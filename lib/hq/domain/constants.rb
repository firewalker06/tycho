# frozen_string_literal: true

require "erb"
require "json"
require "logger"
require "net/http"
require "openssl"
require "rbconfig"
require "shellwords"
require "time"
require "fileutils"
require "uri"

module HQ
  def self.env(name, default = nil)
    suffix = name.to_s.sub(/\ATYCHO_/, "").sub(/\AHQ_/, "")
    key = "TYCHO_#{suffix}"
    return ENV[key] if ENV.key?(key)

    default
  end

  def self.env_present(name, default = nil)
    value = env(name)
    return default if value.to_s.strip.empty?

    value
  end

  ROOT_DIR = File.expand_path("../../..", __dir__)
  TYCHO_HOME = File.expand_path(env_present("HOME", File.join(Dir.home, ".tycho")))
  USER_CONFIG_DIR = File.expand_path(env_present("CONFIG_DIR", File.join(TYCHO_HOME, "config")))
  USER_SCHEDULES_DIR = File.expand_path(env_present("SCHEDULES_ROOT", File.join(TYCHO_HOME, "schedules")))
  USER_LOGS_DIR = File.expand_path(env_present("LOGS_ROOT", File.join(TYCHO_HOME, "logs")))
  USER_WORKSPACES_DIR = File.join(TYCHO_HOME, "workspaces")
  WELCOME_WORKSPACE_DIR = File.join(USER_WORKSPACES_DIR, "welcome")
  BUNDLED_CONFIG_DIR = File.join(ROOT_DIR, "config")

  def self.default_config_path
    ensure_user_config_file("hq.yml", "hq.yml.example")
  end

  def self.default_system_prompts_path(_config_path)
    ensure_user_config_file("system_prompts.yml", "system_prompts.yml.example")
  end

  def self.default_response_style_path
    ensure_user_config_file("response_style.md", "response_style.md.example")
  end

  def self.default_schedules_path
    ensure_user_config_file("schedules.yml", "schedules.yml.example")
  end

  def self.default_hooks_path
    ensure_user_config_file("hooks.yml", "hooks.example.yml")
  end

  def self.ensure_user_config_file(name, example_name)
    target = File.join(USER_CONFIG_DIR, name)
    return target if File.exist?(target)

    FileUtils.mkdir_p(File.dirname(target))
    source = File.join(BUNDLED_CONFIG_DIR, example_name)
    if File.exist?(source)
      FileUtils.cp(source, target)
    else
      File.write(target, "---\n")
    end
    target
  end

  # Keep existing user-owned schemas valid as the structured result contract
  # grows. This changes only the owned memory_handoff property and root field.
  def self.migrate_agent_result_schema!(path)
    source = File.join(BUNDLED_CONFIG_DIR, "schemas", "agent_result.json")
    current = JSON.parse(File.read(path))
    bundled = JSON.parse(File.read(source))
    properties = current["properties"]
    return path unless properties.is_a?(Hash)

    handoff = bundled.dig("properties", "memory_handoff")
    return path unless handoff.is_a?(Hash)

    changed = properties["memory_handoff"] != handoff
    properties["memory_handoff"] = handoff
    required = Array(current["required"])
    unless required.include?("memory_handoff")
      current["required"] = required + ["memory_handoff"]
      changed = true
    end
    File.write(path, "#{JSON.pretty_generate(current)}\n") if changed
    path
  rescue JSON::ParserError, SystemCallError
    path
  end

  LOGS_DIR = USER_LOGS_DIR
  AGENTS_FILE = File.join(LOGS_DIR, "managed_agents.json")
  DELEGATIONS_FILE = File.join(LOGS_DIR, "agent_delegations.json")
  SERVER_IDENTITY_FILE = File.join(USER_CONFIG_DIR, "server_identity.json")
  USAGE_METRICS_FILE = File.join(LOGS_DIR, "usage_metrics.json")
  REMOTE_RESOURCES_FILE = File.join(LOGS_DIR, "remote_resources.json")
  SCHEDULES_FILE = env_present("SCHEDULES_PATH", default_schedules_path)
  SCHEDULES_STATE_FILE = env_present("SCHEDULES_STATE_PATH", File.join(LOGS_DIR, "schedules.json"))
  SCHEDULER_DAEMON_FILE = env_present("SCHEDULER_DAEMON_PATH", File.join(LOGS_DIR, "scheduler_daemon.json"))
  PUSH_SUBSCRIPTIONS_FILE = File.join(LOGS_DIR, "push_subscriptions.json")
  PUSH_NOTIFICATIONS_FILE = File.join(LOGS_DIR, "push_notifications.json")
  WEB_PUSH_VAPID_FILE = File.join(LOGS_DIR, "web_push_vapid.json")
  GITHUB_AUTH_FILE = env_present("GITHUB_AUTH_PATH", File.join(USER_CONFIG_DIR, "github_auth.json"))
  PROJECT_LOGS_DIR = File.join(LOGS_DIR, "projects")
  PROJECT_ARCHIVE_DIR = File.join(PROJECT_LOGS_DIR, "archived")
  AGENT_LOGS_DIR = File.join(LOGS_DIR, "agents")
  AGENT_ARCHIVE_DIR = File.join(AGENT_LOGS_DIR, "archive")
  AGENT_RESULT_SCHEMA = migrate_agent_result_schema!(
    ensure_user_config_file(File.join("schemas", "agent_result.json"), File.join("schemas", "agent_result.json"))
  )
  LOG_FILE = File.join(LOGS_DIR, "hq.log")
  HOOKS_LOG_FILE = File.join(LOGS_DIR, "hooks.log")

  FileUtils.mkdir_p(LOGS_DIR)
  FileUtils.mkdir_p(USER_SCHEDULES_DIR)
  FileUtils.mkdir_p(USER_WORKSPACES_DIR)
  FileUtils.mkdir_p(PROJECT_LOGS_DIR)
  FileUtils.mkdir_p(PROJECT_ARCHIVE_DIR)
  FileUtils.mkdir_p(AGENT_LOGS_DIR)
  FileUtils.mkdir_p(AGENT_ARCHIVE_DIR)

  def self.logger
    @logger ||= begin
      logger = Logger.new(LOG_FILE, "daily")
      logger.level = Logger.const_get(env_present("LOG_LEVEL", "INFO").upcase)
      logger.formatter = proc { |severity, datetime, progname, msg|
        tag = progname ? " [#{progname}]" : ""
        "[#{severity}] [#{datetime.strftime("%Y-%m-%d %H:%M:%S")}]#{tag} #{msg}\n"
      }
      logger
    end
  end

  def self.hooks
    @hooks ||= begin
      require_relative "../hooks"
      HQ::Hooks::Dispatcher.new.tap(&:start!)
    end
  end

  Dir.glob(File.join(LOGS_DIR, "hq.log.*")).each do |old_log|
    File.delete(old_log) if File.mtime(old_log) < Time.now - 7 * 86_400
  rescue StandardError
    nil
  end
end
