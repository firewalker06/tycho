# frozen_string_literal: true

require "open3"

module RemoteUIOptimisticArchiveTest
  module_function

  def run!
    script = <<~'JS'
      const assert = require("node:assert/strict");
      const fs = require("node:fs");
      const vm = require("node:vm");
      const source = fs.readFileSync(process.argv[1], "utf8");
      const extract = (name) => {
        const start = source.indexOf(`\nfunction ${name}(`) + 1;
        const end = source.indexOf("\n}\n", start) + 3;
        assert(start > 0 && end > start, `missing ${name}`);
        return source.slice(start, end);
      };
      const extractAsync = (name) => {
        const start = source.indexOf(`\nasync function ${name}(`) + 1;
        const end = source.indexOf("\n}\n", start) + 3;
        assert(start > 0 && end > start, `missing ${name}`);
        return source.slice(start, end);
      };
      const deferred = () => {
        let resolve;
        let reject;
        const promise = new Promise((res, rej) => { resolve = res; reject = rej; });
        return { promise, resolve, reject };
      };
      const makeContext = (agents) => {
        const calls = [];
        const context = {
          calls,
          state: {
            agents: agents.map(agent => ({ ...agent })),
            agentDetails: {},
            activityAgents: new Map(),
            activityRevision: null,
            activityReadyServerKeys: new Set(),
            archivedAgentKeys: new Set(),
            archivedAgentCatalogConfirmedKeys: new Set(),
            resourceMutationGeneration: 0,
            bulkArchiveSelection: new Set(),
            bulkArchiveMode: true,
            bulkArchiveMenuOpen: true,
          },
          render: () => calls.push(["render"]),
          reconcileOptimisticPromptQueue: () => {},
          activityFields: agent => ({ key: agent.key }),
          setConnection: () => {},
          showGrowl: (message, kind) => calls.push(["growl", message, kind]),
          navigate: route => calls.push(["navigate", route.tab || route.key]),
          findAgent: key => context.state.agents.find(agent => agent.key === key) || null,
        };
        vm.createContext(context);
        vm.runInContext([
          extract("removeAgent"), extract("retireArchivedAgent"), extract("upsertAgent"),
          extract("retireAgentsOptimistically"), extract("restoreRetiredAgents"),
        ].join("\n"), context);
        return context;
      };

      // Single archive: the agent leaves the list before the request settles, and comes back on failure.
      {
        const context = makeContext([{ key: "a", name: "A" }, { key: "b", name: "B" }]);
        const pending = context.retireAgentsOptimistically(["a"]);
        assert.deepEqual(context.state.agents.map(agent => agent.key), ["b"], "Archived agent must leave immediately");
        assert(context.state.archivedAgentKeys.has("a"), "Archived key must be tracked to suppress refresh resurrection");
        assert(context.calls.some(call => call[0] === "render"), "Optimistic removal must render at once");
        context.restoreRetiredAgents(pending);
        assert.deepEqual(context.state.agents.map(agent => agent.key).sort(), ["a", "b"], "Failure must restore the agent");
        assert(!context.state.archivedAgentKeys.has("a"), "Failure must clear the archived marker");
        assert.equal(context.state.agentDetails.a.archived, undefined, "Restored agent must not stay marked archived");
        assert.equal(pending.size, 0, "Restored entries must not be restored twice");
      }

      // Bulk archive: only server-confirmed keys stay archived; skipped keys come back.
      {
        const context = makeContext([{ key: "a" }, { key: "b" }, { key: "c" }]);
        const pending = context.retireAgentsOptimistically(["a", "b"]);
        assert.deepEqual(context.state.agents.map(agent => agent.key), ["c"]);
        context.restoreRetiredAgents(pending, key => key !== "a");
        assert.deepEqual(context.state.agents.map(agent => agent.key).sort(), ["b", "c"]);
        assert(context.state.archivedAgentKeys.has("a"), "Confirmed archive must stay archived");
        assert.deepEqual([...pending.keys()], ["a"], "Confirmed entries stay pending until the request completes");
        pending.clear();
      }

      (async () => {
        // Single archive action: UI moves at click time, the request runs in the background, failure restores.
        const runAgentAction = extractAsync("runAgentAction");
        for (const outcome of ["ok", "rejected"]) {
          const context = makeContext([{ key: "a", name: "A" }]);
          const request = deferred();
          context.mutate = (callback, options = {}) => {
            context.calls.push(["mutate"]);
            context.pending = callback().then(() => {}, error => {
              options.onError?.(error);
              throw error;
            });
          };
          context.apiPost = (path) => { context.calls.push(["post", path]); return request.promise; };
          context.confirmAction = async () => true;
          context.serverDisplayName = () => "local";
          context.resourceServer = () => null;
          vm.runInContext(runAgentAction, context);
          const agentAction = { dataset: { agentKey: "a", agentAction: "archive" } };
          const run = context.runAgentAction(agentAction);
          await run;
          assert.deepEqual(context.state.agents, [], "Archive must remove the agent before the request settles");
          assert(context.calls.some(call => call[0] === "navigate" && call[1] === "agents"), "Archive must leave the detail page at once");
          if (outcome === "ok") {
            request.resolve({});
            await context.pending;
            assert.deepEqual(context.state.agents, [], "Successful archive must keep the agent removed");
          } else {
            request.reject(new Error("Agent is busy"));
            await assert.rejects(context.pending, /Agent is busy/);
            assert.deepEqual(context.state.agents.map(agent => agent.key), ["a"], "Failed archive must restore the agent");
            assert(context.calls.some(call => call[0] === "growl" && /Archive failed: Agent is busy/.test(call[1]) && call[2] === "fail"),
              "Failed archive must show a useful error");
          }
        }
        // Bulk archive across two servers: a failed group must not restore an agent the other server archived.
        const archiveSelectedAgents = extractAsync("archiveSelectedAgents");
        for (const scenario of ["ok", "partial"]) {
          const context = makeContext([{ key: "a", server_key: "s1" }, { key: "b", server_key: "s2" }]);
          context.state.bulkArchiveSelection = new Set(["a", "b"]);
          context.selectedBulkArchiveKeys = () => ["a", "b"];
          context.confirmAction = async () => true;
          context.arrayValue = value => value || [];
          context.serverDisplayName = () => "Server";
          context.resourceServer = serverKey => ({ key: serverKey });
          context.resourceApiPath = (serverKey, path) => `${serverKey}:${path}`;
          context.resourceHeaders = () => ({});
          context.resourceRawKey = key => key;
          context.resourceClientKey = (serverKey, key) => key;
          context.readJson = async response => response.body;
          context.fetch = async path => {
            if (path.startsWith("s1:")) return { body: { archived: [{ agent_key: "a" }] } };
            if (scenario === "partial") throw new Error("server s2 unreachable");
            return { body: { archived: [{ agent_key: "b" }] } };
          };
          context.mutate = (callback, options = {}) => {
            context.pending = Promise.resolve().then(callback).catch(error => {
              options.onError?.(error);
              throw error;
            });
          };
          vm.runInContext(archiveSelectedAgents, context);
          await context.archiveSelectedAgents();
          await context.pending;
          const shown = context.state.agents.map(agent => agent.key).sort();
          if (scenario === "ok") {
            assert.deepEqual(shown, [], "Successful bulk archive must keep both agents removed");
          } else {
            assert.deepEqual(shown, ["b"], "Failed group must restore only its own agent");
            assert(context.state.archivedAgentKeys.has("a"), "Agent archived by the healthy server must stay archived");
            assert(!context.state.archivedAgentKeys.has("b"), "Unconfirmed agent must not stay archived");
            assert(context.calls.some(call => call[0] === "growl" && /Archive failed for some agents/.test(call[1]) && call[2] === "fail"),
              "Partial bulk failure must show an error");
          }
        }
        console.log("remote_ui_optimistic_archive_test: ok");
      })().catch(error => { console.error(error); process.exit(1); });
    JS
    app_path = File.expand_path("../lib/hq/remote_ui/assets/app.js", __dir__)
    out, err, status = Open3.capture3("node", "-e", script, app_path)
    raise "Optimistic archive UI regression failed:\n#{out}#{err}" unless status.success?

    puts out unless out.empty?
  end
end

RemoteUIOptimisticArchiveTest.run! if $PROGRAM_NAME == __FILE__
