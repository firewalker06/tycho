# frozen_string_literal: true

require "json"
require "net/http"
require "uri"

module HQ
  class RemoteServerControl
    DEFAULT_URL = "http://127.0.0.1:7373"

    def initialize(url: ENV.fetch("TYCHO_REMOTE_URL", DEFAULT_URL), token: ENV["TYCHO_REMOTE_TOKEN"], requester: nil)
      @url = url.to_s
      @token = token.to_s
      @requester = requester || method(:request_restart)
    end

    def restart!
      response = @requester.call(@url, @token)
      return unavailable("No running Remote server responded at #{@url}") unless response[:status].to_i.between?(200, 299)
      return unavailable("Remote server at #{@url} did not accept a restart") unless response.dig(:body, :restarting) || response.dig(:body, "restarting")

      { restarted: true, detail: "Remote server restart requested" }
    rescue SystemCallError, IOError, SocketError, URI::InvalidURIError, JSON::ParserError
      unavailable("No running Remote server responded at #{@url}")
    end

    private

    def request_restart(url, token)
      uri = URI.join(url.end_with?("/") ? url : "#{url}/", "server/restart")
      request = Net::HTTP::Post.new(uri)
      request["Accept"] = "application/json"
      request["Authorization"] = "Bearer #{token}" unless token.empty?
      request["Content-Type"] = "application/json"
      request.body = "{}"
      response = Net::HTTP.start(uri.hostname, uri.port, use_ssl: uri.scheme == "https") { |http| http.request(request) }
      { status: response.code.to_i, body: JSON.parse(response.body.to_s) }
    end

    def unavailable(detail)
      { restarted: false, detail: detail }
    end
  end
end
