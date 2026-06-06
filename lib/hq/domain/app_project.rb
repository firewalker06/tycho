# frozen_string_literal: true

require_relative "constants"
require_relative "log_paths"

module HQ
  class AppProject
    DEPLOY_CONFIG_ENV_MUTEX = Mutex.new

    attr_reader :config, :key, :name, :path, :service, :image, :hosts, :proxy_host,
                :healthcheck_path, :kamal_version, :rails_version, :health_status,
                :app_status, :response_time, :commit_hash, :branch, :dirty_files, :group

    def initialize(config)
      @config = config
      @key = config.key
      @name = config.name
      @group = config.group.to_s
      @path = config.path
      @health_status = "pending"
      @app_status = "pending"
      @response_time = nil
      @commit_hash = nil
      @dirty_files = 0
    end

    def apps_enabled?
      @config.apps
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
      parse_deploy_config if apps_enabled?
      parse_versions
      parse_git_status
    end

    def check_health!
      return unless apps_enabled?

      target = healthcheck_target
      unless target
        @response_time = nil
        @health_status = "not checked"
        @app_status = "unknown"
        return
      end

      http = Net::HTTP.new(target.host, target.port)
      http.use_ssl = target.scheme == "https"
      http.open_timeout = 2
      http.read_timeout = 3
      http.keep_alive_timeout = 5

      hc_response = nil
      http.start do |conn|
        start_time = Time.now
        hc_response = conn.head(target.healthcheck_path)
        @response_time = ((Time.now - start_time) * 1000).round

        if hc_response.code.to_s == "503"
          @health_status = "maintenance"
          @app_status = "maintenance"
          next
        end

        @health_status = hc_response.code.start_with?("2", "3") ? "healthy" : "unhealthy (#{hc_response.code})"

        app_response = conn.head(target.root_path)
        @app_status = case app_response.code
                      when /^2/, /^3/ then "running"
                      when "503" then "maintenance"
                      when /^4/ then "error (#{app_response.code})"
                      when /^5/ then "down (#{app_response.code})"
                      else "unknown (#{app_response.code})"
                      end

        @health_status = "maintenance" if @app_status == "maintenance"
      end
    rescue OpenSSL::SSL::SSLError, Errno::ECONNREFUSED => e
      @response_time = nil
      @health_status = "down"
      @app_status = "stopped"
      HQ.logger.warn("Health") { "#{@name}: #{e.class}" }
    rescue Net::OpenTimeout, Net::ReadTimeout => e
      @response_time = nil
      @health_status = "timeout"
      @app_status = "unreachable"
      HQ.logger.warn("Health") { "#{@name}: #{e.class}" }
    rescue StandardError => e
      @response_time = nil
      @health_status = "error: #{e.message.slice(0, 40)}"
      @app_status = "error"
      HQ.logger.warn("Health") { "#{@name}: #{e.class} - #{e.message}" }
    ensure
      log_healthcheck(hc_response&.code)
    end

    def action_log_path
      LogPaths.project_action_log_path(@key)
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

    HealthcheckTarget = Struct.new(:scheme, :host, :port, :healthcheck_path, :root_path, keyword_init: true)

    def healthcheck_target
      if @proxy_host
        uri = normalize_health_uri(@proxy_host, default_scheme: "https", default_path: @healthcheck_path || "/up")
        return nil unless uri&.host

        return HealthcheckTarget.new(
          scheme: uri.scheme,
          host: uri.host,
          port: uri.port,
          healthcheck_path: uri.path.to_s.empty? ? (@healthcheck_path || "/up") : uri.path,
          root_path: "/"
        )
      end

      nil
    rescue URI::InvalidURIError
      nil
    end

    def normalize_health_uri(value, default_scheme:, default_path:)
      raw = value.to_s.strip
      raw = "#{default_scheme}://#{raw}" unless raw.match?(%r{\A[a-z][a-z0-9+\-.]*://}i)
      uri = URI(raw)
      return uri unless uri.path.to_s.empty?

      URI("#{uri.scheme}://#{uri.host}:#{uri.port}#{default_path}")
    end

    def unique_archive_destination(root, now)
      LogPaths.project_archive_destination(root, archive_name, now:)
    end

    def archive_name
      slug = @name.to_s.downcase.gsub(/[^a-z0-9]+/, "-").gsub(/\A-+|-+\z/, "")
      slug.empty? ? @key : slug
    end

    def log_healthcheck(code)
      log_path = LogPaths.project_healthcheck_log_path
      now = Time.now
      date_str = now.strftime("%Y-%m-%d")
      timestamp = now.strftime("%Y-%m-%d %H:%M:%S")
      latency = @response_time ? "#{@response_time}ms" : "n/a"

      File.open(log_path, "a") do |file|
        @last_healthcheck_date ||= nil
        if @last_healthcheck_date != date_str
          file.puts
          file.puts "=== #{date_str} ==="
          file.puts
          @last_healthcheck_date = date_str
        end
        file.puts "[#{timestamp}] #{@name} code=#{code} health=#{@health_status} status=#{@app_status} latency=#{latency}"
      end
    rescue StandardError
      nil
    end

    def parse_deploy_config
      config_path = File.join(@path, "config", "deploy.yml")
      return unless File.exist?(config_path)

      raw = File.read(config_path)
      rendered = render_deploy_config(raw)
      config = YAML.safe_load(rendered, permitted_classes: [Symbol])

      @service = config["service"]
      @image = config["image"]
      @hosts = extract_hosts(config)
      @proxy_host = config.dig("proxy", "host")
      @healthcheck_path = config.dig("proxy", "healthcheck", "path") || "/up"
    rescue StandardError => e
      HQ.logger.warn("Project") { "Deploy config parse failed for #{@key}: #{e.class}: #{e.message}" }
      @service = nil
      @image = nil
      @hosts = []
      @proxy_host = nil
      @healthcheck_path = nil
    end

    def render_deploy_config(raw)
      old_env = {}
      DEPLOY_CONFIG_ENV_MUTEX.synchronize do
        begin
          load_dotenv.each do |key, value|
            next if ENV.key?(key)

            old_env[key] = nil
            ENV[key] = value
          end

          ERB.new(raw).result(binding)
        ensure
          old_env.each_key { |key| ENV.delete(key) }
        end
      end
    end

    def extract_hosts(config)
      hosts = []
      servers = config["servers"]
      return hosts unless servers

      if servers.is_a?(Array)
        hosts.concat(servers)
      elsif servers.is_a?(Hash)
        servers.each_value do |role_config|
          if role_config.is_a?(Hash) && role_config["hosts"]
            Array(role_config["hosts"]).each { |host| hosts << host unless host.to_s.empty? }
          elsif role_config.is_a?(Array)
            role_config.each { |host| hosts << host unless host.to_s.empty? }
          end
        end
      end

      hosts.uniq
    end

    def load_dotenv
      dotenv_path = File.join(@path, ".env")
      return {} unless File.exist?(dotenv_path)

      File.readlines(dotenv_path).each_with_object({}) do |line, vars|
        stripped = line.strip
        next if stripped.empty? || stripped.start_with?("#")

        key, value = stripped.split("=", 2)
        next unless key && value

        vars[key.strip] = value.strip.gsub(/\A["']|["']\z/, "")
      end
    end

    def parse_versions
      lockfile = File.join(@path, "Gemfile.lock")
      return unless File.exist?(lockfile)

      content = File.read(lockfile)
      @kamal_version = content[/^\s*kamal \((.+)\)/, 1]
      @rails_version = content[/^\s*rails \((.+)\)/, 1]
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
