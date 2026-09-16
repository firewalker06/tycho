# frozen_string_literal: true

require "open3"
require "rbconfig"

module HQ
  class TychoUpdater
    FORMULA = "tycho"
    INTEL_MACOS_DEPRECATION = "Intel macOS Homebrew support is deprecated and will be removed in a future Tycho release. Migrate this installation to an Apple Silicon Mac before then."

    def initialize(executable: $PROGRAM_NAME, command_runner: Open3.method(:capture3), host_os: RbConfig::CONFIG["host_os"],
                   host_cpu: RbConfig::CONFIG["host_cpu"])
      @executable = executable.to_s
      @command_runner = command_runner
      @host_os = host_os.to_s
      @host_cpu = host_cpu.to_s
    end

    def status
      if homebrew_install?
        { available: true, detail: homebrew_status_detail }
      else
        { available: false, detail: "Updates are available only for Homebrew-installed Tycho." }
      end
    end

    def update!
      raise Error, status.fetch(:detail) unless status.fetch(:available)

      stdout, stderr, process_status = @command_runner.call("brew", "upgrade", FORMULA)
      output = [stdout, stderr].map(&:to_s).join("\n").strip
      raise Error, (output.empty? ? "Homebrew could not update Tycho" : output) unless process_status.success?

      {
        updated: true,
        detail: [intel_macos_homebrew? ? INTEL_MACOS_DEPRECATION : nil,
                 output.empty? ? "Homebrew updated Tycho." : output].compact.join("\n"),
        executable: self.class.stable_executable_for(@executable)
      }
    rescue Errno::ENOENT
      raise Error, "Homebrew is not available on this host"
    end

    def self.stable_command(command)
      values = Array(command).map(&:to_s)
      return values if values.empty?

      return values unless homebrew_prefix_for(values.first)

      [stable_executable_for(values.first), *values.drop(1)]
    end

    def self.stable_executable_for(executable)
      path = executable.to_s
      prefix = homebrew_prefix_for(path)
      return File.realpath(path) unless prefix

      File.join(prefix, "bin", FORMULA)
    rescue Errno::ENOENT
      path
    end

    def self.homebrew_prefix_for(executable)
      path = executable.to_s
      path = File.realpath(path) if File.exist?(path)
      path[%r{\A(.+)/Cellar/#{FORMULA}(?:/|\z)}, 1]
    end

    private

    def homebrew_install?
      File.realpath(@executable).match?(%r{/Cellar/tycho/})
    rescue Errno::ENOENT
      false
    end

    def intel_macos_homebrew?
      @host_os.downcase.include?("darwin") && @host_cpu.downcase.match?(/\A(?:x86_64|amd64)\z/)
    end

    def homebrew_status_detail
      detail = "Update this Homebrew installation; running local Remote and scheduler services restart automatically."
      return detail unless intel_macos_homebrew?

      "#{INTEL_MACOS_DEPRECATION} #{detail}"
    end

    class Error < StandardError; end
  end
end
