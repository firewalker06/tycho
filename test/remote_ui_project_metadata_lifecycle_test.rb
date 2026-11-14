# frozen_string_literal: true

require "open3"

script = <<~'JS'
  const assert = require("node:assert/strict");
  const fs = require("node:fs");
  const vm = require("node:vm");
  const source = fs.readFileSync(process.argv[1], "utf8");
  const section = (start, end) => {
    const a = source.indexOf(start), b = source.indexOf(end, a);
    assert(a >= 0 && b > a, `missing app section: ${start}`);
    return source.slice(a, b);
  };
  function fixture() {
    let route = { type: "project", key: "p1" }, active = true, nextTimer = 0;
    const requests = [], timers = new Map(), events = new Map();
    const c = {
      state: { projectDetails: {}, fullScreenComposerKeys: new Set(), fullScreenInquiryKeys: new Set() },
      location: { hash: "#project/p1" }, AbortController,
      apiGet: (path, options) => new Promise((resolve, reject) => requests.push({ path, options, resolve, reject })),
      setTimeout: (callback) => { timers.set(++nextTimer, callback); return nextTimer; },
      clearTimeout: (timer) => timers.delete(timer),
      pollingWindowIsActive: () => active,
      parseRoute: () => route,
      focusedWorkspaceAgent: () => null, findAgent: () => null,
      render: () => { c.renders++; }, renders: 0,
      window: { addEventListener: (name, handler) => events.set(name, handler), scrollY: 0 },
      document: { hidden: false, body: { dataset: {} }, addEventListener: (name, handler) => events.set(name, handler) },
      flushComposerDraftSaves() {}, saveAgentShellFormDrafts() {}, schedule() {},
      closeUnreadPanel() {}, showNav() {}, resetPullRequestDiffRender() {},
      ensureRouteData: async () => {}, setConnection() {}, syncPollingWindow() {}, stopSpeechMode() {},
    };
    vm.createContext(c);
    vm.runInContext("let promptQueueNavigationGeneration = 0, scheduleFormNavigationGeneration = 0, projectCreationRouteGeneration = 0;\n" +
      section("let projectMetadataTimer = null;", "\nfunction projectWorkspaceKey") +
      section('window.addEventListener("hashchange",', '\nwindow.addEventListener("scroll",') +
      section('document.addEventListener("visibilitychange",', '\nwindow.matchMedia("(prefers-reduced-motion:'), c);
    return { c, requests, timers,
      route(value) { route = value; c.location.hash = value.type === "project" ? `#project/${value.key}` : "#agents"; events.get("hashchange")(); },
      active(value) { active = value; events.get(value ? "focus" : "blur")(); },
      hide() { c.document.hidden = true; events.get("visibilitychange")(); },
      close() { events.get("pagehide")(); },
      show() { events.get("pageshow")?.(); },
      async response(index, refreshing, branch = "main") {
        requests[index].resolve({ project: { key: requests[index].path.split("/").pop(), git_metadata_refreshing: refreshing, branch } });
        await Promise.resolve(); await Promise.resolve();
      },
      async fireTimer() {
        const [id, callback] = timers.entries().next().value;
        timers.delete(id); const running = callback(); await Promise.resolve(); return { running };
      },
    };
  }
  async function main() {
    const controller = new AbortController();
    let fetchSignal;
    const api = {
      resourceRequest: path => ({ path, server: { key: "local" } }),
      resourceHeaders: () => ({}),
      notificationTraceRequest: (_, __, send) => send(),
      fetch: async (_, options) => { fetchSignal = options.signal; },
    };
    vm.runInNewContext(section("async function apiGet(", "\nasync function brokerGet("), api);
    await api.apiGet("/projects/p1", { signal: controller.signal });
    assert.equal(fetchSignal, controller.signal, "the real API reader must pass the abort signal to fetch");

    const leaving = fixture();
    const old = leaving.c.ensureProject("p1", true);
    leaving.route({ type: "tab", tab: "agents" });
    await leaving.response(0, true); await old;
    assert.equal(leaving.timers.size, 0, "late detail response on Agents must not schedule metadata Git demand");
    assert.equal(leaving.c.state.projectDetails.p1, undefined, "departed response must not publish metadata");
    assert.equal(leaving.requests[0].options.signal.aborted, true, "navigation must abort the old HTTP read");
    await leaving.c.ensureProject("p1", true);
    assert.equal(leaving.requests.length, 1, "a stale caller must not request a project absent from the current view");

    for (const boundary of ["navigation", "blur", "hidden", "close"]) {
      const f = fixture();
      const stale = f.c.ensureProject("p1", true);
      if (boundary === "navigation") { f.route({ type: "tab", tab: "agents" }); f.route({ type: "project", key: "p1" }); }
      if (boundary === "blur") { f.active(false); f.active(true); }
      if (boundary === "hidden") { f.hide(); f.c.document.hidden = false; f.active(true); }
      if (boundary === "close") { f.close(); f.show(); }
      const current = f.c.ensureProject("p1", true);
      await f.response(1, false, "current"); await current;
      await f.response(0, true, "old"); await stale;
      assert.equal(f.c.state.projectDetails.p1.branch, "current", `${boundary}: late response overwrote the new visit`);
      assert.equal(f.timers.size, 0, `${boundary}: late response rearmed a timer after return`);
      assert(f.requests[0].options.signal.aborted, `${boundary}: pending request was not aborted`);
    }

    const switched = fixture();
    const p1 = switched.c.ensureProject("p1", true);
    switched.route({ type: "project", key: "p2" });
    const p2 = switched.c.ensureProject("p2", true);
    await switched.response(1, true); await p2;
    const timer = [...switched.timers.keys()][0];
    await switched.response(0, true); await p1;
    assert.deepEqual([...switched.timers.keys()], [timer], "old view must not replace the current view's timer");
    const renders = switched.c.renders;
    const { running } = await switched.fireTimer();
    assert.equal(switched.requests[2].path, "/projects/p2", "only the current project may poll");
    await switched.response(2, false); await running;
    assert.equal(switched.c.renders, renders + 1, "active metadata completion must still render");

    const failure = fixture();
    const pending = failure.c.ensureProject("p1", true);
    failure.route({ type: "tab", tab: "agents" });
    failure.requests[0].reject(new Error("late network failure"));
    await pending;
    assert.equal(failure.timers.size, 0, "late failures must not restart polling");
    console.log("project metadata lifecycle: late responses, return visits, blur, hide, close, active polling, and aborts passed");
  }
  main().catch(error => { console.error(error); process.exitCode = 1; });
JS
out, err, status = Open3.capture3("node", "-e", script, File.expand_path("../lib/hq/remote_ui/assets/app.js", __dir__))
raise "Project metadata lifecycle regression failed:\n#{out}#{err}" unless status.success?

puts "remote_ui_project_metadata_lifecycle_test: ok"
