# frozen_string_literal: true

require "open3"

module RemoteUIActivityReplacementRaceTest
  module_function

  ROOT = File.expand_path("..", __dir__)
  APP_PATH = File.join(ROOT, "lib", "hq", "remote_ui", "assets", "app.js")

  def run!
    script = <<~'JAVASCRIPT'
      const fs = require("fs");
      const vm = require("vm");
      const source = fs.readFileSync(process.argv[1], "utf8");
      const start = source.indexOf("function mergeAgentActivity");
      const end = source.indexOf("\nasync function loadResourceCatalog", start);
      if (start < 0 || end < 0) throw new Error("missing activity reconciliation functions");

      const sourceDetail = { key: "source", server_key: "local", archived: true, running: false, status: "succeeded" };
      const replacementDetail = { key: "replacement", server_key: "local", archived: false, running: false, status: "idle" };
      const unrelatedDetail = { key: "unrelated", server_key: "local", archived: false, running: false, status: "idle" };
      const context = {
        AGENT_ACTIVITY_FIELDS: ["archived", "running", "status"],
        normalizeAgentResource: (agent, server) => ({ ...agent, server_key: server.key }),
        syncUnreadAlert: () => {},
        state: {
          agents: [replacementDetail, unrelatedDetail],
          agentDetails: {
            source: sourceDetail,
            replacement: replacementDetail,
            unrelated: unrelatedDetail,
          },
          servers: [{ key: "local" }],
          activityAgents: new Map(),
          activityReadyServerKeys: new Set(),
          activityRevision: null,
          activityAppliedSequence: 0,
          resourceMutationGeneration: 1,
          archivedAgentKeys: new Set(["source"]),
          archivedAgentCatalogConfirmedKeys: new Set(),
        },
      };
      vm.createContext(context);
      vm.runInContext(`${source.slice(start, end)}\nthis.applyAgentActivity = applyAgentActivity;`, context);

      const catalogStart = source.indexOf("function applyResourceCatalog");
      const catalogEnd = source.indexOf("\nfunction mergeAgentActivity", catalogStart);
      if (catalogStart < 0 || catalogEnd < 0) throw new Error("missing catalog reconciliation function");
      let quickOptionSyncs = 0;
      Object.assign(context, {
        syncQuickAgentOptions: () => { quickOptionSyncs += 1; },
        normalizeProjectResource: (project, server) => ({ ...project, server_key: server.key }),
        reconcileOptimisticPromptQueue: () => {},
        prunePullRequestDiffState: () => {},
        REMOTE_HELPERS: { reconcileAgentDetail: (detail) => detail, inquiryResolved: () => false },
      });
      Object.assign(context.state, {
        projects: [],
        projectDetails: {},
        filters: { server: "" },
        resourceAppliedSequence: 0,
      });
      vm.runInContext(`${source.slice(catalogStart, catalogEnd)}\nthis.applyResourceCatalog = applyResourceCatalog;`, context);

      const catalog = {
        servers: [{
          key: "local",
          agents: [replacementDetail, unrelatedDetail],
          projects: [],
        }],
      };
      if (context.applyResourceCatalog(catalog, { sequence: 1, mutationGeneration: 0 }) !== false ||
          context.state.agents.map((agent) => agent.key).join(",") !== "replacement,unrelated") {
        throw new Error("pre-archive catalog response was not rejected");
      }
      if (context.applyResourceCatalog(catalog, { sequence: 2, mutationGeneration: 1 }) !== true ||
          context.state.agents.map((agent) => agent.key).join(",") !== "replacement,unrelated" ||
          !context.state.archivedAgentCatalogConfirmedKeys.has("source")) {
        throw new Error("fresh catalog response did not preserve replacement state");
      }
      if (quickOptionSyncs !== 1) throw new Error("only accepted catalogs may update open Quick options");
      if (context.applyResourceCatalog(catalog, { sequence: 1, mutationGeneration: 1 }) !== false) {
        throw new Error("older catalog response was not rejected");
      }

      const stale = {
        revision: "before-archive",
        servers: [{
          key: "local",
          ready: true,
          agents: [
            { key: "source", archived: false, running: true, status: "running" },
            { key: "unrelated", archived: false, running: false, status: "idle" },
          ],
        }],
      };
      if (context.applyAgentActivity(stale, 1, 0) !== false) {
        throw new Error("pre-archive activity response was not rejected");
      }
      if (context.state.agents.map((agent) => agent.key).join(",") !== "replacement,unrelated" ||
          context.state.agentDetails.source.archived !== true ||
          context.state.agentDetails.source.running !== false ||
          context.state.activityAppliedSequence !== 0) {
        throw new Error("stale activity response changed post-replacement state");
      }

      context.state.archivedAgentCatalogConfirmedKeys.add("source");
      const fresh = {
        revision: "after-archive",
        servers: [{
          key: "local",
          ready: true,
          agents: [
            { key: "replacement", archived: false, running: false, status: "idle" },
            { key: "unrelated", archived: false, running: false, status: "idle" },
          ],
        }],
      };
      if (context.applyAgentActivity(fresh, 2, 1) !== true ||
          context.state.agents.map((agent) => agent.key).join(",") !== "replacement,unrelated" ||
          context.state.agentDetails.source.archived !== true ||
          context.state.agentDetails.source.running !== false ||
          context.state.archivedAgentKeys.has("source")) {
        throw new Error("fresh activity response did not converge replacement state");
      }

      const future = {
        revision: "future-update",
        servers: [{
          key: "local",
          ready: true,
          agents: [
            { key: "replacement", archived: false, running: true, status: "running" },
            { key: "unrelated", archived: false, running: false, status: "idle" },
          ],
        }],
      };
      if (context.applyAgentActivity(future, 3, 1) !== true ||
          context.state.agentDetails.replacement.running !== true ||
          context.state.agents.find((agent) => agent.key === "replacement")?.running !== true) {
        throw new Error("future activity response was frozen after replacement");
      }
    JAVASCRIPT
    _stdout, stderr, status = Open3.capture3("node", "-e", script, APP_PATH)
    raise "Remote UI activity replacement race regression failed: #{stderr.strip}" unless status.success?

    puts "remote_ui_activity_replacement_race_test: ok"
  end
end

RemoteUIActivityReplacementRaceTest.run!
