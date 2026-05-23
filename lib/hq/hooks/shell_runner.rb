# frozen_string_literal: true

require "open3"
require "json"
require "timeout"
require "logger"

module HQ
  module Hooks
    module ShellRunner
      module_function

      def call(hook_config, event, payload, blocking: false)
        command = hook_config[:command].to_s
        env = build_env(hook_config, event, payload)
        json = JSON.generate(payload) + "\n"
        timeout = hook_config[:timeout]

        run_process(env, command, json, event, timeout: timeout, blocking: blocking)
      rescue StandardError => e
        HQ.logger.error("Hooks") { "Shell hook failed for #{event}: #{e.class}: #{e.message}" }
        nil
      end

      def build_env(hook_config, event, payload)
        base = {
          "TYCHO_EVENT" => event.to_s,
          "TYCHO_PROJECT_KEY" => payload["project_key"].to_s,
          "TYCHO_AGENT_KEY" => payload["agent_key"].to_s,
          "TYCHO_BIN" => hq_bin_path,
          "TYCHO_PROJECT_PATH" => payload["project_path"].to_s
        }
        base.merge(hook_config[:env] || {})
      end

      def hq_bin_path
        File.expand_path("../../../bin/tycho", __dir__)
      end

      def run_process(env, command, json, event, timeout:, blocking:)
        stdin, stdout, stderr, wait_thr = Open3.popen3(env, command, pgroup: true)
        begin
          begin
            stdin.write(json)
            stdin.close
          rescue Errno::EPIPE
            nil
          end

          deadline = Time.now + timeout
          killer = Thread.new do
            until Time.now >= deadline
              break unless wait_thr.alive?

              sleep 0.1
            end
            if wait_thr.alive?
              kill_group(wait_thr)
              hooks_log.warn { "[#{event}] TIMEOUT #{command}" }
              HQ.logger.warn("Hooks") { "Timeout (#{timeout}s) on #{event} -> #{command}" }
            end
          end

          stderr_thread = Thread.new do
            stderr.each_line { |line| hooks_log.info { "[#{event}] stderr: #{line.chomp}" } }
          rescue StandardError
            nil
          end

          if blocking
            out = stdout.read.to_s
            wait_thr.value
            stderr_thread.join
            killer.join
            return nil unless wait_thr.value.success?

            parse_response(out, event)
          else
            stdout_thread = Thread.new do
              stdout.each_line { |line| hooks_log.info { "[#{event}] stdout: #{line.chomp}" } }
            rescue StandardError
              nil
            end
            wait_thr.value
            stderr_thread.join
            stdout_thread.join
            killer.join
            nil
          end
        ensure
          [stdin, stdout, stderr].each { |io| io.close unless io.closed? }
        end
      end

      def parse_response(out, event)
        return nil if out.strip.empty?

        JSON.parse(out)
      rescue JSON::ParseError => e
        HQ.logger.warn("Hooks") { "Failed to parse JSON response for #{event}: #{e.message}" }
        nil
      end

      def kill_group(wait_thr)
        pid = wait_thr.pid
        Process.kill("TERM", -Process.getpgid(pid))
      rescue Errno::ESRCH, Errno::EPERM
        nil
      end

      def hooks_log
        @hooks_log ||= begin
          logger = ::Logger.new(HQ::HOOKS_LOG_FILE, "daily")
          logger.formatter = proc do |severity, datetime, _progname, msg|
            "[#{severity}] [#{datetime.strftime("%Y-%m-%d %H:%M:%S")}] #{msg}\n"
          end
          logger
        end
      end
    end
  end
end
