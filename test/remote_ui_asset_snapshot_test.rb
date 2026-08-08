# frozen_string_literal: true

require "fileutils"
require "open3"
require "rbconfig"
require "tmpdir"

module RemoteUIAssetSnapshotTest
  module_function

  ROOT = File.expand_path("..", __dir__)

  def run!
    assert_loaded_daemon_keeps_one_asset_build
    assert_handoff_retry_key_is_cleared_after_success
    puts "remote_ui_asset_snapshot_test: ok"
  end

  def assert_handoff_retry_key_is_cleared_after_success
    javascript = File.read(File.join(ROOT, "lib", "hq", "remote_ui", "assets", "app.js"))
    response_index = javascript.index("const response = await apiPost(`/pull-requests/${encodeURIComponent(id)}/handoff`")
    clear_index = javascript.index("delete form.dataset.handoffIdempotencyKey", response_index)
    raise "expected a successful handoff to clear its retry key" unless response_index && clear_index && clear_index > response_index
  end

  def assert_loaded_daemon_keeps_one_asset_build
    Dir.mktmpdir("tycho-remote-ui-snapshot") do |dir|
      lib_dir = File.join(dir, "lib", "hq")
      FileUtils.mkdir_p(lib_dir)
      FileUtils.cp(File.join(ROOT, "lib", "hq", "remote_ui.rb"), lib_dir)
      FileUtils.cp_r(File.join(ROOT, "lib", "hq", "remote_ui"), lib_dir)

      script = <<~'RUBY'
        require "hq/remote_ui"

        loaded_js = HQ::RemoteUI.js
        loaded_version = HQ::RemoteUI.asset_version
        File.write(HQ::RemoteUI::JS_PATH, "#{loaded_js}\n// simulated update\n")

        abort "running daemon served JavaScript from a different build" unless HQ::RemoteUI.js == loaded_js
        abort "running daemon changed its asset version after startup" unless HQ::RemoteUI.asset_version == loaded_version
      RUBY
      stdout, stderr, status = Open3.capture3(
        RbConfig.ruby,
        "-I#{File.join(dir, "lib")}",
        "-e",
        script
      )
      return if status.success?

      raise "asset snapshot regression failed: #{[stdout, stderr].join.strip}"
    end
  end
end

RemoteUIAssetSnapshotTest.run! if $PROGRAM_NAME == __FILE__
