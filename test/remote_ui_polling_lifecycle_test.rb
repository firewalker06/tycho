# frozen_string_literal: true

require "open3"

script = <<~'JS'
  const assert = require("node:assert/strict");
  const fs = require("node:fs");
  const vm = require("node:vm");
  const source = fs.readFileSync(process.argv[1], "utf8");
  let id = 0, focused = false, hidden = false, activityCalls = 0, catalogCalls = 0;
  let finishActivity, finishCatalog, rejectCatalog;
  const timers = new Map();
  const context = {
    document: { get hidden() { return hidden; }, hasFocus: () => focused },
    window: { scrollY: 10 }, location: { hash: "#agents" },
    state: { timer: null, activityTimer: null, activityRequestSequence: 0, resourceRequestSequence: 0,
      resourceMutationGeneration: 0, failureCount: 0 },
    setTimeout: (fn, ms) => { timers.set(++id, { fn, ms }); return id; },
    clearTimeout: (key) => timers.delete(key),
    pollDelay: () => 100, agentActivityDelay: () => 50,
    fullScreenEditorOpen: () => false, formPollQuietRemaining: () => 0,
    updateQueueEligibilityLabels() {}, showNav() {}, applyAgentActivity() {},
    brokerGet: () => { activityCalls++; return new Promise(resolve => { finishActivity = resolve; }); },
    preserveWorkspaceDuringPoll: () => false, canSkipCatalogLoad: () => false,
    loadResourceCatalog: () => { catalogCalls++; return new Promise((resolve, reject) => { finishCatalog = resolve; rejectCatalog = reject; }); },
    setConnection() {}, render() {}, failBootShell() {}, bootError() {},
  };
  vm.createContext(context);
  const start = source.indexOf("let pollingWindowActive = false;");
  const end = source.indexOf("\nfunction fullScreenEditorOpen", start);
  vm.runInContext(source.slice(start, end), context);
  const refreshStart = source.indexOf("async function refresh(options = {})");
  const refreshEnd = source.indexOf("\nfunction detailedSetupRoute", refreshStart);
  vm.runInContext(source.slice(refreshStart, refreshEnd), context);
  async function run() {
    context.syncPollingWindow();
    await context.refresh(); await context.pollAgentActivity();
    assert.equal(timers.size, 0); assert.equal(catalogCalls + activityCalls, 0, "inactive boot");
    focused = true;
    context.syncPollingWindow(); context.syncPollingWindow();
    assert.equal(timers.size, 2, "one timer per loop on repeated focus");
    const pendingRefresh = context.refresh(), pendingActivity = context.pollAgentActivity();
    assert.equal(catalogCalls, 1); assert.equal(activityCalls, 1);
    focused = false; context.syncPollingWindow();
    assert.equal(timers.size, 0, "visible blur clears both timers");
    finishActivity({}); finishCatalog({});
    await Promise.all([pendingRefresh, pendingActivity]);
    assert.equal(timers.size, 0, "in-flight finally cannot resurrect timers");
    context.schedule(); context.scheduleAgentActivity();
    assert.equal(timers.size, 0, "all scheduling callers use activity gate");
    focused = true; hidden = true; context.syncPollingWindow();
    assert.equal(timers.size, 0, "hidden focus remains inactive");
    hidden = false; context.syncPollingWindow();
    assert.equal(timers.size, 2);
    const activity = context.pollAgentActivity();
    focused = false; context.syncPollingWindow(); focused = true;
    context.syncPollingWindow(); context.syncPollingWindow();
    assert.equal(activityCalls, 2, "return does not overlap existing request");
    assert.equal(timers.size, 1);
    finishActivity({}); await activity;
    assert.equal(timers.size, 2, "in-flight request restores its own cadence");
    focused = false; context.syncPollingWindow();
    const manual = context.pollAgentActivity({ manual: true });
    assert.equal(activityCalls, 3, "explicit activity refresh works inactive");
    finishActivity({}); await manual;
    assert.equal(timers.size, 0);
    const manualRefresh = context.refresh({ force: true });
    assert.equal(catalogCalls, 2, "explicit full refresh works inactive");
    // A rejected manual request exercises the normal error/finally path.
    rejectCatalog(new Error("Synthetic request failure")); await manualRefresh;
    assert.equal(context.state.failureCount, 1);
    assert.equal(timers.size, 0);
    focused = true; context.syncPollingWindow();
    assert.equal(timers.size, 2, "focus recovers after an error");
    // Even an already dequeued callback must check current focus before fetching.
    const callbacks = [...timers.values()].map(item => item.fn);
    focused = false;
    await Promise.all(callbacks.map(fn => fn()));
    assert.equal(catalogCalls, 2); assert.equal(activityCalls, 3);
  }
  run().catch(error => { console.error(error); process.exitCode = 1; });
JS
out, err, status = Open3.capture3("node", "-e", script, File.expand_path("../lib/hq/remote_ui/assets/app.js", __dir__))
raise "Polling lifecycle regression failed: #{out}#{err}" unless status.success?
puts "remote_ui_polling_lifecycle_test: ok"
