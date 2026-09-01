# frozen_string_literal: true

require "json"
require "net/http"
require "uri"
require "fileutils"
require "ipaddr"
require "socket"

require_relative "constants"

module HQ
  class RemoteServerControl
    def initialize(record_path: REMOTE_CONTROL_FILE, token: ENV["TYCHO_REMOTE_TOKEN"], requester: nil,
                   local_addresses: nil, interfaces: nil)
      @record_path = record_path
      @token = token.to_s
      @requester = requester || method(:request_restart)
      @local_addresses = local_addresses || method(:local_addresses)
      @interfaces = interfaces || Socket.method(:getifaddrs)
    end

    def self.publish(host:, port:, path: REMOTE_CONTROL_FILE)
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, "#{JSON.generate(host: host.to_s, port: port.to_i)}\n")
      File.chmod(0o600, path)
    end

    def self.clear(host: nil, port: nil, path: REMOTE_CONTROL_FILE)
      if host || port
        record = JSON.parse(File.read(path))
        return unless record["host"].to_s == host.to_s && record["port"].to_i == port.to_i
      end

      File.delete(path) if File.exist?(path)
    rescue SystemCallError, JSON::ParserError
      nil
    end

    def restart!
      url = local_url
      return unavailable("No local Remote server control record is available") unless url

      response = @requester.call(url, @token)
      return unavailable("No running local Remote server responded at #{url}") unless response[:status].to_i.between?(200, 299)
      return unavailable("Local Remote server at #{url} did not accept a restart") unless response.dig(:body, :restarting) || response.dig(:body, "restarting")

      { restarted: true, detail: "Remote server restart requested" }
    rescue SystemCallError, IOError, SocketError, URI::InvalidURIError, JSON::ParserError
      unavailable("No running local Remote server responded")
    end

    private

    def local_url
      record = JSON.parse(File.read(@record_path))
      host = record.fetch("host").to_s
      port = Integer(record.fetch("port"))
      return unless local_host?(host) && port.between?(1, 65_535)

      "http://#{host.include?(":") ? "[#{host}]" : host}:#{port}"
    rescue Errno::ENOENT, JSON::ParserError, KeyError, ArgumentError, TypeError
      nil
    end

    def local_host?(host)
      value = host.to_s.downcase
      return true if value == "localhost" || value == "::1" || value.start_with?("127.")

      ip = IPAddr.new(value)
      Array(@local_addresses.call).any? { |address| IPAddr.new(address.to_s) == ip }
    rescue IPAddr::InvalidAddressError
      false
    end

    def local_addresses
      Array(@interfaces.call).filter_map do |interface|
        address = interface.addr
        address.ip_address if address.respond_to?(:ip_address)
      rescue SocketError
        nil
      end
    rescue SocketError
      []
    end

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
