# frozen_string_literal: true

require "open3"

root = File.expand_path("..", __dir__)
out, err, status = Open3.capture3("node", File.join(__dir__, "support/queue_result_contract.js"),
                                File.join(root, "lib/hq/remote_ui/assets/app.js"))
raise "Queue result regression failed: #{err}" unless status.success?

puts out
