# frozen_string_literal: true

require "open3"

module RemoteUIContextPressureTest
  module_function

  ROOT = File.expand_path("..", __dir__)
  APP_PATH = File.join(ROOT, "lib", "hq", "remote_ui", "assets", "app.js")
  CSS_PATH = File.join(ROOT, "lib", "hq", "remote_ui", "assets", "app.css")

  def run!
    script = <<~'JAVASCRIPT'
      const fs = require("fs");
      const vm = require("vm");
      const source = fs.readFileSync(process.argv[1], "utf8");
      const styles = fs.readFileSync(process.argv[2], "utf8");
      const start = source.indexOf("function renderContextPressureWarning");
      const end = source.indexOf("\nfunction linkedAgentReferences", start);
      if (start < 0 || end < 0) throw new Error("missing context warning renderer");
      const context = {
        escapeAttr: String,
        escapeHtml: String,
        iconSvg: (name) => `<i>${name}</i>`,
        moreMenuButton: ({ label, icon, attrs = "", danger = false, disabled = false }) =>
          `<button role="menuitem" class="${danger ? "danger" : ""}" ${attrs} ${disabled ? "disabled" : ""}><i>${icon}</i>${label}</button>`,
        moreMenuSeparator: () => '<span role="separator"></span>',
        moreMenuHtml: (items) => `<div role="menu">${items.join("")}</div>`,
      };
      vm.createContext(context);
      vm.runInContext(`${source.slice(start, end)}\nthis.renderContextPressureWarning = renderContextPressureWarning;`, context);
      const html = context.renderContextPressureWarning({
        key: "agent-1",
        context_pressure: {
          warning: true, basis: "measured", summary: "Context pressure is high", detail: "Measured by harness",
          used_tokens: 90, limit_tokens: 100, signal_id: "signal-1", actions: { archive: false },
        },
      });
      for (const text of ["Start New", "Keep Going", "Start with Handoff", "Archive", "90% active-context usage"]) {
        if (!html.includes(text)) throw new Error(`missing warning action: ${text}`);
      }
      if (html.includes("90 of 100") || html.includes("active tokens reported")) {
        throw new Error("measured warning must not render an x-of-y token count");
      }
      for (const icon of ["shieldAlert", "sportShoe", "thumbsUp", "ellipsis"]) {
        if (!html.includes(`<i>${icon}</i>`)) throw new Error(`missing warning icon: ${icon}`);
      }
      if (!html.includes("data-context-pressure-ack") || !html.includes("data-context-pressure-dismiss") || !html.includes("disabled") ||
          !html.includes('aria-label="More context pressure actions"') ||
          !html.includes('aria-haspopup="menu"') || !html.includes('role="menu"')) {
        throw new Error("warning actions do not expose safe control state");
      }
      const topLevelActions = html.match(/data-context-pressure-(?:clone|ack)=/g) || [];
      if (topLevelActions.length !== 2 || !html.includes('class="context-pressure-dismiss inline-icon-button ui-button"') || !html.includes('class="primary inline-icon-button ui-button"')) {
        throw new Error("warning must expose exactly two primary actions before the menu");
      }
      if (context.renderContextPressureWarning({ key: "quiet", context_pressure: { warning: false } }) !== "") {
        throw new Error("unknown or acknowledged state must not show a warning");
      }
      const compactionHtml = context.renderContextPressureWarning({
        key: "compacted",
        context_pressure: {
          warning: true, basis: "reported", summary: "The harness compacted this session",
          detail: "The harness reported a compaction.", signal_id: "signal-2", actions: { archive: true },
        },
      });
      if (!compactionHtml.includes("No context percentage is shown") || compactionHtml.includes("NaN%")) {
        throw new Error("reported-only warning must explain that no percentage is available");
      }
      if (!source.includes("archive_source: true") || !source.includes("context_handoff: handoff") ||
          !source.includes("start: handoff") || !styles.includes(".context-pressure-warning") ||
          !styles.includes(".context-pressure-dismiss") || !styles.includes("position: absolute") ||
          !styles.includes("width: var(--ds-touch-target)") || !styles.includes("height: var(--ds-touch-target)") ||
          !styles.includes(".context-pressure-warning-copy > div") || !styles.includes("padding-right")) {
        throw new Error("clone safety or warning styles are missing");
      }

      async function runCloneCase({ handoff, reject = false }) {
        const lifecycleStart = source.indexOf("function retireArchivedAgent");
        const lifecycleEnd = source.indexOf("\nfunction toggleBulkArchiveMode", lifecycleStart);
        if (lifecycleStart < 0 || lifecycleEnd < 0) throw new Error("missing context replacement lifecycle functions");

        const state = {
          agents: [{ key: "source" }, { key: "unrelated" }],
          activityAgents: new Map([["source", { key: "source" }], ["unrelated", { key: "unrelated" }]]),
          archivedAgentKeys: new Set(),
          archivedAgentCatalogConfirmedKeys: new Set(),
          agentDetails: { source: { key: "source", running: true } },
          activityRevision: "old",
          resourceMutationGeneration: 0,
        };
        let request = null;
        let route = null;
        let mutation = null;
        let mutationError = null;
        const lifecycle = {
          state,
          findAgent: (key) => state.agentDetails[key] || state.agents.find((agent) => agent.key === key),
          removeAgent: (key) => {
            state.agents = state.agents.filter((agent) => agent.key !== key);
            state.activityAgents.delete(key);
            state.activityRevision = null;
            delete state.agentDetails[key];
          },
          upsertAgent: (agent) => {
            const index = state.agents.findIndex((item) => item.key === agent.key);
            if (index >= 0) state.agents[index] = agent;
            else state.agents.unshift(agent);
            state.agentDetails[agent.key] = agent;
          },
          navigate: (next) => { route = next; },
          apiPost: async (path, payload) => {
            request = { path, payload };
            if (reject) throw new Error("archive rejected");
            return { agent: { key: "replacement", running: handoff }, source_agent_key: "source", archived: true };
          },
          mutate: (callback) => {
            mutation = callback().catch((error) => { mutationError = error; });
          },
        };
        vm.createContext(lifecycle);
        vm.runInContext(`${source.slice(lifecycleStart, lifecycleEnd)}\nthis.cloneForContextPressure = cloneForContextPressure;`, lifecycle);
        lifecycle.cloneForContextPressure("source", handoff);
        await mutation;

        if (request.payload.archive_source !== true || request.payload.context_handoff !== handoff || request.payload.start !== handoff) {
          throw new Error(`clone payload mismatch: ${JSON.stringify(request)}`);
        }
        if (reject) {
          if (!mutationError || state.agents.map((agent) => agent.key).join(",") !== "source,unrelated" ||
              state.archivedAgentKeys.size !== 0 || route !== null) {
            throw new Error("rejected archive changed active client state");
          }
          return;
        }

        const keys = state.agents.map((agent) => agent.key);
        if (keys.length !== 2 || keys[0] !== "replacement" || keys[1] !== "unrelated" ||
            state.activityAgents.has("source") || !state.archivedAgentKeys.has("source") ||
            state.resourceMutationGeneration !== 1 ||
            state.agentDetails.source?.archived !== true || state.agentDetails.source?.running !== false ||
            route?.key !== "replacement") {
          throw new Error(`successful replacement left stale active state: ${JSON.stringify({ keys, route })}`);
        }
      }

      Promise.resolve().then(async () => {
        await runCloneCase({ handoff: false });
        await runCloneCase({ handoff: true });
        await runCloneCase({ handoff: true, reject: true });
      }).catch((error) => {
        console.error(error);
        process.exitCode = 1;
      });
    JAVASCRIPT
    _stdout, stderr, status = Open3.capture3("node", "-e", script, APP_PATH, CSS_PATH)
    raise "Remote UI context pressure regression failed: #{stderr.strip}" unless status.success?

    puts "remote_ui_context_pressure_test: ok"
  end
end

RemoteUIContextPressureTest.run!
