# frozen_string_literal: true

require "optparse"

require_relative "dotenv_loader"

HQ::DotenvLoader.load(File.expand_path("../.env", __dir__))

require_relative "remote_server"
require_relative "tailscale"

module HQ
  module ServeCommand
    module_function

    def run(argv = ARGV, executable: nil, command_prefix: [], out: $stdout, err: $stderr)
      args = Array(argv).dup
      options = {
        host: nil,
        port: RemoteServer::DEFAULT_PORT
      }
      explicit_host = false
      original_argv = args.dup

      parser = OptionParser.new do |opts|
        opts.banner = "Usage: tycho serve [--host 127.0.0.1] [--port 7373]"
        opts.on("--host HOST", "Bind host") do |host|
          explicit_host = true
          options[:host] = host
        end
        opts.on("--port PORT", Integer, "Bind port") { |port| options[:port] = port }
        opts.on("-h", "--help", "Show this help") do
          out.puts opts
          return 0
        end
      end

      parser.parse!(args)
      unless args.empty?
        err.puts "Unexpected argument: #{args.join(" ")}"
        err.puts parser
        return 1
      end

      start_server(
        options: options,
        explicit_host: explicit_host,
        restart_command: restart_command(executable, command_prefix, original_argv),
        out: out
      )
      0
    end

    def start_server(options:, explicit_host:, restart_command:, out:)
      tailscale = explicit_host ? nil : Tailscale.detect
      tailscale_https_url = if tailscale&.https_capable?
                              Tailscale.serve_https_url(
                                port: options[:port],
                                dns_name: tailscale.https_dns_name || tailscale.dns_name
                              )
                            end
      host = options[:host] || (tailscale_https_url ? RemoteServer::DEFAULT_HOST : tailscale&.ip) ||
             RemoteServer::DEFAULT_HOST
      public_url = tailscale_https_url || tailscale&.magic_dns_url(port: options[:port]) ||
                   tailscale&.ip_url(port: options[:port])
      startup_messages = startup_messages_for(tailscale, tailscale_https_url, options[:port])

      RemoteServer.new(
        host: host,
        port: options[:port],
        public_url: public_url,
        restart_command: restart_command,
        startup_messages: startup_messages,
        output: out
      ).start
    end

    def startup_messages_for(tailscale, tailscale_https_url, port)
      return [] unless tailscale

      messages = []
      if tailscale.dns_name.to_s.empty?
        messages << "Tailscale detected; binding to #{tailscale.ip}"
      else
        messages << "Tailscale detected; using MagicDNS #{tailscale.dns_name}"
      end

      if tailscale_https_url
        messages << "Tailscale HTTPS Serve detected; QR will use #{tailscale_https_url}"
      elsif tailscale.https_capable?
        messages << "Tailscale HTTPS is enabled for #{tailscale.https_dns_name}"
        messages << "Run `tailscale serve --bg #{port}` and restart to use an HTTPS QR"
      end
      messages
    end

    def restart_command(executable, command_prefix, original_argv)
      path = executable.to_s
      return [] if path.empty?

      [path, *Array(command_prefix), *Array(original_argv)]
    end
  end
end
