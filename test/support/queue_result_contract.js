const assert = require("node:assert/strict");
const fs = require("node:fs");
const vm = require("node:vm");
const source = fs.readFileSync(process.argv[2], "utf8");
const fn = name => source.match(new RegExp(`^(?:async )?function ${name}\\([^]*?^}`, "m"))[0];
const functions = ["promptQueueSelection", "promptQueueActionResult", "promptQueueActionMessage", "runPromptQueueAction", "reconcilePromptQueueAction", "inquiryAnswerDisplayState", "inquiryAnswerDisplayUnchanged", "agentDetailGeneration", "ensureAgentDetail"].map(fn).join("\n");
let cases = 0;
function fixture(kind = "process") {
  let resolve, reject, reads = 0, writes = 0, refreshes = 0;
  const agent = { key: "fixture", name: "Original agent", running: false, prompt_queue: { entries: [{ id: "a" }, { id: "b" }], processing: { message: "Waiting for the workspace." } } };
  const selection = new Set(["a", "b"]);
  const state = { agents: [agent], agentDetails: { fixture: agent }, activityAgents: new Map(), agentDetailGenerations: new Map(),
    resourceMutationGeneration: 0, promptQueueSelections: new Map([["fixture", selection]]), pendingPromptQueueActions: new Map() };
  const messages = [], applied = [];
  const c = { state, console, location: { hash: "#agent/fixture" }, clearTimeout, arrayValue: x => x || [],
    findAgent: () => state.agentDetails.fixture, render() {}, schedule() {}, syncPendingPromptQueueActions() {},
    reconcileOptimisticPromptQueue() {}, confirmAction: async () => true, showGrowl: (message, level) => messages.push({ message, level }),
    upsertAgent: value => { applied.push(value); state.agentDetails.fixture = value; },
    apiPost: async (path, body) => { writes++; assert.deepEqual(JSON.parse(JSON.stringify(body)), { entry_ids: ["a", "b"], expected_entry_ids: ["a", "b"] }); return new Promise((yes, no) => { resolve = yes; reject = no; }); },
    apiGet: async () => { reads++; return c.readResponse; },
    refresh: async () => { refreshes++; },
  };
  vm.createContext(c);
  vm.runInContext(`let promptQueueNavigationGeneration = 0;\n${functions}`, c);
  const run = code => vm.runInContext(code, c);
  const response = (status = "accepted", ids = ["a", "b"]) => {
    const resultAgent = structuredClone(agent);
    resultAgent.running = status === "started";
    if (status === "removed") resultAgent.prompt_queue.entries = resultAgent.prompt_queue.entries.filter(entry => !ids.includes(entry.id));
    return { status, [kind === "remove" ? "removed_entry_ids" : "processed_entry_ids"]: ids,
      current_entry_ids: resultAgent.prompt_queue.entries.map(entry => entry.id), agent: resultAgent };
  };
  return { c, state, selection, messages, applied, run, response,
    start: async () => { const promise = run(`runPromptQueueAction({dataset:{agentKey:"fixture",queueAction:"${kind}-selected"}})`); await new Promise(resolve => setImmediate(resolve)); return { promise }; },
    finish: async (pending, value) => { resolve(value); await pending.promise; },
    fail: async pending => { reject(Error("Synthetic network/peer error")); await pending.promise; },
    stats: () => ({ reads, writes, refreshes }),
  };
}
(async () => {
  for (const kind of ["process", "remove"]) {
    for (const status of kind === "process" ? ["started", "accepted", "stale"] : ["removed", "stale"]) {
      for (const partial of [false, true]) {
        const f = fixture(kind), p = await f.start();
        await f.start(); assert.equal(f.stats().writes, 1, "one pending mutation");
        const ids = status === "stale" ? [] : partial ? ["a"] : ["a", "b"];
        await f.finish(p, f.response(status, ids));
        assert.equal(f.state.pendingPromptQueueActions.size, 0);
        assert.equal(f.selection.size, 2 - ids.length);
        assert.equal(f.applied.length, 1);
        const message = f.messages.at(-1).message;
        assert(message.startsWith("Original agent:"));
        if (status === "accepted") assert(message.includes("Accepted") && !message.includes("Started"));
        if (status === "started") assert(message.includes("Started"));
        if (partial && status !== "stale") assert(message.includes("1 of 2 selected"));
        cases++;
      }
    }
    const mutations = [r => ({}), r => null, r => ({ ...r, status: "unknown" }), r => ({ ...r, agent: { ...r.agent, key: "other" } }),
      r => ({ ...r, agent: { ...r.agent, running: "true" } }), r => ({ ...r, status: "started", agent: { ...r.agent, running: false } }), r => ({ ...r, current_entry_ids: ["wrong"] }),
      r => ({ ...r, [kind === "remove" ? "removed_entry_ids" : "processed_entry_ids"]: ["foreign"] }),
      r => ({ ...r, [kind === "remove" ? "removed_entry_ids" : "processed_entry_ids"]: ["a", "a"] }),
      r => ({ ...r, [kind === "remove" ? "removed_entry_ids" : "processed_entry_ids"]: [] }),
      r => ({ ...r, agent: { ...r.agent, prompt_queue: {} } })];
    for (const alter of mutations) {
      const f = fixture(kind), p = await f.start();
      await f.finish(p, alter(f.response(kind === "remove" ? "removed" : "accepted")));
      assert.equal(f.state.pendingPromptQueueActions.get("fixture").phase, "uncertain");
      assert.deepEqual([...f.selection], ["a", "b"]);
      assert.equal(f.applied.length, 0);
      assert(f.messages.at(-1).message.includes("not confirmed"));
      await f.start(); assert.equal(f.stats().writes, 1, "uncertain action cannot replay");
      // Bad reads retain the barrier; a valid canonical read releases controls without writing.
      f.c.readResponse = {};
      await f.run('reconcilePromptQueueAction("fixture")');
      assert.equal(f.state.pendingPromptQueueActions.get("fixture").phase, "uncertain");
      f.c.readResponse = { agent: f.response("accepted").agent };
      await f.run('reconcilePromptQueueAction("fixture")');
      assert.equal(f.state.pendingPromptQueueActions.size, 0);
      assert.equal(f.stats().writes, 1);
      cases++;
    }
    for (const change of ["detail", "activity", "navigation", "selection", "selection-replace", "archive", "in-place", "navigation-aba"]) {
      const f = fixture(kind), p = await f.start();
      if (change === "in-place") f.state.agentDetails.fixture.name = "Newer in-place name";
      if (change === "navigation-aba") f.run('promptQueueNavigationGeneration += 2');
      if (change === "detail") f.state.agentDetails.fixture = { ...f.state.agentDetails.fixture, name: "Newer" };
      if (change === "activity") f.state.activityAgents.set("fixture", { running: false, run_count: 8 });
      if (change === "navigation") f.run('promptQueueNavigationGeneration++; location.hash="#agent/other"');
      if (change === "selection") f.selection.add("newer");
      if (change === "selection-replace") f.state.promptQueueSelections.set("fixture", new Set(["a", "newer"]));
      if (change === "archive") f.state.archivedAgentKeys = new Set(["fixture"]);
      await f.finish(p, f.response(kind === "remove" ? "removed" : "started"));
      if (!["selection", "selection-replace"].includes(change)) assert.equal(f.applied.length, 0, "late projection cannot replace newer state");
      if (["navigation", "selection"].includes(change)) assert(f.selection.has("a"));
      if (change === "selection-replace") assert.deepEqual([...f.state.promptQueueSelections.get("fixture")], ["a", "newer"]);
      assert(f.messages.at(-1).message.startsWith("Original agent:"));
      cases++;
    }
    const f = fixture(kind), p = await f.start(); await f.fail(p);
    assert.equal(f.state.pendingPromptQueueActions.get("fixture").phase, "uncertain");
    assert.equal(f.selection.size, 2); assert.equal(f.stats().writes, 1); cases++;
  }
  const f = fixture(), p = await f.start(), result = f.response();
  result.agent.prompt_queue.dispatch_error = { message: "Synthetic native launch refusal" };
  await f.finish(p, result);
  assert(f.messages.at(-1).message.includes("Dispatch failed"));
  assert(f.messages.at(-1).message.includes("Retry queue")); cases++;
  for (const kind of ["process", "remove"]) {
    const f = fixture(kind), p = await f.start(); await f.finish(p, {});
    let release;
    f.c.apiGet = () => new Promise(resolve => { release = resolve; });
    const recovery = f.run('reconcilePromptQueueAction("fixture")');
    f.state.agentDetails.fixture = { ...f.state.agentDetails.fixture, name: "Newer canonical read" };
    release({ agent: f.response("accepted").agent }); await recovery;
    assert.equal(f.state.pendingPromptQueueActions.get("fixture").phase, "uncertain");
    assert.equal(f.state.agentDetails.fixture.name, "Newer canonical read");
    assert.equal(f.stats().writes, 1); cases++;
  }
  const panel = fixture(), pending = await panel.start();
  let finishRefresh;
  panel.c.refresh = () => new Promise(resolve => { finishRefresh = resolve; });
  const completed = panel.finish(pending, panel.response("started"));
  await new Promise(resolve => setImmediate(resolve));
  assert.equal(panel.state.pendingPromptQueueActions.get("fixture").phase, "confirmed", "keep panel during final read");
  assert(panel.messages.at(-1).message.includes("Started 2"), "show confirmed result before final read");
  finishRefresh(); await completed;
  assert.equal(panel.state.pendingPromptQueueActions.size, 0); cases++;
  const race = fixture(), action = await race.start();
  let releaseOldRead;
  race.c.apiGet = () => new Promise(resolve => { releaseOldRead = resolve; });
  const oldRead = race.run('ensureAgentDetail("fixture", true)');
  race.state.agentDetails.fixture = { ...race.state.agentDetails.fixture, name: "Newer observed canonical state" };
  await race.finish(action, race.response("started"));
  releaseOldRead({agent: race.response("accepted").agent}); await oldRead;
  assert.equal(race.state.agentDetails.fixture.name, "Newer observed canonical state", "pre-result detail read cannot replace newer canonical state after confirmed action"); cases++;
  console.log(`remote_ui_queue_result_test: ${cases} cases passed`);
})().catch(error => { console.error(error); process.exitCode = 1; });
