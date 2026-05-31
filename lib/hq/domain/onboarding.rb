# frozen_string_literal: true

require "fileutils"
require_relative "constants"

module HQ
  module Onboarding
    WELCOME_PROJECT_KEY = "welcome"
    WELCOME_PROJECT_NAME = "Welcome Sandbox"
    WELCOME_PROJECT_GROUP = "Getting Started"

    module_function

    def welcome_workspace_path
      WELCOME_WORKSPACE_DIR
    end

    def ensure_welcome_workspace!
      FileUtils.mkdir_p(welcome_workspace_path)
      write_once("README.md", welcome_readme)
      write_once("notes.md", welcome_notes)
      welcome_workspace_path
    end

    def welcome_project_attrs(agent: nil)
      {
        key: WELCOME_PROJECT_KEY,
        name: WELCOME_PROJECT_NAME,
        group: WELCOME_PROJECT_GROUP,
        path: ensure_welcome_workspace!,
        apps: false,
        agent: agent.to_s
      }
    end

    def current_directory_candidate(cwd = Dir.pwd)
      path = File.expand_path(cwd)
      return nil unless File.directory?(path)

      kind = workspace_kind(path)
      return nil unless kind

      basename = File.basename(path)
      {
        key: project_key_for(basename),
        name: basename,
        path: path,
        apps: File.exist?(File.join(path, "config", "deploy.yml")),
        kind: kind
      }
    end

    def project_key_for(name)
      key = name.to_s.downcase.gsub(/[^a-z0-9_-]+/, "-").gsub(/\A-+|-+\z/, "")
      key.empty? ? "project" : key
    end

    def workspace_kind(path)
      return "Kamal app" if File.exist?(File.join(path, "config", "deploy.yml"))
      return "Git repository" if File.directory?(File.join(path, ".git"))
      return "Ruby project" if File.exist?(File.join(path, "Gemfile"))
      return "JavaScript project" if File.exist?(File.join(path, "package.json"))

      nil
    end

    def write_once(relative_path, content)
      path = File.join(welcome_workspace_path, relative_path)
      return if File.exist?(path)

      File.write(path, content)
    end

    def welcome_readme
      <<~MARKDOWN
        # Welcome to Tycho

        This workspace is a safe place for first managed-agent runs.

        Try creating an agent and asking it to inspect this folder, summarize what
        Tycho is for, or make a small edit to `notes.md`.
      MARKDOWN
    end

    def welcome_notes
      <<~MARKDOWN
        # First Run Notes

        - Create an agent from this project.
        - Send a short prompt.
        - Add a real project when you are ready.
      MARKDOWN
    end
  end
end
