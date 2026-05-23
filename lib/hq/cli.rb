# frozen_string_literal: true

require "rbconfig"

module HQ
  module CLI
    module_function

    def run(argv = ARGV, executable: default_executable)
      if command_mode?(argv)
        require_relative "cli_command"
        exit CLICommand.run(argv, executable: executable)
      end

      Process.setproctitle("tycho") if Process.respond_to?(:setproctitle)
      Object.const_set(:HQ_BOOT_START, Process.clock_gettime(Process::CLOCK_MONOTONIC)) unless defined?(HQ_BOOT_START)

      require_relative "app"
      HQ.log_boot_step("requires loaded")

      app = HQ::App.new
      HQ.log_boot_step("App.new returned")

      Bubbletea.run(app, alt_screen: true, bracketed_paste: true)

      HQ.hooks.stop! if HQ.instance_variable_defined?(:@hooks)
      restart!(argv, executable) if HQ.restart_requested
    end

    def default_executable
      File.expand_path("../../bin/tycho", __dir__)
    end

    def command_mode?(argv)
      first = argv.first.to_s
      first == "--help" || first == "-h" || !first.empty?
    end

    def restart!(argv, executable)
      command = restart_command(argv, executable)

      HQ.logger.info("App") { "Restarting via #{command.join(" ")}" }
      exec(*command)
    end

    def restart_command(argv, executable)
      executable = default_executable if executable.nil? || executable.empty?

      if File.executable?(executable)
        [executable, *argv]
      else
        [RbConfig.ruby, executable, *argv]
      end
    end
  end
end
