# frozen_string_literal: true

require "json"
require "net/http"
require "open3"
require "securerandom"
require "time"
require "timeout"
require "uri"

require_relative "constants"
require_relative "executable_resolver"
require_relative "file_store"

module HQ
  class GitHubAuth
    STORE_VERSION = 1
    DEVICE_GRANT_TYPE = "urn:ietf:params:oauth:grant-type:device_code"
    DEFAULT_WEB_URL = "https://github.com"
    DEFAULT_API_URL = "https://api.github.com"
    REFRESH_GRANT_TYPE = "refresh_token"
    TOKEN_REFRESH_SKEW = 60

    class Error < StandardError
      attr_reader :status

      def initialize(message, status: 502)
        super(message)
        @status = status
      end
    end

    class Store
      def initialize(path = HQ::GITHUB_AUTH_FILE)
        @path = path
      end

      def session
        data.fetch("session", {})
      end

      def device
        data.fetch("device", {})
      end

      def save_session(value)
        mutate do |current|
          current["session"] = stringify(value)
          current.delete("device")
        end
      end

      def update_session
        result = nil
        mutate do |current|
          result = stringify(yield(current.fetch("session", {})))
          current["session"] = result
        end
        result
      end

      def save_device(value)
        mutate { |current| current["device"] = stringify(value) }
      end

      def clear_device
        mutate { |current| current.delete("device") }
      end

      def clear_session
        mutate { |current| current.delete("session") }
      end

      def clear
        mutate do |current|
          current.delete("session")
          current.delete("device")
        end
        FileUtils.rm_f(FileStore.backup_path(@path))
        true
      end

      private

      def data
        value = FileStore.read_json(@path, fallback: {})
        return default_data unless value.is_a?(Hash) && value["version"] == STORE_VERSION

        value
      end

      def default_data
        { "version" => STORE_VERSION }
      end

      def mutate
        FileUtils.mkdir_p(File.dirname(@path))
        File.open("#{@path}.lock", File::RDWR | File::CREAT, 0o600) do |lock|
          lock.flock(File::LOCK_EX)
          current = data
          yield current
          FileStore.write_json(@path, current, backup: false)
          File.chmod(0o600, @path)
        ensure
          lock.flock(File::LOCK_UN) rescue nil
        end
      end

      def stringify(value)
        case value
        when Hash then value.to_h { |key, item| [key.to_s, stringify(item)] }
        when Array then value.map { |item| stringify(item) }
        else value
        end
      end
    end

    class App
      attr_reader :client_id

      def initialize(client_id: HQ.env("GITHUB_APP_CLIENT_ID"),
                     app_slug: HQ.env("GITHUB_APP_SLUG"),
                     install_url: HQ.env("GITHUB_APP_INSTALL_URL"),
                     web_url: HQ.env("GITHUB_WEB_URL", DEFAULT_WEB_URL),
                     api_url: HQ.env("GITHUB_API_URL", DEFAULT_API_URL),
                     store: Store.new,
                     transport: nil,
                     now: -> { Time.now })
        @client_id = client_id.to_s.strip
        @app_slug = app_slug.to_s.strip
        @install_url = install_url.to_s.strip
        @web_url = normalize_url(web_url, DEFAULT_WEB_URL)
        @api_url = normalize_url(api_url, DEFAULT_API_URL)
        @store = store
        @transport = transport
        @now = now
      end

      def configured?
        !@client_id.empty?
      end

      def authenticated?
        return false unless configured?

        session = @store.session
        return false if session["access_token"].to_s.empty?
        return true unless access_expired?(session)

        refresh_usable?(session)
      end

      def access_token
        raise Error.new("Tycho GitHub App is not configured.", status: 424) unless configured?

        session = @store.session
        raise Error.new("GitHub login is required.", status: 401) if session["access_token"].to_s.empty?

        session = refresh_session(session) if access_expired?(session)
        session.fetch("access_token")
      end

      def capability
        session = @store.session
        {
          configured: configured?,
          authenticated: authenticated?,
          account: empty_to_nil(session["account"]),
          expires_at: empty_to_nil(session["expires_at"]),
          install_url: installation_url,
          device_flow: configured?
        }
      end

      def start_device_flow
        raise Error.new("Set TYCHO_GITHUB_APP_CLIENT_ID to enable GitHub login.", status: 424) unless configured?

        response = post_form(
          "#{@web_url}/login/device/code",
          { client_id: @client_id },
          accept: "application/json"
        )
        require_fields!(response, "device_code", "user_code", "verification_uri", "expires_in")
        verification_uri = safe_http_url(response.fetch("verification_uri"))
        raise Error.new("GitHub returned an invalid verification URL.", status: 502) unless verification_uri

        started_at = @now.call
        device = {
          "id" => SecureRandom.hex(16),
          "device_code" => response.fetch("device_code"),
          "user_code" => response.fetch("user_code"),
          "verification_uri" => verification_uri,
          "interval" => [response["interval"].to_i, 1].max,
          "expires_at" => (started_at + response.fetch("expires_in").to_i).iso8601,
          "last_polled_at" => nil
        }
        @store.save_device(device)
        public_device(device)
      end

      def poll_device_flow(id)
        device = @store.device
        raise Error.new("GitHub login request was not found.", status: 404) unless secure_equal?(device["id"], id)
        raise Error.new("GitHub login code expired. Start again.", status: 410) if expired_at?(device["expires_at"])

        retry_after = polling_retry_after(device)
        return public_device(device).merge(status: "pending", retry_after:) if retry_after.positive?

        device["last_polled_at"] = @now.call.iso8601
        @store.save_device(device)
        response = post_form(
          "#{@web_url}/login/oauth/access_token",
          {
            client_id: @client_id,
            device_code: device.fetch("device_code"),
            grant_type: DEVICE_GRANT_TYPE
          },
          accept: "application/json"
        )
        return handle_device_error(device, response) if response["error"]

        session = session_from_token_response(response)
        session["account"] = fetch_account(response.fetch("access_token"))
        @store.save_session(session)
        {
          status: "authenticated",
          account: session["account"],
          expires_at: session["expires_at"]
        }.compact
      end

      def logout
        @store.clear
        true
      end

      private

      def refresh_session(session)
        @store.update_session do |current|
          raise Error.new("GitHub login is required.", status: 401) if current["access_token"].to_s.empty?
          next current unless access_expired?(current)

          unless refresh_usable?(current)
            raise Error.new("GitHub login expired. Sign in again.", status: 401)
          end

          response = post_form(
            "#{@web_url}/login/oauth/access_token",
            {
              client_id: @client_id,
              grant_type: REFRESH_GRANT_TYPE,
              refresh_token: current.fetch("refresh_token")
            },
            accept: "application/json"
          )
          raise Error.new("GitHub login expired. Sign in again.", status: 401) if response["error"]

          session_from_token_response(response).merge("account" => current["account"])
        end
      rescue Error
        @store.clear_session
        raise
      end

      def session_from_token_response(response)
        token = response["access_token"].to_s
        raise Error.new("GitHub returned an invalid login response.", status: 502) if token.empty?

        now = @now.call
        {
          "access_token" => token,
          "token_type" => response["token_type"].to_s,
          "expires_at" => expires_at(now, response["expires_in"]),
          "refresh_token" => empty_to_nil(response["refresh_token"]),
          "refresh_token_expires_at" => expires_at(now, response["refresh_token_expires_in"]),
          "created_at" => now.iso8601
        }.compact
      end

      def fetch_account(token)
        response = request_json(
          :get,
          "#{@api_url}/user",
          headers: {
            "Accept" => "application/vnd.github+json",
            "Authorization" => "Bearer #{token}",
            "X-GitHub-Api-Version" => "2026-03-10",
            "User-Agent" => "Tycho"
          }
        )
        response["login"].to_s
      rescue Error
        ""
      end

      def handle_device_error(device, response)
        case response["error"]
        when "authorization_pending"
          public_device(device).merge(status: "pending", retry_after: device["interval"])
        when "slow_down"
          device["interval"] = device["interval"].to_i + 5
          @store.save_device(device)
          public_device(device).merge(status: "pending", retry_after: device["interval"])
        when "expired_token"
          @store.clear_device
          raise Error.new("GitHub login code expired. Start again.", status: 410)
        when "access_denied"
          @store.clear_device
          raise Error.new("GitHub login was cancelled.", status: 403)
        when "device_flow_disabled"
          raise Error.new("Device flow is disabled for the Tycho GitHub App.", status: 424)
        else
          raise Error.new("GitHub login failed: #{sanitize(response["error_description"] || response["error"])}", status: 502)
        end
      end

      def public_device(device)
        {
          id: device["id"],
          user_code: device["user_code"],
          verification_uri: device["verification_uri"],
          interval: device["interval"],
          expires_at: device["expires_at"]
        }
      end

      def post_form(url, payload, accept:)
        request_json(
          :post,
          url,
          headers: {
            "Accept" => accept,
            "Content-Type" => "application/x-www-form-urlencoded",
            "User-Agent" => "Tycho"
          },
          body: URI.encode_www_form(payload)
        )
      end

      def request_json(method, url, headers:, body: nil)
        raw = if @transport
                @transport.call(method, URI(url), headers, body)
              else
                http_request(method, URI(url), headers, body)
              end
        status = raw.code.to_i
        parsed = JSON.parse(raw.body.to_s)
        unless status.between?(200, 299)
          message = parsed["error_description"] || parsed["message"] || "request failed"
          raise Error.new("GitHub login failed: #{sanitize(message)}", status: status)
        end
        parsed
      rescue JSON::ParserError
        raise Error.new("GitHub returned an invalid login response.", status: 502)
      rescue Timeout::Error, Net::OpenTimeout, Net::ReadTimeout
        raise Error.new("GitHub login request timed out.", status: 504)
      rescue SocketError, SystemCallError, IOError => e
        raise Error.new("GitHub login request failed: #{sanitize(e.message)}", status: 502)
      end

      def http_request(method, uri, headers, body)
        request_class = method == :post ? Net::HTTP::Post : Net::HTTP::Get
        request = request_class.new(uri)
        headers.each { |key, value| request[key] = value }
        request.body = body if body
        Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https",
                       open_timeout: 5, read_timeout: 15, write_timeout: 5) do |http|
          http.request(request)
        end
      end

      def installation_url
        return safe_http_url(@install_url) unless @install_url.empty?
        return nil unless @app_slug.match?(/\A[A-Za-z0-9-]+\z/)

        "#{@web_url}/apps/#{@app_slug}/installations/new"
      end

      def safe_http_url(value)
        uri = URI.parse(value.to_s)
        return nil unless %w[http https].include?(uri.scheme) && uri.host && uri.userinfo.to_s.empty?

        uri.to_s
      rescue URI::InvalidURIError
        nil
      end

      def access_expired?(session)
        expires_at = session["expires_at"].to_s
        return false if expires_at.empty?

        Time.parse(expires_at) <= @now.call + TOKEN_REFRESH_SKEW
      rescue ArgumentError
        true
      end

      def refresh_usable?(session)
        token = session["refresh_token"].to_s
        return false if token.empty?

        expires_at = session["refresh_token_expires_at"].to_s
        return true if expires_at.empty?

        Time.parse(expires_at) > @now.call + TOKEN_REFRESH_SKEW
      rescue ArgumentError
        false
      end

      def expired_at?(value)
        Time.parse(value.to_s) <= @now.call
      rescue ArgumentError
        true
      end

      def polling_retry_after(device)
        last = device["last_polled_at"].to_s
        return 0 if last.empty?

        remaining = device["interval"].to_i - (@now.call - Time.parse(last))
        [remaining.ceil, 0].max
      rescue ArgumentError
        0
      end

      def expires_at(now, seconds)
        value = seconds.to_i
        value.positive? ? (now + value).iso8601 : nil
      end

      def require_fields!(response, *fields)
        return if fields.all? { |field| !response[field].to_s.empty? }

        raise Error.new("GitHub returned an invalid device login response.", status: 502)
      end

      def normalize_url(value, fallback)
        text = value.to_s.strip
        text = fallback if text.empty?
        uri = URI.parse(text)
        raise ArgumentError, "Invalid GitHub URL" unless %w[http https].include?(uri.scheme) && uri.host

        text.sub(%r{/+\z}, "")
      end

      def secure_equal?(left, right)
        left = left.to_s
        right = right.to_s
        return false if left.empty? || left.bytesize != right.bytesize

        left.bytes.zip(right.bytes).reduce(0) { |memo, (a, b)| memo | (a ^ b) }.zero?
      end

      def empty_to_nil(value)
        text = value.to_s
        text.empty? ? nil : text
      end

      def sanitize(value)
        value.to_s
             .gsub(/github_pat_[A-Za-z0-9_]+|gh[pousr]_[A-Za-z0-9_]+/i, "[REDACTED]")
             .gsub(/Bearer\s+\S+/i, "Bearer [REDACTED]")
             .slice(0, 300)
      end
    end

    class CLI
      CACHE_TTL = 30

      def initialize(resolution: ExecutableResolver.resolve_tool("gh"), runner: Open3, timeout: 5,
                     now: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) })
        @resolution = resolution
        @runner = runner
        @timeout = timeout
        @now = now
      end

      def available?
        @resolution.available?
      end

      def authenticated?
        !token.to_s.empty?
      end

      def token
        now = @now.call
        return @token if defined?(@token_checked_at) && now - @token_checked_at < CACHE_TTL

        @token_checked_at = now
        return @token = nil unless available?

        stdout, _stderr, status = Timeout.timeout(@timeout) do
          @runner.capture3(@resolution.command, "auth", "token")
        end
        @token = status.success? ? stdout.to_s.strip : nil
        @token = nil if @token.to_s.empty? || @token.to_s.bytesize > 4_096
        @token
      rescue Timeout::Error, SystemCallError
        @token = nil
      end

      def capability
        {
          available: available?,
          authenticated: authenticated?
        }
      end
    end

    def initialize(app: App.new, cli: CLI.new)
      @app = app
      @cli = cli
    end

    class << self
      def default
        @default ||= new
      end
    end

    def enabled?
      @app.authenticated? || @cli.authenticated?
    end

    def source
      return "github_app" if @app.authenticated?
      return "gh" if @cli.authenticated?

      "none"
    end

    def access_token
      return @app.access_token if @app.authenticated?

      token = @cli.token
      return token unless token.to_s.empty?

      raise Error.new("Connect the Tycho GitHub App or run `gh auth login`.", status: 424)
    end

    def capability(api_url: DEFAULT_API_URL)
      {
        enabled: enabled?,
        available: @app.configured? || @cli.available?,
        source: source,
        api_url: api_url,
        app: @app.capability,
        gh: @cli.capability
      }
    end

    def start_device_flow
      @app.start_device_flow
    end

    def poll_device_flow(id)
      @app.poll_device_flow(id)
    end

    def logout
      @app.logout
      capability
    end
  end
end
