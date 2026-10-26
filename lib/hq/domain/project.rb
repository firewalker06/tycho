# frozen_string_literal: true

require_relative "command_runner"
require_relative "constants"
require_relative "log_paths"

module HQ
  class Project
    # Bounds every git call. A stalled repository or mount must not hold the refresh for longer than this.
    GIT_COMMAND_TIMEOUT = 5
    GIT_FIELDS = %i[commit_hash branch dirty_files].freeze

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
      @git_known_fields = []
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
    # Returns only the fields that were read successfully; a failed field keeps its previous value.
    def refresh_metadata!
      metadata = read_git_metadata
      apply_git_metadata(metadata)
      metadata
    end

    def apply_git_metadata(metadata)
      @commit_hash = metadata[:commit_hash] if metadata.key?(:commit_hash)
      @branch = metadata[:branch] if metadata.key?(:branch)
      @dirty_files = metadata[:dirty_files] if metadata.key?(:dirty_files)
      @git_known_fields |= metadata.keys
      self
    end

    # False until every git field has a valid value, so a failed first read is not shown as clean.
    def git_metadata_known?
      (GIT_FIELDS - @git_known_fields).empty?
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

    # Reads each field on its own. A failed field is left out of the result, so only fields
    # that were read successfully overwrite cached values. A timed-out command skips the rest:
    # a stalled repository is unlikely to answer the next command either.
    def read_git_metadata
      return {} unless File.exist?(File.join(@path, ".git"))

      metadata = {}
      status = git_command("status", "--porcelain")
      if status.success?
        metadata[:dirty_files] = status.stdout.lines.count
      else
        log_failed_git("status", status)
        return metadata if status.timed_out?
      end

      commit = git_command("rev-parse", "--verify", "--short", "-q", "HEAD")
      if commit.success?
        metadata[:commit_hash] = presence(commit.stdout)
      elsif commit.exit_code == 1 && !commit.timed_out?
        # Exit 1 from --verify means the branch has no commit yet.
        metadata[:commit_hash] = nil
      else
        log_failed_git("rev-parse", commit)
        return metadata if commit.timed_out?
      end

      branch = git_command("branch", "--show-current")
      if branch.success?
        metadata[:branch] = presence(branch.stdout)
      else
        log_failed_git("branch", branch)
      end
      metadata
    rescue StandardError => e
      HQ.logger.warn("Project") { "Git metadata read failed for #{@key}: #{e.class} - #{e.message}; keeping cached values" }
      {}
    end

    def git_command(*args)
      CommandRunner.capture(["git", "-C", @path, *args], timeout: GIT_COMMAND_TIMEOUT)
    end

    def log_failed_git(command, result)
      reason = result.timed_out? ? "timed out after #{GIT_COMMAND_TIMEOUT}s" : "exited #{result.exit_code}"
      HQ.logger.warn("Project") { "Git #{command} #{reason} for #{@key}; keeping cached values" }
    end

    def presence(output)
      value = output.strip
      value.empty? ? nil : value
    end
  end
end
