# frozen_string_literal: true

require "optparse"
require "time"

require_relative "dotenv_loader"

HQ::DotenvLoader.load(File.expand_path("../.env", __dir__))

require_relative "domain/scheduler"

module HQ
  module ScheduleDaemonCommand
    module_function

    def run(argv = ARGV, out: $stdout, err: $stderr)
      out.sync = true if out.respond_to?(:sync=)
      err.sync = true if err.respond_to?(:sync=)

      args = Array(argv).dup
      options = {
        once: false,
        dry_run: false,
        interval: Scheduler::DEFAULT_INTERVAL
      }
      command = args.shift if args.first && !args.first.start_with?("-")

      parser = OptionParser.new do |opts|
        opts.banner = "Usage: bin/tycho schedule daemon [--once] [--dry-run] [--interval SECONDS]"
        opts.on("--once", "Run one scheduler tick and exit") { options[:once] = true }
        opts.on("--dry-run", "Validate and report due work without starting agents") { options[:dry_run] = true }
        opts.on("--interval SECONDS", Integer, "Polling interval for daemon mode") do |value|
          options[:interval] = value.positive? ? value : Scheduler::DEFAULT_INTERVAL
        end
        opts.on("-h", "--help", "Show help") do
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

      case command
      when nil
        run_loop(options, out: out, err: err)
      when "list"
        require_relative "cli_command"
        CLICommand.list_schedules(out: out, err: err)
      else
        err.puts "Unknown schedule daemon command: #{command}"
        err.puts parser
        1
      end
    rescue OptionParser::ParseError => e
      err.puts e.message
      1
    end

    def run_loop(options, out:, err:)
      shutdown_requested = false
      shutdown_signal = nil
      announce_shutdown = proc do |signal|
        next if shutdown_requested

        shutdown_requested = true
        shutdown_signal = signal
        begin
          err.puts "[#{Time.now.iso8601}] received #{signal}; shutting down after the current scheduler tick completes..."
        rescue StandardError
          nil
        end
      end

      Signal.trap("INT") { announce_shutdown.call("INT") }
      Signal.trap("TERM") { announce_shutdown.call("TERM") }

      store = ScheduleStore.new
      begin
        store.record_daemon_start!(
          pid: Process.pid,
          mode: options[:once] ? "once" : "daemon",
          interval: options[:interval],
          dry_run: options[:dry_run]
        )
        loop do
          scheduler = Scheduler.new
          store.record_daemon_tick_started!
          scheduler.validate!
          result = scheduler.tick(dry_run: options[:dry_run])
          store.record_daemon_tick_finished!(result)
          out.puts "[#{Time.now.iso8601}] schedules: started=#{result[:started]} skipped=#{result[:skipped]} " \
                   "queued=#{result[:queued]} failed=#{result[:failed]} dry_run=#{result[:dry_run]}"

          break if options[:once] || shutdown_requested

          sleep_until = Time.now + options[:interval]
          until shutdown_requested || Time.now >= sleep_until
            sleep [1, sleep_until - Time.now].min
          end
          break if shutdown_requested
        end
        store.record_daemon_stop!(signal: shutdown_signal)
        err.puts "[#{Time.now.iso8601}] scheduler stopped after #{shutdown_signal}." if shutdown_signal
        0
      rescue ScheduleRegistry::Error => e
        store&.record_daemon_stop!(error: e.message)
        err.puts e.message
        1
      end
    end
  end
end
