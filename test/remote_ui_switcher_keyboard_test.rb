# frozen_string_literal: true

require "open3"

root = File.expand_path("..", __dir__)
output, status = Open3.capture2e(
  "node", File.join(root, "test/support/switcher_keyboard_probe.js"),
  File.join(root, "lib/hq/remote_ui/assets/app.js"),
  File.join(root, "lib/hq/remote_ui/assets/app_helpers.js"), "--assert"
)
raise "switcher keyboard regression failed:\n#{output}" unless status.success?

puts "remote_ui_switcher_keyboard_test: ok"
