# frozen_string_literal: true

require "json"
require "net/http"
require "timeout"
require "uri"

require_relative "github_auth"

module HQ
  class GitHubAPIClient
    API_VERSION = "2026-03-10"
    DEFAULT_BASE_URL = "https://api.github.com"
    DEFAULT_OPEN_TIMEOUT = 5
    DEFAULT_READ_TIMEOUT = 15
    DEFAULT_WRITE_TIMEOUT = 5
    DEFAULT_MAX_BYTES = 8 * 1024 * 1024
    USER_AGENT = "Tycho/#{defined?(HQ::VERSION) ? HQ::VERSION : "development"}"
    DEFAULT_CREDENTIAL = Object.new.freeze

    class Error < StandardError
      attr_reader :status, :rate_limit

      def initialize(message, status: 502, rate_limit: nil)
        super(message)
        @status = status
        @rate_limit = rate_limit
      end
    end

    class DisabledError < Error
      def initialize(message = "Connect the Tycho GitHub App or run `gh auth login`.")
        super(message, status: 424)
      end
    end

    Response = Struct.new(:status, :body, :headers, :etag, :rate_limit, :not_modified, keyword_init: true)

    attr_reader :base_url

    def initialize(token: DEFAULT_CREDENTIAL, credential: GitHubAuth.default,
                   base_url: HQ.env("GITHUB_API_URL"),
                   open_timeout: DEFAULT_OPEN_TIMEOUT, read_timeout: DEFAULT_READ_TIMEOUT,
                   write_timeout: DEFAULT_WRITE_TIMEOUT, max_bytes: DEFAULT_MAX_BYTES,
                   transport: nil)
      @token = token.equal?(DEFAULT_CREDENTIAL) ? nil : token.to_s.strip
      @explicit_token = !token.equal?(DEFAULT_CREDENTIAL)
      @credential = credential
      @base_url = normalize_base_url(base_url)
      @open_timeout = open_timeout
      @read_timeout = read_timeout
      @write_timeout = write_timeout
      @max_bytes = max_bytes
      @transport = transport
    end

    def enabled?
      @explicit_token ? !@token.empty? : @credential.enabled?
    end

    def capability
      return { enabled: enabled?, available: enabled?, source: "explicit", api_url: @base_url } if @explicit_token

      @credential.capability(api_url: @base_url)
    end

    def start_device_flow
      @credential.start_device_flow
    rescue GitHubAuth::Error => e
      raise Error.new(e.message, status: e.status)
    end

    def poll_device_flow(id)
      @credential.poll_device_flow(id)
    rescue GitHubAuth::Error => e
      raise Error.new(e.message, status: e.status)
    end

    def logout
      @credential.logout
    rescue GitHubAuth::Error => e
      raise Error.new(e.message, status: e.status)
    end

    def get_json(path, params: nil, etag: nil, max_bytes: @max_bytes)
      response = request(:get, path, params:, accept: "application/vnd.github+json", etag:, max_bytes:)
      return response if response.not_modified

      response.body = JSON.parse(response.body)
      response
    rescue JSON::ParserError
      raise Error.new("GitHub returned invalid JSON.", status: 502)
    end

    def get_text(path, accept:, etag: nil, max_bytes: @max_bytes)
      request(:get, path, accept:, etag:, max_bytes:)
    end

    def post_json(path, payload, idempotency_key: nil, max_bytes: @max_bytes)
      response = request(:post, path, accept: "application/vnd.github+json", payload:, idempotency_key:, max_bytes:)
      response.body = JSON.parse(response.body)
      response
    rescue JSON::ParserError
      raise Error.new("GitHub returned invalid JSON.", status: 502)
    end

    def paginate(path, params: nil, per_page: 100, max_pages: 10)
      items = []
      page = 1
      rate_limit = nil
      loop do
        response = get_json(path, params: (params || {}).merge(per_page: per_page, page: page))
        value = response.body
        raise Error.new("GitHub returned an unexpected paginated response.", status: 502) unless value.is_a?(Array)

        items.concat(value)
        rate_limit = response.rate_limit
        break if value.length < per_page || page >= max_pages

        page += 1
      end
      [items, rate_limit]
    end

    private

    def request(method, path, params: nil, accept:, payload: nil, etag: nil, idempotency_key: nil,
                max_bytes: @max_bytes)
      raise DisabledError unless enabled?

      uri = build_uri(path, params)
      token = access_token
      headers = {
        "Accept" => accept,
        "Authorization" => "Bearer #{token}",
        "X-GitHub-Api-Version" => API_VERSION,
        "User-Agent" => USER_AGENT
      }
      headers["If-None-Match"] = etag unless etag.to_s.empty?
      headers["X-GitHub-Idempotency-Key"] = idempotency_key unless idempotency_key.to_s.empty?
      headers["Content-Type"] = "application/json" if payload
      raw = @transport ? @transport.call(method, uri, headers, payload) : http_request(method, uri, headers, payload)
      normalize_response(raw, max_bytes:)
    rescue DisabledError, Error
      raise
    rescue GitHubAuth::Error => e
      raise Error.new(e.message, status: e.status)
    rescue Timeout::Error, Net::OpenTimeout, Net::ReadTimeout
      raise Error.new("GitHub API request timed out.", status: 504)
    rescue SocketError, SystemCallError, IOError => e
      raise Error.new("GitHub API request failed: #{sanitize(e.message)}", status: 502)
    end

    def http_request(method, uri, headers, payload)
      request_class = method == :post ? Net::HTTP::Post : Net::HTTP::Get
      request = request_class.new(uri)
      headers.each { |key, value| request[key] = value }
      request.body = JSON.generate(payload) if payload
      Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https",
                     open_timeout: @open_timeout, read_timeout: @read_timeout,
                     write_timeout: @write_timeout) do |http|
        http.request(request)
      end
    end

    def normalize_response(raw, max_bytes:)
      status = raw.code.to_i
      headers = raw.each_header.to_h
      rate_limit = rate_limit_payload(headers)
      return Response.new(status:, body: "", headers:, etag: headers["etag"], rate_limit:, not_modified: true) if status == 304

      body = raw.body.to_s
      if body.bytesize > max_bytes
        raise Error.new("GitHub response exceeded #{max_bytes} bytes.", status: 413, rate_limit:)
      end
      unless status.between?(200, 299)
        raise Error.new(error_message(status, body), status: mapped_status(status), rate_limit:)
      end

      Response.new(status:, body: utf8(body), headers:, etag: headers["etag"], rate_limit:, not_modified: false)
    end

    def error_message(status, body)
      parsed = JSON.parse(utf8(body))
      message = parsed["message"].to_s
      message = "request failed" if message.empty?
      "GitHub API #{status}: #{sanitize(message)}"
    rescue JSON::ParserError
      "GitHub API #{status}: request failed"
    end

    def mapped_status(status)
      return 401 if status == 401
      return 403 if status == 403
      return 404 if status == 404
      return 422 if status == 422
      return 429 if status == 429

      502
    end

    def rate_limit_payload(headers)
      {
        limit: integer_or_nil(headers["x-ratelimit-limit"]),
        remaining: integer_or_nil(headers["x-ratelimit-remaining"]),
        used: integer_or_nil(headers["x-ratelimit-used"]),
        reset_at: integer_or_nil(headers["x-ratelimit-reset"]),
        resource: empty_to_nil(headers["x-ratelimit-resource"]),
        retry_after: integer_or_nil(headers["retry-after"])
      }.compact
    end

    def build_uri(path, params)
      uri = URI.join("#{@base_url}/", path.to_s.sub(%r{\A/+}, ""))
      raise Error.new("Unsupported GitHub API URL.", status: 400) unless %w[http https].include?(uri.scheme)

      uri.query = URI.encode_www_form(params) if params && !params.empty?
      uri
    end

    def normalize_base_url(value)
      text = value.to_s.strip
      text = DEFAULT_BASE_URL if text.empty?
      uri = URI.parse(text)
      unless %w[http https].include?(uri.scheme) && uri.host && uri.userinfo.to_s.empty?
        raise ArgumentError, "Invalid GitHub API URL"
      end

      text.sub(%r{/+\z}, "")
    end

    def access_token
      return @token if @explicit_token

      @credential.access_token
    rescue GitHubAuth::Error => e
      raise DisabledError, e.message if e.status == 424

      raise Error.new(e.message, status: e.status)
    end

    def utf8(value)
      value.to_s.dup.force_encoding(Encoding::UTF_8).scrub
    end

    def sanitize(value)
      value.to_s
           .gsub(/github_pat_[A-Za-z0-9_]+|gh[pousr]_[A-Za-z0-9_]+/i, "[REDACTED]")
           .gsub(/Bearer\s+\S+/i, "Bearer [REDACTED]")
           .slice(0, 300)
    end

    def integer_or_nil(value)
      Integer(value, exception: false)
    end

    def empty_to_nil(value)
      text = value.to_s
      text.empty? ? nil : text
    end
  end
end
