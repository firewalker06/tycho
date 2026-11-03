# frozen_string_literal: true

require "open3"

script = <<~'JS'
  const assert = require("node:assert/strict");
  const fs = require("node:fs");
  const vm = require("node:vm");
  const source = fs.readFileSync(process.argv[1], "utf8");
  const deferred = () => {
    let resolve, reject;
    const promise = new Promise((yes, no) => { resolve = yes; reject = no; });
    return { promise, resolve, reject };
  };
  function fixture() {
    const summary = deferred(), schedules = deferred(), detail = [];
    const state = { schedules: [], agents: [], resourceRequestSequence: 0, resourceMutationGeneration: 0,
      setupRequestSequence: 0, setupResponseSequence: 0, setupDetailed: false, setup: null,
      failureCount: 0, initialRouteLoaded: false, timer: null };
    let route = { type: "agent", key: "a" }, renders = 0;
    const c = { state, location: { hash: "#agent/a" }, Date,
      els: { view: { querySelector: () => null }, authPanel: { classList: { add() {}, remove() {} } } },
      clearTimeout() {}, fullScreenEditorOpen: () => false, formPollQuietRemaining: () => 0,
      pollingWindowIsActive: () => true, schedule() {}, preserveWorkspaceDuringPoll: () => false,
      syncFocusedWorkspacePollingSubtitle() {}, setConnection() {}, canSkipCatalogLoad: () => false,
      loadResourceCatalog: async () => ({ revision: "1" }), applyResourceCatalog: () => true,
      parseRoute: () => route, focusedWorkspaceAgent: () => null, shouldOpenSummaryForSucceededAgent: () => false,
      syncBulkArchiveSelection() {}, detailedSetupRoute: () => route.type === "tab",
      agentShellRoute: r => r.type === "agent", CONVERSATION_SHELL_REFRESH_MS: 60000,
      normalizeLocalSchedule: value => value, refreshedText: () => "Updated", focusedWorkspacePollingSubtitle: () => "",
      ensureRouteData: async () => {}, render: () => { renders++; }, syncFocusedWorkspaceCatalog() {},
      syncPendingPromptQueueActions() {}, dismissBootShell() {}, failBootShell() {},
      requestAllServerResourceRefreshes: async () => {},
      apiGet: path => {
        if (path === "/setup/summary") return summary.promise;
        if (path === "/schedules") return schedules.promise;
        assert.equal(path, "/setup");
        const request = deferred(); detail.push(request); return request.promise;
      },
    };
    vm.createContext(c);
    function include(start, end) {
      const a = source.indexOf(start), b = source.indexOf(end, a);
      assert(a >= 0 && b > a); vm.runInContext(source.slice(a, b), c);
    }
    vm.runInContext("const scheduleStateVersions = new Map();", c);
    include("function noteScheduleStateChange(", "\nfunction saveScheduleForm");
    include("async function refresh(options = {})", "\nfunction detailedSetupRoute");
    include("function applySetupResponse(", "\nasync function ensureRouteData");
    return { c, state, summary, schedules, detail, renders: () => renders,
      settings: () => { route = { type: "tab", tab: "settings" }; c.location.hash = "#settings"; } };
  }
  const full = name => ({ setup: { harnesses: [name], tools: ["gh"] } });
  (async () => {
    const f = fixture(), initial = f.c.refresh();
    for (let i = 0; !f.state.initialRouteLoaded && i < 30; i++) await Promise.resolve();
    assert(f.state.initialRouteLoaded && f.renders() > 0, "content must render before shell completion");
    f.settings();
    const detailed = f.c.ensureDetailedSetup();
    f.detail[0].resolve(full("newer")); await detailed;
    assert.equal(f.state.resourceRequestSequence, 1, "setup navigation must not advance catalog generations");
    f.summary.resolve({ setup: { harnesses: [], tools: [] } });
    f.schedules.resolve({ schedules: [{ key: "late-schedule" }] }); await initial;
    assert.equal(f.state.setupDetailed, true);
    assert.equal(f.state.setup.harnesses[0], "newer");
    assert.equal(f.state.schedules[0].key, "late-schedule", "independent schedule data still applies");

    const g = fixture(), oldDetail = g.c.ensureDetailedSetup(), newDetail = g.c.ensureDetailedSetup();
    g.detail[1].resolve(full("latest")); await newDetail;
    g.detail[0].resolve(full("old")); await oldDetail;
    assert.equal(g.state.setup.harnesses[0], "latest", "an older full response is also stale");

    const h = fixture(), failed = h.c.ensureDetailedSetup();
    h.detail[0].reject(Object.assign(Error("temporary setup failure"), { status: 503 }));
    await assert.rejects(failed, /temporary setup failure/);
    assert.equal(h.state.setupResponseSequence, 0, "failed requests do not certify setup readiness");
    assert.equal(h.state.setupDetailed, false);
    const retry = h.c.ensureDetailedSetup(); h.detail[1].resolve(full("retried")); await retry;
    assert.equal(h.state.setupDetailed, true); assert.equal(h.state.setup.harnesses[0], "retried");
  })().catch(error => { console.error(error); process.exitCode = 1; });
JS
out, err, status = Open3.capture3("node", "-e", script, File.expand_path("../lib/hq/remote_ui/assets/app.js", __dir__))
raise "Setup response ordering regression failed: #{out}#{err}" unless status.success?
puts "remote_ui_setup_order_test: ok"
