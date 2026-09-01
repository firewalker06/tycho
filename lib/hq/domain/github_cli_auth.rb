# frozen_string_literal: true

require "open3"
require "timeout"

require_relative "executable_resolver"

module HQ
  class GitHubCLIAuth
    CACHE_TTL = 30

    def initialize(resolution: ExecutableResolver.resolve_tool("gh"), runner: Open3, timeout: 5,
                   now: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) })
      @resolution = resolution
      @runner = runner
      @timeout = timeout
      @now = now
      @token_lock = Mutex.new
    end

    def enabled?
      !access_token.to_s.empty?
    end

    def access_token
      @token_lock.synchronize do
        now = @now.call
        return @token if defined?(@token_checked_at) && now - @token_checked_at < CACHE_TTL

        @token_checked_at = now
        return @token = nil unless @resolution.available?

        stdout, _stderr, status = Timeout.timeout(@timeout) do
          @runner.capture3(@resolution.command, "auth", "token")
        end
        @token = status.success? ? stdout.to_s.strip : nil
        @token = nil if @token.to_s.empty? || @token.to_s.bytesize > 4_096
        @token
      end
    rescue Timeout::Error, SystemCallError
      @token = nil
    end

    def capability(api_url:)
      {
        enabled: enabled?,
        available: @resolution.available?,
        source: enabled? ? "gh" : "none",
        api_url: api_url,
        gh: { available: @resolution.available?, authenticated: enabled? }
      }
    end

    class << self
      def default
        @default ||= new
      end
    end
  end
end
