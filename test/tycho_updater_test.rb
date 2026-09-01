# frozen_string_literal: true

require "tmpdir"
require "fileutils"
require "stringio"

require_relative "../lib/hq/cli_command"
require_relative "../lib/hq/tycho_updater"

module TychoUpdaterTest
  module_function

  def run!
    assert_homebrew_updater_runs_upgrade
    assert_source_checkout_is_not_updatable
    assert_cli_restart_and_update_commands
    puts "tycho_updater_test: ok"
  end

  def assert_homebrew_updater_runs_upgrade
    Dir.mktmpdir("tycho-updater") do |dir|
      executable = File.join(dir, "Cellar", "tycho", "0.10.2", "bin", "tycho")
      FileUtils.mkdir_p(File.dirname(executable))
      File.write(executable, "#!/bin/sh\n")
      calls = []
      updater = HQ::TychoUpdater.new(
        executable: executable,
        command_runner: lambda do |*command|
          calls << command
          ["Upgraded tycho\n", "", instance_double(true)]
        end
      )

      assert(updater.status[:available], "expected Cellar Tycho to be updateable")
      assert(updater.update![:updated], "expected Homebrew update result")
      assert(calls == [["brew", "upgrade", "tycho"]], "expected constrained Homebrew upgrade command")
    end
  end

  def assert_source_checkout_is_not_updatable
    updater = HQ::TychoUpdater.new(executable: __FILE__)
    assert(!updater.status[:available], "expected source checkout update to be unavailable")
  end

  def assert_cli_restart_and_update_commands
    restarted = nil
    assert(HQ::CLICommand.restart([], executable: "tycho", restarter: ->(argv, executable) { restarted = [argv, executable] }) == 0,
           "expected restart command success")
    assert(restarted == [[], "tycho"], "expected restart command to reopen Tycho without arguments")

    out = StringIO.new
    updater = Struct.new(:result) do
      def update!
        result
      end
    end.new({ updated: true, detail: "Updated" })
    assert(HQ::CLICommand.update([], out: out, updater: updater) == 0, "expected update command success")
    assert(out.string.include?("Restart Tycho Remote and the scheduler daemon"),
           "expected update command to give restart guidance")
  end

  def instance_double(success)
    Struct.new(:success?).new(success)
  end

  def assert(condition, message)
    raise message unless condition
  end
end

TychoUpdaterTest.run! if $PROGRAM_NAME == __FILE__
