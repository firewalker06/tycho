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
      const conversationSnapshotRequestMode = context.window.TychoRemoteHelpers.conversationSnapshotRequestMode;
      const shouldAutoScrollConversation = context.window.TychoRemoteHelpers.shouldAutoScrollConversation;
      const shouldOpenSucceededAgentSummary = context.window.TychoRemoteHelpers.shouldOpenSucceededAgentSummary;
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

      const slowPollDelay = context.window.TychoRemoteHelpers.slowPollDelay;
      const modeChecks = [
        ["matching revision skips poll", conversationSnapshotRequestMode({ loaded: true, revision: "r1" }, "r1"), "none"],
        ["remembered agent revision skips poll", conversationSnapshotRequestMode({ loaded: true, revision: "conv-9", agentRevision: "r1" }, "r1"), "none"],
        ["changed revision fetches metadata", conversationSnapshotRequestMode({ loaded: true, revision: "conv-9", agentRevision: "r1" }, "r2"), "metadata"],
        ["unloaded conversation fetches snapshot", conversationSnapshotRequestMode({ loaded: false }, "r1"), "snapshot"],
      ];
      const failedMode = modeChecks.find(([, actual, expected]) => actual !== expected);
      if (failedMode) throw new Error(`${failedMode[0]}: expected ${failedMode[2]}, got ${failedMode[1]}`);
      const slowChecks = [
        ["fast request keeps interval", slowPollDelay(5000, 200, 1500), 5000],
        ["slow request doubles interval", slowPollDelay(5000, 2000, 1500), 10000],
        ["very slow request is capped at 4x", slowPollDelay(5000, 60000, 1500), 20000],
        ["unknown duration keeps interval", slowPollDelay(5000, undefined, 1500), 5000],
      ];
      const failedSlow = slowChecks.find(([, actual, expected]) => actual !== expected);
      if (failedSlow) throw new Error(`${failedSlow[0]}: expected ${failedSlow[2]}, got ${failedSlow[1]}`);

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
      const amended = [{ id: "two", kind: "message", role: "assistant", content: "Existing reply amended", metadata: { progress: "complete" } }];
      const original = [{ id: "two", kind: "message", role: "assistant", content: "Existing reply", metadata: { progress: "running" } }];
      if (conversationBlocksMatch(original, amended) || unseenConversationBlocks(original, amended).length !== 1) {
        throw new Error("same-ID content or metadata amendments were not staged");
      }

      // An older page can overlap the rendered tail when new blocks arrive
      // while the page request is in flight. The prepend path must keep only
      // the older portion so an overlapping page never duplicates messages.
      const renderedTail = [
        { id: "tail-one", kind: "message", role: "assistant", content: "Already rendered one" },
        { id: "tail-two", kind: "message", role: "assistant", content: "Already rendered two" },
      ];
      const delayedOlderPage = [
        { id: "older", kind: "message", role: "assistant", content: "Older history" },
        ...renderedTail,
      ];
      const uniqueOlderPage = unseenConversationBlocks(renderedTail, delayedOlderPage);
      if (uniqueOlderPage.length !== 1 || uniqueOlderPage[0].id !== "older") {
        throw new Error("overlapping older page did not discard already-rendered tail blocks");
      }

      const optimistic = { id: "local", kind: "message", role: "user", content: "Optimistic prompt", client_request_id: "request-1" };
      const acknowledged = { id: "server", kind: "message", role: "user", content: "Optimistic prompt", metadata: { client_request_id: "request-1" } };
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

      const loadedConversation = { revision: "old", blocks: rendered, loaded: true, loading: false };
      if (conversationSnapshotRequestMode(loadedConversation, "new", { force: true }) !== "metadata") {
        throw new Error("automatic refresh fetched the full conversation snapshot");
      }
      if (conversationSnapshotRequestMode(loadedConversation, "new", { manual: true }) !== "snapshot") {
        throw new Error("manual loading did not fetch the full conversation snapshot");
      }
      if (conversationSnapshotRequestMode(undefined, "new") !== "snapshot") {
        throw new Error("initial conversation loading did not fetch the full snapshot");
      }
      if (conversationSnapshotRequestMode({ ...loadedConversation, revision: "new" }, "new") !== "none") {
        throw new Error("unchanged conversation revision triggered another request");
      }

      const conversationScrollChecks = [
        ["first visit", { marker: "first", previousMarker: undefined, entered: true, atBottom: false }, true],
        ["reopened conversation", { marker: "same", previousMarker: "same", entered: true, atBottom: false }, true],
        ["asynchronous first content", { marker: "loaded", previousMarker: undefined, entered: false, atBottom: false }, true],
        ["new content at the live tail", { marker: "new", previousMarker: "old", entered: false, atBottom: true }, true],
        ["reader in older history", { marker: "new", previousMarker: "old", entered: false, atBottom: false }, false],
        ["unchanged live conversation", { marker: "same", previousMarker: "same", entered: false, atBottom: true }, false],
      ];
      const failedScrollCheck = conversationScrollChecks.find(([, input, expected]) =>
        shouldAutoScrollConversation(input) !== expected);
      if (failedScrollCheck) {
        throw new Error(`conversation scroll policy failed for ${failedScrollCheck[0]}`);
      }

      if (shouldOpenSucceededAgentSummary(
        { key: "loop", status: "running", scheduled: true },
        { key: "loop", status: "succeeded", scheduled: true },
        "agent"
      )) {
        throw new Error("scheduled loop completion opened Summary and displaced the conversation scroll");
      }
      if (!shouldOpenSucceededAgentSummary(
        { key: "manual", status: "running", scheduled: false },
        { key: "manual", status: "succeeded", scheduled: false },
        "agent"
      )) {
        throw new Error("ordinary agent completion stopped opening Summary");
      }
    JAVASCRIPT

    _stdout, stderr, status = Open3.capture3("node", "-e", script, HELPERS_PATH, chdir: ROOT)
    raise "conversation loading regression failed: #{stderr.strip}" unless status.success?

    puts "remote_ui_conversation_loading_test: ok"
  end
end

RemoteUIConversationLoadingTest.run! if $PROGRAM_NAME == __FILE__
