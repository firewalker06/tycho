# frozen_string_literal: true

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

    def refresh_metadata!
      parse_git_status
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

    def parse_git_status
      git_dir = File.join(@path, ".git")
      return unless File.exist?(git_dir)

      @commit_hash = `git -C #{@path.shellescape} rev-parse --short HEAD 2>/dev/null`.strip
      @commit_hash = nil if @commit_hash.to_s.empty?

      @branch = `git -C #{@path.shellescape} branch --show-current 2>/dev/null`.strip
      @branch = nil if @branch.to_s.empty?

      porcelain = `git -C #{@path.shellescape} status --porcelain 2>/dev/null`
      @dirty_files = porcelain.lines.count
    rescue StandardError
      @commit_hash = nil
      @branch = nil
      @dirty_files = 0
    end
  end
end
