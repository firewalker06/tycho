# frozen_string_literal: true

require "tmpdir"
require "fileutils"
require "stringio"

require_relative "../lib/hq/cli_command"
require_relative "../lib/hq/domain/tycho_updater"
require_relative "../lib/hq/domain/remote_server_control"

module TychoUpdaterTest
  module_function

  def run!
    assert_homebrew_updater_runs_upgrade
    assert_removed_homebrew_keg_resolves_stable_launcher
    assert_source_checkout_is_not_updatable
    assert_remote_server_control_uses_only_local_record
    assert_cli_restart_and_update_commands
    puts "tycho_updater_test: ok"
  end

  def assert_homebrew_updater_runs_upgrade
    Dir.mktmpdir("tycho-updater") do |dir|
      executable = File.join(dir, "Cellar", "tycho", "0.10.2", "bin", "tycho")
      stable_executable = File.join(dir, "bin", "tycho")
      FileUtils.mkdir_p(File.dirname(executable))
      File.write(executable, "#!/bin/sh\n")
      FileUtils.mkdir_p(File.dirname(stable_executable))
      File.write(stable_executable, "#!/bin/sh\n")
      calls = []
      updater = HQ::TychoUpdater.new(
        executable: executable,
        command_runner: lambda do |*command|
          calls << command
          ["Upgraded tycho\n", "", instance_double(true)]
        end
      )

      assert(updater.status[:available], "expected Cellar Tycho to be updateable")
      result = updater.update!
      assert(result[:updated], "expected Homebrew update result")
      assert(result[:executable] == File.join(File.realpath(dir), "bin", "tycho"),
             "expected updater to re-resolve the stable Homebrew executable")
      assert(calls == [["brew", "upgrade", "tycho"]], "expected constrained Homebrew upgrade command")
    end
  end

  def assert_source_checkout_is_not_updatable
    updater = HQ::TychoUpdater.new(executable: __FILE__)
    assert(!updater.status[:available], "expected source checkout update to be unavailable")
  end

  def assert_removed_homebrew_keg_resolves_stable_launcher
    Dir.mktmpdir("tycho-updater-removed-keg") do |dir|
      old_executable = File.join(dir, "Cellar", "tycho", "0.10.2", "bin", "tycho")
      stable_executable = File.join(dir, "bin", "tycho")
      FileUtils.mkdir_p(File.dirname(old_executable))
      File.write(old_executable, "#!/bin/sh\n")
      FileUtils.mkdir_p(File.dirname(stable_executable))
      File.write(stable_executable, "#!/bin/sh\n")
      updater = HQ::TychoUpdater.new(
        executable: old_executable,
        command_runner: lambda do |_brew, _upgrade, _formula|
          File.delete(old_executable)
          ["Upgraded tycho\n", "", instance_double(true)]
        end
      )

      result = updater.update!
      expected = stable_executable
      assert(result[:executable] == expected, "expected removed Cellar executable to resolve to stable launcher")
      assert(HQ::TychoUpdater.stable_command([old_executable, "serve"]) == [expected, "serve"],
             "expected server command to avoid deleted Cellar executable")
    end
  end

  def assert_remote_server_control_uses_only_local_record
    Dir.mktmpdir("tycho-remote-control") do |dir|
      record_path = File.join(dir, "remote_control.json")
      requests = []
      control = HQ::RemoteServerControl.new(
        record_path: record_path,
        requester: ->(url, _token) { requests << url; { status: 202, body: { restarting: true } } }
      )
      old_remote_url = ENV["TYCHO_REMOTE_URL"]
      ENV["TYCHO_REMOTE_URL"] = "https://peer.example.test:7373"
      HQ::RemoteServerControl.publish(host: "127.0.0.1", port: 7422, path: record_path)
      assert(control.restart![:restarted], "expected loopback control record restart")
      assert(requests == ["http://127.0.0.1:7422"], "expected remote URL environment to be ignored")

      HQ::RemoteServerControl.publish(host: "100.64.0.10", port: 7423, path: record_path)
      assert(control.restart![:restarted], "expected Tailscale-bound local control record restart")
      assert(requests.last == "http://100.64.0.10:7423", "expected Tailscale control host discovery")

      File.write(record_path, '{"host":"peer.example.test","port":7424}')
      result = control.restart!
      assert(!result[:restarted], "expected connected peer record to be rejected")
      assert(requests.length == 2, "expected peer record to make no request")
    ensure
      ENV["TYCHO_REMOTE_URL"] = old_remote_url
    end
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
    supervisor = Struct.new(:calls) do
      def restart_if_running!(command:, interval: nil, dry_run: false)
        self.calls << command
        { restarted: true, detail: "Scheduler daemon restart requested" }
      end
    end.new([])
    control = Struct.new(:calls) do
      def restart!
        self.calls += 1
        { restarted: true, detail: "Remote server restart requested" }
      end
    end.new(0)
    updater.result[:executable] = "/opt/homebrew/bin/tycho"
    assert(HQ::CLICommand.update([], out: out, updater: updater, schedule_daemon_supervisor: supervisor,
                                 remote_server_control: control) == 0,
           "expected update command success")
    assert(supervisor.calls == [["/opt/homebrew/bin/tycho", "schedule", "daemon"]],
           "expected update command to restart the scheduler daemon using the new executable")
    assert(control.calls == 1, "expected update command to request a running Remote server restart")
    assert(out.string.include?("Remote server restart requested"), "expected CLI update to report remote restart state")

    absent = HQ::RemoteServerControl.new(requester: ->(_url, _token) { { status: 503, body: {} } })
    absent_result = absent.restart!
    assert(!absent_result[:restarted] && absent_result[:detail].include?("No local Remote server control record"),
           "expected absent local Remote server to be a safe no-op")
  end

  def instance_double(success)
    Struct.new(:success?).new(success)
  end

  def assert(condition, message)
    raise message unless condition
  end
end

TychoUpdaterTest.run! if $PROGRAM_NAME == __FILE__
