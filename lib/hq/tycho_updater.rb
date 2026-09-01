# frozen_string_literal: true

require "open3"

module HQ
  class TychoUpdater
    FORMULA = "tycho"

    def initialize(executable: $PROGRAM_NAME, command_runner: Open3.method(:capture3))
      @executable = executable.to_s
      @command_runner = command_runner
    end

    def status
      if homebrew_install?
        { available: true, detail: "Update this Homebrew installation, then restart Remote and the scheduler daemon." }
      else
        { available: false, detail: "Updates are available only for Homebrew-installed Tycho." }
      end
    end

    def update!
      raise Error, status.fetch(:detail) unless status.fetch(:available)

      stdout, stderr, process_status = @command_runner.call("brew", "upgrade", FORMULA)
      output = [stdout, stderr].map(&:to_s).join("\n").strip
      raise Error, (output.empty? ? "Homebrew could not update Tycho" : output) unless process_status.success?

      { updated: true, detail: output.empty? ? "Homebrew updated Tycho." : output }
    rescue Errno::ENOENT
      raise Error, "Homebrew is not available on this host"
    end

    private

    def homebrew_install?
      File.realpath(@executable).match?(%r{/Cellar/tycho/})
    rescue Errno::ENOENT
      false
    end

    class Error < StandardError; end
  end
end
