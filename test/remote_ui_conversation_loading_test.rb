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
      const agentComposerState = context.window.TychoRemoteHelpers.agentComposerState;
      const conversationBlocksMatch = context.window.TychoRemoteHelpers.conversationBlocksMatch;
      const unseenConversationBlocks = context.window.TychoRemoteHelpers.unseenConversationBlocks;
      const pendingConversationBlockAcknowledged = context.window.TychoRemoteHelpers.pendingConversationBlockAcknowledged;
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

      const composerChecks = [
        ["normal agent", agentComposerState({}), "composer"],
        ["pending inquiry detail", agentComposerState({ awaiting_input: true }), "inquiry-loading"],
        ["loaded inquiry", agentComposerState({ awaiting_input: true, latest_inquiry: { id: "inquiry-1" } }), "inquiry"],
        ["inconsistent inquiry detail", agentComposerState({ awaiting_input: true, latest_inquiry: null }), "composer"],
      ];
      const failedComposerCheck = composerChecks.find(([, actual, expected]) => actual !== expected);
      if (failedComposerCheck) {
        const [label, actual, expected] = failedComposerCheck;
        throw new Error(`${label}: expected ${expected}, got ${actual}`);
      }

      const rendered = [
        { id: "one", kind: "message", role: "user", content: "Keep this visible" },
        { id: "two", kind: "message", role: "assistant", content: "Existing reply" },
      ];
      const incoming = [...rendered, { id: "three", kind: "message", role: "assistant", content: "Arrived while composing" }];
      const unseen = unseenConversationBlocks(rendered, incoming);
      if (unseen.length !== 1 || unseen[0].id !== "three") {
        throw new Error(`new server message was not staged exactly once: ${JSON.stringify(unseen)}`);
      }
      if (conversationBlocksMatch(rendered, incoming) || !conversationBlocksMatch(rendered, [...rendered])) {
        throw new Error("conversation snapshot comparison did not preserve the rendered baseline");
      }

      const optimistic = { id: "local", kind: "message", role: "user", content: "Optimistic prompt", client_request_id: "request-1" };
      const acknowledged = { id: "server", kind: "message", role: "user", content: "Optimistic prompt", metadata: { personal_assistant_client_request_id: "request-1" } };
      if (!pendingConversationBlockAcknowledged(optimistic, [acknowledged])) {
        throw new Error("server acknowledgement did not suppress the duplicate optimistic message");
      }
      if (pendingConversationBlockAcknowledged(optimistic, rendered)) {
        throw new Error("unrelated server history acknowledged an optimistic message");
      }
      const legacyPending = { id: "local-legacy", kind: "message", role: "user", content: "Same legacy prompt", created_at: "2026-09-10T00:00:00Z" };
      const legacyAcknowledged = { id: "server-legacy", kind: "message", role: "user", content: "Same legacy prompt", created_at: "2026-09-10T00:00:02Z" };
      if (!pendingConversationBlockAcknowledged(legacyPending, [legacyAcknowledged])) {
        throw new Error("nearby legacy acknowledgement did not suppress a duplicate optimistic message");
      }
    JAVASCRIPT

    _stdout, stderr, status = Open3.capture3("node", "-e", script, HELPERS_PATH, chdir: ROOT)
    raise "conversation loading regression failed: #{stderr.strip}" unless status.success?

    puts "remote_ui_conversation_loading_test: ok"
  end
end

RemoteUIConversationLoadingTest.run! if $PROGRAM_NAME == __FILE__
