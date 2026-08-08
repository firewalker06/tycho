# frozen_string_literal: true

require "json"
require "net/http"
require "openssl"
require "socket"
require "uri"

module HQ
  class RemoteCLIClient
    DEFAULT_OPEN_TIMEOUT = 5
    DEFAULT_READ_TIMEOUT = 30

    class Error < StandardError
      attr_reader :kind, :status

      def initialize(message, kind:, status: nil)
        super(message)
        @kind = kind
        @status = status
      end
    end

    def self.from_registry(server_key, registry:, **options)
      key = server_key.to_s.strip
      config = Array(registry.remote_servers).find { |candidate| candidate.key == key }
      raise Error.new("Unknown remote server: #{key}", kind: :unknown_server) unless config

      new(config, **options)
    end

    attr_reader :server_key

    def initialize(config, open_timeout: DEFAULT_OPEN_TIMEOUT, read_timeout: DEFAULT_READ_TIMEOUT)
      @server_key = config.key
      @base_uri = URI.parse(config.url)
      @token = config.resolved_token.to_s
      @open_timeout = open_timeout
      @read_timeout = read_timeout
    end

    def request(method, path, body: nil)
      uri = target_uri(path)
      response = perform_request(method, uri, body)
      parse_response(response)
    rescue Net::OpenTimeout, Net::ReadTimeout
      raise Error.new("Remote server #{server_key} timed out", kind: :timeout)
    rescue SystemCallError, IOError, SocketError, OpenSSL::SSL::SSLError => e
      raise Error.new("Remote server #{server_key} is unreachable: #{e.message}", kind: :unreachable)
    end

    private

    def target_uri(path)
      suffix = path.to_s
      suffix = "/#{suffix}" unless suffix.start_with?("/")
      uri = @base_uri.dup
      uri.path = "#{@base_uri.path.to_s.sub(%r{/+\z}, "")}#{suffix}"
      uri.query = nil
      uri.fragment = nil
      uri
    end

    def perform_request(method, uri, body)
      request_class = {
        "GET" => Net::HTTP::Get,
        "POST" => Net::HTTP::Post,
        "DELETE" => Net::HTTP::Delete
      }.fetch(method.to_s.upcase) do
        raise Error.new("Unsupported remote operation: #{method}", kind: :unsupported)
      end
      request = request_class.new(uri)
      request["Accept"] = "application/json"
      request["Authorization"] = "Bearer #{@token}" unless @token.empty?
      if request.request_body_permitted?
        request["Content-Type"] = "application/json"
        request.body = JSON.generate(body || {})
      end

      Net::HTTP.start(
        uri.hostname,
        uri.port,
        use_ssl: uri.scheme == "https",
        open_timeout: @open_timeout,
        read_timeout: @read_timeout
      ) { |http| http.request(request) }
    end

    def parse_response(response)
      status = response.code.to_i
      payload = parse_json(response.body)
      return payload if status.between?(200, 299)

      message = error_message(payload, response)
      if status == 401 || status == 403
        raise Error.new("Remote server #{server_key} authentication failed", kind: :authentication, status: status)
      end
      if status == 404 && message == "Not found"
        raise Error.new("Remote server #{server_key} does not support this operation", kind: :unsupported, status: status)
      end

      raise Error.new(
        "Remote server #{server_key} API error (HTTP #{status}): #{redact_token(message)}",
        kind: :api,
        status: status
      )
    rescue JSON::ParserError
      raise Error.new("Remote server #{server_key} returned invalid JSON", kind: :api, status: status)
    end

    def parse_json(body)
      value = JSON.parse(body.to_s)
      value.is_a?(Hash) ? value : { "data" => value }
    end

    def error_message(payload, response)
      message = payload["error"].to_s.strip
      message = response.message.to_s if message.empty?
      message
    end

    def redact_token(value)
      return value.to_s if @token.empty?

      value.to_s.gsub(@token, "[REDACTED]")
    end
  end
end
