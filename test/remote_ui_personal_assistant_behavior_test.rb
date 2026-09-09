# frozen_string_literal: true

require "open3"

module RemoteUIPersonalAssistantBehaviorTest
  module_function

  ROOT = File.expand_path("..", __dir__)
  APP_PATH = File.join(ROOT, "lib", "hq", "remote_ui", "assets", "app.js")

  def run!
    script = <<~'JAVASCRIPT'
      const fs = require("fs");
      const vm = require("vm");
      const source = fs.readFileSync(process.argv[1], "utf8");

      function extractFunction(name) {
        const start = source.indexOf(`function ${name}`);
        if (start < 0) throw new Error(`missing ${name}`);
        const opening = source.indexOf("{", source.indexOf(")", start));
        let depth = 0;
        let quote = "";
        let escaped = false;
        for (let index = opening; index < source.length; index += 1) {
          const char = source[index];
          if (quote) {
            if (escaped) escaped = false;
            else if (char === "\\") escaped = true;
            else if (char === quote) quote = "";
            continue;
          }
          if (["'", '"', "`"].includes(char)) {
            quote = char;
            continue;
          }
          if (char === "{") depth += 1;
          if (char === "}" && --depth === 0) return source.slice(start, index + 1);
        }
        throw new Error(`unterminated ${name}`);
      }

      const context = {
        Map,
        Set,
        PERSONAL_ASSISTANT_ANNOUNCEMENT_LIMIT: 128,
        PERSONAL_ASSISTANT_MAX_FAILURE_COUNT: 2,
        PERSONAL_ASSISTANT_POLL_INTERVALS: { activeMs: 1500, idleMs: 12000, hiddenMs: 30000 },
        document: { hidden: false },
        state: {
          personalAssistant: { configured: true },
          personalAssistantAnnouncementValues: new Map(),
          personalAssistantProposals: [],
          personalAssistantCurrentWork: null,
          agentDetails: { fred: { running: true } },
          failureCount: 0,
        },
        els: { view: null },
        escapeAttr: (value) => String(value),
        personalAssistantSubmissionForBlock: () => null,
        personalAssistantSessionContext: () => ({ server_key: "local", active_key: "fred", generation: 1 }),
        personalAssistantServerKey: () => "local",
        personalAssistantSubmissionEntries: () => [],
      };
      vm.createContext(context);
      [
        "personalAssistantAnnouncementAttributes",
        "commitPersonalAssistantAnnouncements",
        "personalAssistantShellRefreshNeeded",
        "personalAssistantConversationEventIdentity",
        "personalAssistantVisibleConversationBlocks",
        "personalAssistantPollDelay",
        "notePersonalAssistantRefreshFailure",
      ].forEach((name) => vm.runInContext(`${extractFunction(name)}\nthis.${name} = ${name};`, context));

      const assert = (condition, message) => {
        if (!condition) throw new Error(message);
      };
      const liveValue = (attributes) => attributes.match(/aria-live="([^"]+)"/)[1];

      context.state.personalAssistant = { configured: true };
      assert(context.personalAssistantShellRefreshNeeded() === false,
             "configured FRED still requests shell setup discovery");
      context.state.personalAssistant = { configured: false };
      assert(context.personalAssistantShellRefreshNeeded() === true,
             "unconfigured FRED lost setup discovery");

      const runOnly = context.personalAssistantVisibleConversationBlocks([
        { kind: "message", role: "assistant", run_id: "run-1", content: "First" },
        { kind: "message", role: "assistant", run_id: "run-1", content: "Second" },
      ]);
      assert(runOnly.length === 2, "run-only messages were collapsed");
      const timestampOnly = context.personalAssistantVisibleConversationBlocks([
        { kind: "message", role: "user", created_at: "2026-09-09T00:00:00Z", content: "Question" },
        { kind: "message", role: "assistant", created_at: "2026-09-09T00:00:00Z", content: "Answer" },
      ]);
      assert(timestampOnly.length === 2, "timestamp-only messages were collapsed");
      const duplicateEvent = context.personalAssistantVisibleConversationBlocks([
        { kind: "message", role: "assistant", metadata: { event_id: "event-1" }, content: "Same" },
        { kind: "message", role: "assistant", metadata: { event_id: "event-1" }, content: "Same" },
      ]);
      assert(duplicateEvent.length === 1, "duplicate event IDs were not deduplicated");

      let mounted = [];
      context.els.view = { querySelectorAll: () => mounted };
      context.state.personalAssistantAnnouncementValues = new Map();
      const first = context.personalAssistantAnnouncementAttributes("current-work", "live");
      const beforeCommit = context.personalAssistantAnnouncementAttributes("current-work", "live");
      assert(liveValue(first) === "polite" && liveValue(beforeCommit) === "polite",
             "uncommitted announcement state was consumed");
      mounted = [{ dataset: { paAnnouncementRegion: "current-work", paAnnouncementValue: "live" } }];
      context.commitPersonalAssistantAnnouncements();
      assert(liveValue(context.personalAssistantAnnouncementAttributes("current-work", "live")) === "off",
             "unchanged announcement was not suppressed");
      mounted = [{ dataset: { paAnnouncementRegion: "current-work", paAnnouncementValue: "stale" } }];
      assert(liveValue(context.personalAssistantAnnouncementAttributes("current-work", "stale")) === "polite",
             "degraded announcement was not announced");
      context.commitPersonalAssistantAnnouncements();
      assert(liveValue(context.personalAssistantAnnouncementAttributes("current-work", "live")) === "polite",
             "recovery announcement was suppressed by historical state");

      context.state.personalAssistant = { configured: true, active_key: "fred" };
      assert(context.personalAssistantPollDelay() === 1500,
             "active FRED polling lost its normal cadence");
      context.notePersonalAssistantRefreshFailure();
      assert(context.state.failureCount === 1 && context.personalAssistantPollDelay() === 12000,
             "the first failed FRED poll did not use the bounded idle backoff");
      context.notePersonalAssistantRefreshFailure();
      context.notePersonalAssistantRefreshFailure();
      assert(context.state.failureCount === 2 && context.personalAssistantPollDelay() === 30000,
             "repeated failed FRED polls were not capped at the hidden backoff");
      context.state.failureCount = 0;
      assert(context.personalAssistantPollDelay() === 1500,
             "successful FRED recovery did not restore active polling");
    JAVASCRIPT

    _stdout, stderr, status = Open3.capture3("node", "-e", script, APP_PATH, chdir: ROOT)
    raise "Personal Assistant UI behavior regression failed: #{stderr.strip}" unless status.success?

    puts "remote_ui_personal_assistant_behavior_test: ok"
  end
end

RemoteUIPersonalAssistantBehaviorTest.run! if $PROGRAM_NAME == __FILE__
