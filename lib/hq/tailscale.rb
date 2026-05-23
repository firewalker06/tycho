# frozen_string_literal: true

require "json"

module HQ
  module Tailscale
    SelfInfo = Struct.new(:ip, :dns_name, :host_name, :https_dns_name, keyword_init: true) do
      def magic_dns_url(port:, path: "/")
        return nil if dns_name.to_s.empty?

        "http://#{dns_name}:#{port}#{path}"
      end

      def https_capable?
        !https_dns_name.to_s.empty?
      end

      def https_url(port: 443, path: "/")
        return nil unless https_capable?

        port_part = port.to_i == 443 ? "" : ":#{port}"
        "https://#{https_dns_name}#{port_part}#{path}"
      end

      def ip_url(port:, path: "/")
        return nil if ip.to_s.empty?

        "http://#{ip}:#{port}#{path}"
      end
    end

    module_function

    def detect
      command = HQ.env_present("TAILSCALE_BIN", "tailscale")
      output = IO.popen([command, "status", "--self", "--json"], err: File::NULL, &:read)
      parse_self_status(output)
    rescue Errno::ENOENT, SystemCallError, JSON::ParserError
      nil
    end

    def serve_https_url(port:, dns_name:, path: "/")
      return nil if dns_name.to_s.empty?

      command = HQ.env_present("TAILSCALE_BIN", "tailscale")
      output = IO.popen([command, "serve", "status", "--json"], err: File::NULL, &:read)
      parse_serve_https_url(output, dns_name: dns_name, port: port, path: path)
    rescue Errno::ENOENT, SystemCallError, JSON::ParserError
      nil
    end

    def parse_self_status(output)
      data = JSON.parse(output.to_s)
      return nil unless data["BackendState"] == "Running"

      self_data = data["Self"].is_a?(Hash) ? data["Self"] : {}
      ips = Array(data["TailscaleIPs"])
      ips = Array(self_data["TailscaleIPs"]) if ips.empty?
      ip = ips.find { |value| value.to_s.match?(/\A100\./) } || ips.first.to_s
      return nil if ip.to_s.empty?

      dns_name = normalize_dns_name(self_data["DNSName"])
      cert_domains = Array(data["CertDomains"]).map { |value| normalize_dns_name(value) }.reject(&:empty?)
      capabilities = Array(self_data["Capabilities"]).map(&:to_s)
      cap_map = self_data["CapMap"].is_a?(Hash) ? self_data["CapMap"] : {}
      https_capable = capabilities.include?("https") || cap_map.key?("https") || !cert_domains.empty?
      https_dns_name = cert_domains.find { |domain| domain == dns_name } || (dns_name if https_capable)
      SelfInfo.new(
        ip: ip,
        dns_name: dns_name.empty? ? nil : dns_name,
        host_name: self_data["HostName"].to_s,
        https_dns_name: https_dns_name
      )
    end

    def parse_serve_https_url(output, dns_name:, port:, path: "/")
      data = JSON.parse(output.to_s)
      target = find_https_proxy(data, dns_name: dns_name, port: port)
      return nil unless target

      host, public_port = target
      public_port ||= 443
      port_part = public_port == 443 ? "" : ":#{public_port}"
      "https://#{host}#{port_part}#{path}"
    end

    def find_https_proxy(data, dns_name:, port:)
      web_entries(data).each do |host_port, config|
        host, public_port = split_host_port(host_port)
        next if public_port && !https_port?(data, public_port)
        next unless proxy_targets_port?(config, port)

        host = dns_name.to_s if host.empty? || host == "${TS_CERT_DOMAIN}"
        next if host.empty?
        next unless dns_name.to_s.empty? || host == dns_name.to_s

        return [host, public_port || 443]
      end

      nil
    end

    def web_entries(value, entries = [])
      case value
      when Hash
        web = value["Web"]
        entries.concat(web.to_a) if web.is_a?(Hash)
        value.each_value { |child| web_entries(child, entries) }
      when Array
        value.each { |child| web_entries(child, entries) }
      end

      entries
    end

    def split_host_port(value)
      host_port = value.to_s
      return ["", nil] if host_port.empty?

      host, separator, port = host_port.rpartition(":")
      return [host_port, nil] if separator.empty? || port.empty? || !port.match?(/\A\d+\z/)

      [host, port.to_i]
    end

    def https_port?(data, port)
      tcp_configs(data).any? do |tcp|
        handler = tcp[port.to_s] || tcp[port]
        handler.is_a?(Hash) && handler["HTTPS"] == true
      end
    end

    def tcp_configs(value, configs = [])
      case value
      when Hash
        tcp = value["TCP"]
        configs << tcp if tcp.is_a?(Hash)
        value.each_value { |child| tcp_configs(child, configs) }
      when Array
        value.each { |child| tcp_configs(child, configs) }
      end

      configs
    end

    def proxy_targets_port?(value, port)
      case value
      when Hash
        value.any? do |key, child|
          key.to_s == "Proxy" ? proxy_target_port?(child, port) : proxy_targets_port?(child, port)
        end
      when Array
        value.any? { |child| proxy_targets_port?(child, port) }
      else
        false
      end
    end

    def proxy_target_port?(value, port)
      value.to_s.match?(/:#{Regexp.escape(port.to_s)}(?:\/|\z)/)
    end

    def normalize_dns_name(value)
      value.to_s.sub(/\.\z/, "")
    end
  end
end
