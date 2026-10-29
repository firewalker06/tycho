# frozen_string_literal: true

require "open3"

script = <<~'JS'
  const assert = require("node:assert/strict");
  const fs = require("node:fs");
  const vm = require("node:vm");
  const source = fs.readFileSync(process.argv[1], "utf8");
  async function check(type) {
    let active = false, failCatalog = false, pauseRoute = false, releaseRoute;
    const calls = { catalog: 0, route: 0, render: 0, sync: 0, timers: 0 };
    const state = { initialRouteLoaded: false, timer: null, fullScreenComposerKeys: new Set(),
      agents: [], resourceRequestSequence: 0, resourceMutationGeneration: 0,
      failureCount: 0, setup: {}, lastShellUpdatedAt: new Date(), setupDetailed: true };
    const c = { state, location: { hash: `#${type}` },
      els: { view: { querySelector: () => null }, authPanel: { classList: { add() {}, remove() {} } } },
      clearTimeout() {}, fullScreenEditorOpen: () => false, formPollQuietRemaining: () => 0,
      pollingWindowIsActive: () => active, schedule: () => { if (active) calls.timers++; },
      parseRoute: () => ({ type }), focusedWorkspacePreservedDuringPoll: () => true,
      syncFocusedWorkspacePollingSubtitle() {}, setConnection() {}, canSkipCatalogLoad: () => false,
      loadResourceCatalog: async () => { calls.catalog++; if (failCatalog) throw Error("initial failure"); return { revision: "1" }; },
      applyResourceCatalog: () => true, focusedWorkspaceAgent: () => null,
      shouldOpenSummaryForSucceededAgent: () => false, syncBulkArchiveSelection() {},
      detailedSetupRoute: () => false, agentShellRoute: () => false,
      CONVERSATION_SHELL_REFRESH_MS: 60000, refreshedText: () => "Updated",
      focusedWorkspacePollingSubtitle: () => "", syncFocusedWorkspaceCatalog: () => { calls.sync++; },
      ensureRouteData: async () => { calls.route++; if (pauseRoute) await new Promise(resolve => { releaseRoute = resolve; }); },
      render: () => { calls.render++; }, syncPendingPromptQueueActions() {}, dismissBootShell() {},
      requestAllServerResourceRefreshes: async () => {}, failBootShell() {},
    };
    vm.createContext(c);
    let start = source.indexOf("function preserveWorkspaceDuringPoll(options = {})");
    let end = source.indexOf("\nfunction focusedWorkspacePreservedDuringPoll", start);
    vm.runInContext(source.slice(start, end), c);
    start = source.indexOf("async function refresh(options = {})");
    end = source.indexOf("\nfunction detailedSetupRoute", start);
    vm.runInContext(source.slice(start, end), c);
    await c.refresh(); assert.equal(calls.catalog, 0, "inactive cold load stays gated");
    active = true; failCatalog = true;
    await c.refresh(); assert.equal(state.initialRouteLoaded, false, "failure must not enable preservation");
    failCatalog = false; pauseRoute = true;
    const loading = c.refresh();
    for (let i = 0; !releaseRoute && i < 20; i++) await Promise.resolve();
    assert.equal(typeof releaseRoute, "function", `${type}: cold route data must load`);
    active = false; const timers = calls.timers; releaseRoute(); await loading;
    assert.equal(state.initialRouteLoaded, false, "blur during route load must leave initialization pending");
    assert.equal(calls.timers, timers); // No timer resurrection.
    const renders = calls.render;
    active = true; pauseRoute = false;
    await c.refresh();
    assert.equal(state.initialRouteLoaded, true, `${type}: retry initializes`);
    assert.equal(calls.render, renders + 1, `${type}: full render required`);
    const routeCalls = calls.route, renderCalls = calls.render;
    await c.refresh();
    assert.equal(calls.route, routeCalls, `${type}: later polls preserve route data`);
    assert.equal(calls.render, renderCalls, `${type}: later polls preserve DOM`);
    assert.equal(calls.sync, 1);
  }
  (async () => { for (const type of ["attachment", "agentAttachment", "projectDiff", "agentPullRequests"]) await check(type); })()
    .catch(error => { console.error(error); process.exitCode = 1; });
JS
out, err, status = Open3.capture3("node", "-e", script, File.expand_path("../lib/hq/remote_ui/assets/app.js", __dir__))
raise "Cold workspace regression failed: #{out}#{err}" unless status.success?
puts "remote_ui_cold_workspace_test: ok"
