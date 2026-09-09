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
        const marker = source.indexOf(`function ${name}`);
        if (marker < 0) throw new Error(`missing ${name}`);
        const start = source.slice(marker - 6, marker) === "async " ? marker - 6 : marker;
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
        personalAssistantSessionMatches: () => true,
        personalAssistantServerKey: () => "local",
        personalAssistantSubmissionEntries: () => [],
        personalAssistantRequest: (_requests, _key, factory) => factory(),
        loadPersonalAssistantSubmissionStates: () => {},
        applyPersonalAssistantItem: (item) => { context.state.personalAssistant = item; },
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
        "requestPersonalAssistantCurrentWork",
        "personalAssistantStatusRequestIsCurrent",
        "requestPersonalAssistantStatus",
        "ensureConversation",
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

      (async () => {
        context.location = { hash: "#personal-assistant" };
        context.parseRoute = () => ({ type: "personalAssistant" });
        context.personalAssistantSessionContext = (item = context.state.personalAssistant) => {
          const activeKey = String(item?.active_key || "").trim();
          const generation = Number(item?.generation);
          return activeKey && Number.isInteger(generation)
            ? { server_key: "local", active_key: activeKey, generation }
            : null;
        };
        context.personalAssistantSessionMatches = (captured) => {
          const current = context.personalAssistantSessionContext();
          return Boolean(current && captured && current.server_key === captured.server_key &&
            current.active_key === captured.active_key && current.generation === captured.generation);
        };

        const oldSession = { active_key: "fred-old", generation: 1 };
        const newSession = { active_key: "fred-new", generation: 2 };
        context.personalAssistantRequest = (requests, key, factory) => {
          if (requests[key]?.promise) return requests[key].promise;
          const request = { promise: Promise.resolve().then(factory) };
          requests[key] = request;
          request.promise.then(
            () => { if (requests[key] === request) delete requests[key]; },
            () => { if (requests[key] === request) delete requests[key]; }
          );
          return request.promise;
        };
        context.state.personalAssistantRequests = {
          status: null,
          conversations: {},
          coordinator: { sequence: 0, applied: 0 },
        };
        context.state.personalAssistant = oldSession;
        context.apiGet = () => Promise.resolve({ personal_assistant: oldSession });
        const staleStatusRequest = context.requestPersonalAssistantStatus(true, "#personal-assistant");
        context.state.personalAssistant = newSession;
        await staleStatusRequest;
        assert(context.state.personalAssistant === newSession,
               "status read captured before restart overwrote the new session");

        context.state.personalAssistant = oldSession;
        context.apiGet = () => Promise.resolve({ personal_assistant: newSession });
        await context.requestPersonalAssistantStatus(true, "#personal-assistant");
        assert(context.state.personalAssistant === newSession,
               "normal status polling did not discover a new generation");

        context.state.personalAssistant = null;
        context.apiGet = () => Promise.resolve({ personal_assistant: oldSession });
        const staleInitialStatusRequest = context.requestPersonalAssistantStatus(true, "#personal-assistant");
        context.state.personalAssistant = newSession;
        await staleInitialStatusRequest;
        assert(context.state.personalAssistant === newSession,
               "status read captured with no session overwrote a newly opened session");

        context.state.personalAssistant = null;
        await context.requestPersonalAssistantStatus(true, "#personal-assistant");
        assert(context.state.personalAssistant === oldSession,
               "initial status discovery was blocked by the null-session guard");

        context.state.personalAssistant = oldSession;
        context.state.personalAssistantLoadState = "ready";
        context.state.personalAssistantLoadError = "";
        context.state.failureCount = 0;
        let rejectStatus;
        context.apiGet = () => new Promise((_resolve, reject) => {
          rejectStatus = reject;
        });
        const staleErrorRequest = context.requestPersonalAssistantStatus(true, "#personal-assistant");
        const coalescedStaleErrorRequest = context.requestPersonalAssistantStatus(true, "#personal-assistant");
        await Promise.resolve();
        context.state.personalAssistant = newSession;
        rejectStatus(new Error("old offline"));
        const staleErrorResults = await Promise.all([staleErrorRequest, coalescedStaleErrorRequest]);
        assert(staleErrorResults.every((result) => result === null),
               "coalesced obsolete status errors did not resolve as obsolete reads");
        assert(context.state.personalAssistant === newSession &&
          context.state.personalAssistantLoadState === "ready" &&
          context.state.personalAssistantLoadError === "" && context.state.failureCount === 0,
        "obsolete status error marked the new session unavailable or backed off polling");

        context.apiGet = () => Promise.reject(new Error("current offline"));
        let currentStatusError;
        try {
          await context.requestPersonalAssistantStatus(true, "#personal-assistant");
        } catch (error) {
          currentStatusError = error;
        }
        assert(currentStatusError?.message === "current offline" &&
          context.state.personalAssistantLoadState === "error" &&
          context.state.personalAssistantLoadError === "current offline",
        "current status errors stopped surfacing");

        let conversationReads = 0;
        const runningAgent = {
          key: "fred",
          role: "personal_assistant_daily",
          running: true,
          revision: "rev-1",
        };
        context.personalAssistantAgent = (agent) => agent?.role === "personal_assistant_daily";
        context.findAgent = () => runningAgent;
        context.setConversationLoading = () => {};
        context.reconcilePersonalAssistantConversation = () => {};
        context.reconcilePersonalAssistantTerminalRuns = () => {};
        context.render = () => {};
        context.state.personalAssistant = { active_key: "fred", generation: 1 };
        context.state.conversations = {
          fred: { revision: "rev-1", blocks: [], loaded: true, loading: false },
        };
        context.state.loadingConversations = {};
        context.state.personalAssistantRequests = { conversations: {} };
        context.apiGet = () => {
          conversationReads += 1;
          return Promise.resolve({ conversation: [] });
        };
        await context.ensureConversation(runningAgent, false);
        assert(conversationReads === 1,
               "running FRED skipped its focused conversation read on an unchanged revision");
        const idleAgent = { ...runningAgent, running: false };
        await context.ensureConversation(idleAgent, false);
        assert(conversationReads === 1,
               "idle FRED lost its revision-cache conversation shortcut");

        let resolveCurrentWork;
        let rejectCurrentWork;
        let renderCalls = 0;
        context.apiGet = () => new Promise((resolve, reject) => {
          resolveCurrentWork = resolve;
          rejectCurrentWork = reject;
        });
        context.render = () => { renderCalls += 1; };
        context.state.personalAssistantRequests = {
          currentWork: {},
          coordinator: { currentWorkSequence: 0, currentWorkApplied: 0 },
        };
        context.state.personalAssistantCurrentWork = { state: "fresh", agents: [] };
        context.state.personalAssistantCurrentWorkState = "fresh";
        context.state.personalAssistantCurrentWorkError = "";
        context.state.renderedViewHtml = "stable-current-work-html";
        const currentWorkRequest = context.requestPersonalAssistantCurrentWork("#personal-assistant", {
          server_key: "local",
          active_key: "fred",
          generation: 1,
        });
        assert(context.state.personalAssistantCurrentWorkState === "fresh",
               "background current-work polling replaced the visible snapshot with refreshing");
        assert(context.state.renderedViewHtml === "stable-current-work-html",
               "background current-work polling invalidated the visible snapshot before its response");
        await Promise.resolve();
        resolveCurrentWork({ state: "fresh", agents: [] });
        await currentWorkRequest;
        assert(renderCalls === 1, "current-work response did not use the existing render path");
        assert(context.state.renderedViewHtml === "stable-current-work-html",
               "unchanged current-work response bypassed the same-HTML render shortcut");

        const changedCurrentWorkRequest = context.requestPersonalAssistantCurrentWork("#personal-assistant", {
          server_key: "local",
          active_key: "fred",
          generation: 1,
        });
        assert(context.state.personalAssistantCurrentWorkState === "fresh",
               "changed current-work polling replaced the visible snapshot with refreshing");
        await Promise.resolve();
        resolveCurrentWork({ state: "stale", agents: [{ key: "fred", status: "waiting" }] });
        await changedCurrentWorkRequest;
        assert(context.state.personalAssistantCurrentWorkState === "stale",
               "changed current-work response did not update its visible state");
        assert(renderCalls === 2, "changed current-work response did not use the existing render path");
        assert(context.state.renderedViewHtml === "stable-current-work-html",
               "changed current-work response unnecessarily invalidated the existing view");

        const failedCurrentWorkRequest = context.requestPersonalAssistantCurrentWork("#personal-assistant", {
          server_key: "local",
          active_key: "fred",
          generation: 1,
        });
        assert(context.state.personalAssistantCurrentWorkState === "stale",
               "failed background current-work polling replaced the visible snapshot with refreshing");
        await Promise.resolve();
        rejectCurrentWork(new Error("offline"));
        await failedCurrentWorkRequest.catch(() => {});
        assert(context.state.personalAssistantCurrentWorkState === "unavailable",
               "current-work failure did not surface an unavailable state");
        assert(context.state.personalAssistantCurrentWorkError === "offline",
               "current-work failure did not retain its error");
        assert(context.state.renderedViewHtml === "stable-current-work-html",
               "current-work failure unnecessarily invalidated the existing view");

        console.log("remote_ui_personal_assistant_behavior_test: completed");
      })().catch((error) => {
        console.error(error.stack || error);
        process.exitCode = 1;
      });
    JAVASCRIPT

    stdout, stderr, status = Open3.capture3("node", "-e", script, APP_PATH, chdir: ROOT)
    completion_marker = "remote_ui_personal_assistant_behavior_test: completed"
    completed = stdout.lines.map(&:chomp).include?(completion_marker)
    unless status.success? && completed
      detail = stderr.strip
      detail = "completion marker missing" unless completed
      raise "Personal Assistant UI behavior regression failed: #{detail}"
    end

    puts "remote_ui_personal_assistant_behavior_test: ok"
  end
end

RemoteUIPersonalAssistantBehaviorTest.run! if $PROGRAM_NAME == __FILE__
