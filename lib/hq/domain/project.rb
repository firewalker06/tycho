# frozen_string_literal: true

require "open3"
require_relative "constants"
require_relative "log_paths"

module HQ
  class Project
    attr_reader :config, :key, :name, :path, :commit_hash, :branch, :dirty_files, :group

    def initialize(config)
      @config = config
      @key = config.key
      @name = config.name
      @group = config.group.to_s
      @path = config.path
      @commit_hash = nil
      @branch = nil
      @dirty_files = 0
    end

    def status
      "configured"
    end

    def hidden?
      @config.hidden == true
    end

    def hidden_config
      @config.hidden_config
    end

    def group_hidden
      @config.group_hidden
    end

    def visibility_source
      return "project" unless @config.hidden_config.nil?
      return "group" unless @config.group_hidden.nil?

      "default"
    end

    def agent_templates
      @config.agent_templates
    end

    def response_style
      @config.response_style
    end

    def pr_url
      @config.pr_url
    end

    def pr_number
      return nil unless pr_url

      match = pr_url.match(%r{/pull/(\d+)})
      match && match[1]
    end

    def github_repo_url
      return nil unless pr_url

      match = pr_url.match(%r{\A(https?://[^/]+/[^/]+/[^/]+)/pull/\d+})
      match && match[1]
    end

    def branch_url(branch_name)
      return nil if branch_name.to_s.empty?
      return nil unless (repo = github_repo_url)

      "#{repo}/tree/#{branch_name}"
    end

    def commit_url(sha)
      return nil if sha.to_s.empty?
      return nil unless (repo = github_repo_url)

      "#{repo}/commit/#{sha}"
    end

    # Runs git, so call it from a background refresh, never from a read path.
    # Returns the new git values, or nil when the read failed and the previous values stay.
    def refresh_metadata!
      metadata = read_git_metadata
      apply_git_metadata(metadata) if metadata
      metadata
    end

    def apply_git_metadata(metadata)
      @commit_hash = metadata[:commit_hash]
      @branch = metadata[:branch]
      @dirty_files = metadata[:dirty_files]
      self
    end

    def log_dir
      LogPaths.project_log_dir(@key)
    end

    def archive_logs!(root = PROJECT_ARCHIVE_DIR, now: Time.now)
      return nil unless Dir.exist?(log_dir)

      FileUtils.mkdir_p(root)
      destination = unique_archive_destination(root, now)
      FileUtils.mv(log_dir, destination)
      destination
    end

    private

    def unique_archive_destination(root, now)
      LogPaths.project_archive_destination(root, archive_name, now:)
    end

    def archive_name
      slug = @name.to_s.downcase.gsub(/[^a-z0-9]+/, "-").gsub(/\A-+|-+\z/, "")
      slug.empty? ? @key : slug
    end

    def read_git_metadata
      return nil unless File.exist?(File.join(@path, ".git"))

      porcelain, status = Open3.capture2("git", "-C", @path, "status", "--porcelain", err: File::NULL)
      unless status.success?
        HQ.logger.warn("Project") { "Git status failed for #{@key}; keeping cached metadata" }
        return nil
      end

      {
        commit_hash: git_output("rev-parse", "--short", "HEAD"),
        branch: git_output("branch", "--show-current"),
        dirty_files: porcelain.lines.count
      }
    rescue StandardError => e
      HQ.logger.warn("Project") { "Git metadata read failed for #{@key}: #{e.class} - #{e.message}; keeping cached metadata" }
      nil
    end

    def git_output(*args)
      output, status = Open3.capture2("git", "-C", @path, *args, err: File::NULL)
      value = output.strip
      status.success? && !value.empty? ? value : nil
    end
  end
end
