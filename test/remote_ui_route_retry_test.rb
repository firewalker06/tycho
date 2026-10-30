# frozen_string_literal: true

require "open3"

script = <<~'JS'
  const assert = require("node:assert/strict");
  const fs = require("node:fs");
  const vm = require("node:vm");
  const source = fs.readFileSync(process.argv[1], "utf8");
  function fixture(type, status, image = false) {
    let active = true, failing = true, route = { type, key: "web", scope: "worktree", id: "file", attachmentId: "file" };
    let calls = 0;
    const state = { initialRouteLoaded: false, projectDiffs: {}, pullRequests: {}, attachmentDetails: {}, attachmentRequestGenerations: {},
      attachmentImageErrors: {}, attachmentImageErrorStatuses: {}, attachmentImageRequestGenerations: {}, attachmentImageUrls: {},
      agents: [], resourceRequestSequence: 0, resourceMutationGeneration: 0, failureCount: 0, setup: {}, lastShellUpdatedAt: new Date(), setupDetailed: true };
    const request = async () => { calls++; if (failing) throw Object.assign(Error("endpoint failed"), status !== undefined ? { status } : {});
      return { diff: { files: [] }, pull_requests: [], attachment: { kind: "file", format: "markdown", content: "Loaded" } }; };
    const c = { state, location: { hash: `#${type}`, href: "http://fixture/ui", origin: "http://fixture" }, globalThis: {},
      els: { view: { querySelector: () => null }, authPanel: { classList: { add() {}, remove() {} } } },
      clearTimeout() {}, fullScreenEditorOpen: () => false, formPollQuietRemaining: () => 0,
      pollingWindowIsActive: () => active, schedule() {}, parseRoute: () => route,
      focusedWorkspacePreservedDuringPoll: () => true, syncFocusedWorkspacePollingSubtitle() {},
      setConnection() {}, canSkipCatalogLoad: () => false, loadResourceCatalog: async () => ({ revision: "1" }), applyResourceCatalog: () => true,
      focusedWorkspaceAgent: () => null, shouldOpenSummaryForSucceededAgent: () => false, syncBulkArchiveSelection() {},
      detailedSetupRoute: () => false, agentShellRoute: r => r.type === "agentPullRequests" || r.type === "agentAttachment",
      normalizeLocalSchedule: x => x, CONVERSATION_SHELL_REFRESH_MS: 60000, refreshedText: () => "Updated", focusedWorkspacePollingSubtitle: () => "",
      syncFocusedWorkspaceCatalog() {}, render() {}, syncPendingPromptQueueActions() {}, dismissBootShell() {},
      requestAllServerResourceRefreshes: async () => {}, failBootShell() {},
      cancelBackgroundPullRequestDiffFetchesExcept() {}, ensureAgentDetail: async () => {}, findAgent: () => null,
      ensureProject: async () => {}, projectDiffKey: (key, scope) => `${key}:${scope}`, normalizeDiffScope: scope => scope,
      apiGet: path => /^\/(setup|schedules)/.test(path) ? Promise.resolve({ setup: {}, schedules: [] }) : image ? (calls++, Promise.resolve({ attachment: { kind: "file", format: "image" } })) : request(),
      apiBlob: request, attachmentBlobPath: () => "/blob", URL: { createObjectURL: () => "blob:fixture", revokeObjectURL() {} }, selectedPullRequestId: () => "", preloadSavedPullRequestDiffs() {},
      attachmentById: () => null, attachmentKind: a => a?.kind, attachmentFormat: a => a?.format,
    };
    vm.createContext(c);
    function include(start, end) { const a = source.indexOf(start), b = source.indexOf(end, a); assert(a >= 0 && b > a); vm.runInContext(source.slice(a, b), c); }
    include("function preserveWorkspaceDuringPoll(options = {})", "\nfunction focusedWorkspacePreservedDuringPoll");
    include("async function refresh(options = {})", "\nfunction detailedSetupRoute");
    // Includes the real route dispatcher and its initialization helpers.
    include("async function ensureRouteData(options = {})", "\nasync function ensureAgentDetail");
    include("async function ensureProjectDiff(", "\nasync function ensurePullRequestDiff");
    include("async function ensureAttachment(id,", "\nfunction revokeAttachmentImageUrls");
    include("async function ensureAttachmentPreview(", "\nasync function ensureProject(");
    return { c, state, calls: () => calls, healthy: () => { failing = false; }, focus: value => { active = value; } };
  }
  (async () => {
    for (const type of ["projectDiff", "agentPullRequests", "attachment", "agentAttachment"]) {
      for (const status of [503, undefined, 0, 408, 429, 404]) {
        const f = fixture(type, status);
        await f.c.refresh();
        assert.equal(f.state.initialRouteLoaded, false, `${type} ${status}: cached endpoint error is not initialization success`);
        assert.equal(f.state.failureCount, 1);
        assert.equal(f.calls(), 1);
        f.healthy(); f.focus(false); await f.c.refresh(); assert.equal(f.calls(), 1, "inactive retry stays gated");
        f.focus(true); await f.c.refresh();
        if (status === 404) {
          assert.equal(f.calls(), 1, "permanent errors do not produce route request storms");
          assert.equal(f.state.initialRouteLoaded, false);
          await f.c.refresh({ force: true, forcePullRequests: true, forceAttachment: true });
        }
        assert.equal(f.calls(), 2, `${type}: next active attempt must retry actual endpoint`);
        assert.equal(f.state.initialRouteLoaded, true);
        assert.equal(f.state.failureCount, 0);
        await f.c.refresh(); assert.equal(f.calls(), 2, "loaded workspace remains preserved");
      }
    }
    for (const status of [503, undefined]) {
      const f = fixture("agentAttachment", status, true);
      await f.c.refresh(); assert.equal(f.state.initialRouteLoaded, false, "image preview failure is not ready");
      assert.equal(f.calls(), 2); // Metadata succeeded, real image loader failed.
      f.healthy(); await f.c.refresh(); assert.equal(f.state.initialRouteLoaded, true);
      assert.equal(f.calls(), 3, "retry blob without refetching healthy metadata");
      await f.c.refresh(); assert.equal(f.calls(), 3);
    }
    for (const type of ["projectDiff", "agentPullRequests"]) {
      const f = fixture(type, 503);
      await f.c.refresh(); await f.c.refresh();
      assert.equal(f.state.failureCount, 2, "route failures retain normal backoff progression");
      assert.equal(f.calls(), 2); f.healthy(); await f.c.refresh();
      assert.equal(f.state.failureCount, 0); assert.equal(f.state.initialRouteLoaded, true);
    }
    const permanentImage = fixture("agentAttachment", 404, true);
    await permanentImage.c.refresh(); await permanentImage.c.refresh();
    assert.equal(permanentImage.state.initialRouteLoaded, false); assert.equal(permanentImage.calls(), 2);
    for (const staleFailure of [false, true]) {
      const f = fixture("projectDiff", 503); f.healthy();
      let release;
      const original = f.c.apiGet;
      f.c.apiGet = path => path.includes("git/diff") ? new Promise((resolve, reject) => {
        release = () => staleFailure ? reject(Object.assign(Error("old route failed"), { status: 503 })) : resolve({ diff: { files: [] } });
      }) : original(path);
      const pending = f.c.refresh();
      for (let i = 0; !release && i < 30; i++) await Promise.resolve();
      assert.equal(typeof release, "function");
      f.c.location.hash = "#pr";
      f.c.parseRoute = () => ({ type: "agentPullRequests", key: "other" });
      release(); await pending;
      assert.equal(f.state.initialRouteLoaded, false, "stale success or error cannot initialize the new route");
      await f.c.refresh(); assert.equal(f.state.initialRouteLoaded, true);
      assert(f.state.pullRequests.other && !f.state.pullRequests.other.error);
    }
  })().catch(error => { console.error(error); process.exitCode = 1; });
JS
out, err, status = Open3.capture3("node", "-e", script, File.expand_path("../lib/hq/remote_ui/assets/app.js", __dir__))
raise "Route endpoint retry regression failed: #{out}#{err}" unless status.success?
puts "remote_ui_route_retry_test: ok"
