# frozen_string_literal: true

require_relative "constants"
require_relative "executable_resolver"
require_relative "log_paths"
require_relative "process_liveness"

module HQ
  class KamalAction
    attr_reader :project_key, :project_name, :action, :log_path, :started_at, :pid

    def initialize(project_key:, project_name:, project_path:, action:, pid: nil, started_at: nil)
      @project_key = project_key
      @project_name = project_name
      @project_path = project_path
      @action = action
      @started_at = started_at || Time.now
      @log_path = LogPaths.project_action_log_path(@project_key)
      @status_path = "#{@log_path}.status"
      @pid = pid
      @done = false
      @success = nil
    end

    def self.from_hash(hash)
      new(
        project_key: hash["project_key"],
        project_name: hash["project_name"],
        project_path: hash["project_path"],
        action: hash["action"].to_sym,
        pid: hash["pid"],
        started_at: Time.parse(hash["started_at"])
      )
    end

    def to_hash
      {
        "project_key" => @project_key,
        "project_name" => @project_name,
        "project_path" => @project_path,
        "action" => @action.to_s,
        "pid" => @pid,
        "started_at" => @started_at.iso8601
      }
    end

    def start!
      args = {
        deploy: ["deploy"],
        maintenance: %w[app maintenance],
        live: %w[app live]
      }[@action]

      bin_kamal = File.join(@project_path, "bin", "kamal")
      mise = mise_executable
      command = if File.executable?(bin_kamal)
                  [mise, "exec", "--", bin_kamal, *args]
                else
                  [mise, "exec", "--", "bundle", "exec", "kamal", *args]
                end

      FileUtils.mkdir_p(File.dirname(@log_path))
      FileUtils.rm_f(@status_path)
      File.open(@log_path, "a") do |file|
        file.puts
        file.puts "=== [#{@started_at.strftime("%Y-%m-%d %H:%M:%S")}] #{@action} ==="
        file.puts
      end

      log_file = File.open(@log_path, "a")
      @pid = spawn(
        RbConfig.ruby,
        "-e",
        action_runner_script,
        @status_path,
        @project_path,
        @log_path,
        *command,
        out: log_file,
        err: %i[child out],
        pgroup: true
      )
      log_file.close
      Process.detach(@pid)
      HQ.logger.info("KamalAction") { "Started #{@action} for #{@project_name} (pid=#{@pid})" }
    end

    def poll!
      return if @done
      return if ProcessLiveness.alive?(@pid)

      @done = true
      @success = action_exit_success? && !action_log_failure?
      HQ.logger.info("KamalAction") { "#{@action} finished for #{@project_name} (success=#{@success})" }
    end

    def done?
      @done
    end

    def success?
      @success
    end

    def label
      self.class.label_for(@action)
    end

    def self.label_for(action)
      {
        deploy: "deploying",
        maintenance: "going maintenance",
        live: "going live"
      }[action.to_sym]
    end

    def self.project_ready?(project_path)
      !project_readiness_source(project_path).to_s.empty?
    end

    def self.project_readiness_source(project_path)
      path = project_path.to_s
      return nil if path.empty?

      binstub = File.join(path, "bin", "kamal")
      return "bin/kamal" if File.executable?(binstub)

      lockfile = File.join(path, "Gemfile.lock")
      return "Gemfile.lock" if File.file?(lockfile) && File.read(lockfile).match?(/^    kamal \(/)

      gemfile = File.join(path, "Gemfile")
      return "Gemfile" if File.file?(gemfile) && File.read(gemfile).match?(/gem ["']kamal["']/)

      nil
    rescue StandardError
      nil
    end

    private

    def mise_executable
      ExecutableResolver.command_for_tool("mise")
    end

    def action_exit_success?
      return true unless File.exist?(@status_path)

      File.read(@status_path).to_i.zero?
    rescue StandardError
      false
    end

    def action_log_failure?
      section = current_log_section
      return false if section.empty?

      section.match?(/\bERROR\b|\bexit status:\s*[1-9]\d*\b|failed to/i)
    rescue StandardError
      false
    end

    def current_log_section
      return "" unless File.exist?(@log_path)

      marker = "=== [#{@started_at.strftime("%Y-%m-%d %H:%M:%S")}] #{@action} ==="
      content = File.read(@log_path)
      index = content.rindex(marker)
      return "" unless index

      content[index..]
    end

    def action_runner_script
      <<~RUBY
        status_path = ARGV.shift
        project_path = ARGV.shift
        log_path = ARGV.shift
        command = ARGV
        exit_status = 1

        Dir.chdir(project_path)
        File.open(log_path, "a") do |log|
          pid = spawn(*command, out: log, err: [:child, :out], pgroup: true)
          _, status = Process.wait2(pid)
          exit_status = status.exitstatus || 1
        end
        File.write(status_path, exit_status.to_s)
        exit(exit_status)
      RUBY
    end
  end
end
