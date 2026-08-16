# frozen_string_literal: true

require "open3"

module RemoteUIConversationLoadingTest
  module_function

  ROOT = File.expand_path("..", __dir__)
  HELPERS_PATH = File.join(ROOT, "lib", "hq", "remote_ui", "assets", "app_helpers.js")

  def run!
    script = <<~'JAVASCRIPT'
      const fs = require("fs");
      const vm = require("vm");
      const context = { window: {} };
      vm.createContext(context);
      vm.runInContext(fs.readFileSync(process.argv[1], "utf8"), context);

      const conversationLoading = context.window.TychoRemoteHelpers.conversationLoading;
      const conversations = {
        alpha: { blocks: [], loaded: true, loading: false },
      };
      const loadingConversations = { beta: true };
      const checks = [
        ["uncached conversation", conversationLoading(undefined, false), true],
        ["fetch in progress", conversationLoading({ blocks: [], loaded: false, loading: true }, true), true],
        ["failed unconfirmed fetch", conversationLoading({ blocks: [], loaded: false, loading: false }, false), true],
        ["confirmed empty conversation", conversationLoading({ blocks: [], loaded: true, loading: false }, false), false],
        ["confirmed empty conversation while another agent loads", conversationLoading(conversations.alpha, Boolean(loadingConversations.alpha)), false],
        ["loaded conversation", conversationLoading({ blocks: [{ role: "user" }], loaded: true, loading: false }, false), false],
      ];

      const failed = checks.find(([, actual, expected]) => actual !== expected);
      if (failed) {
        const [label, actual, expected] = failed;
        throw new Error(`${label}: expected ${expected}, got ${actual}`);
      }
    JAVASCRIPT

    _stdout, stderr, status = Open3.capture3("node", "-e", script, HELPERS_PATH, chdir: ROOT)
    raise "conversation loading regression failed: #{stderr.strip}" unless status.success?

    puts "remote_ui_conversation_loading_test: ok"
  end
end

RemoteUIConversationLoadingTest.run! if $PROGRAM_NAME == __FILE__
