const assert = require("node:assert/strict");
const fs = require("node:fs");
const vm = require("node:vm");
const source = fs.readFileSync(process.argv[2], "utf8");
const fn = name => source.match(new RegExp(`^(?:async )?function ${name}\\([^]*?^}`, "m"))[0];
const functions = ["promptQueueWaitMessage", "promptQueueDiagnostic", "promptQueueReadAgent", "promptQueueReadFailedBatch", "runFailedPromptQueueAction", "promptQueueSelection", "promptQueueActionResult", "promptQueueActionMessage", "runPromptQueueAction", "reconcilePromptQueueAction", "inquiryAnswerDisplayState", "inquiryAnswerDisplayUnchanged", "agentDetailGeneration", "ensureAgentDetail"].map(fn).join("\n");
let cases = 0;
function fixture(kind = "process") {
  let resolve, reject, reads = 0, writes = 0, refreshes = 0;
  const agent = { key: "fixture", name: "Original agent", running: false, prompt_queue: { entries: [{ id: "a" }, { id: "b" }], processing: { message: "Waiting for the workspace." } } };
  const selection = new Set(["a", "b"]);
  const state = { agents: [agent], agentDetails: { fixture: agent }, activityAgents: new Map(), agentDetailGenerations: new Map(),
    resourceMutationGeneration: 0, promptQueueSelections: new Map([["fixture", selection]]), pendingPromptQueueActions: new Map() };
  const messages = [], applied = [], diagnostics = [];
  const c = { state, console: {warn: (...args) => diagnostics.push(args), debug: (...args) => diagnostics.push(args)}, location: { hash: "#agent/fixture" }, clearTimeout, arrayValue: x => x || [],
    findAgent: () => state.agentDetails.fixture, render() {}, schedule() {}, syncPendingPromptQueueActions() {},
    reconcileOptimisticPromptQueue() {}, confirmAction: async () => true, showGrowl: (message, level) => messages.push({ message, level }),
    upsertAgent: value => { applied.push(value); state.agentDetails.fixture = value; },
    apiPost: async (path, body) => { writes++; assert.deepEqual(JSON.parse(JSON.stringify(body)), { entry_ids: ["a", "b"], expected_entry_ids: ["a", "b"], ...(Object.hasOwn(body,"expected_batch_id") ? {expected_batch_id:""} : {}) }); return new Promise((yes, no) => { resolve = yes; reject = no; }); },
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
  return { c, state, selection, messages, applied, diagnostics, run, response,
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
      assert(f.messages.at(-1).message.includes("Could not confirm"));
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
  assert(f.messages.at(-1).message.includes("Could not process the queue"));
  assert(!f.messages.at(-1).message.includes("Synthetic")); cases++;
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
  const privacy = fixture(), privacyPending = await privacy.start();
  privacy.c.apiGet = async () => { throw Object.assign(Error("token-secret private prompt /private/file"), {status:401}); };
  await privacy.fail(privacyPending);
  await privacy.run('reconcilePromptQueueAction("fixture")');
  const visible = JSON.stringify(privacy.messages) + privacy.state.pendingPromptQueueActions.get("fixture").message;
  const logged = JSON.stringify(privacy.diagnostics);
  assert(!/Synthetic|token-secret|private prompt|private\/file/.test(visible + logged));
  assert(logged.includes('"httpStatus":401')); cases++;
  for (const protectedEntry of [false, true]) {
    const removal = fixture("remove"), p = await removal.start(); await removal.finish(p, {});
    const agent = removal.response("accepted").agent;
    if (protectedEntry) agent.prompt_queue.entries[0].source = "delegation_callback";
    removal.c.readResponse = {agent};
    const recovery = removal.run('reconcilePromptQueueAction("fixture", "discard")');
    await new Promise(resolve => setImmediate(resolve));
    if (protectedEntry) {
      await recovery; assert.equal(removal.stats().writes, 1); assert.equal(removal.state.pendingPromptQueueActions.get("fixture").phase, "uncertain");
    } else {
      assert.equal(removal.stats().writes, 2);
      await removal.finish({promise: recovery}, removal.response("removed"));
      assert.equal(removal.state.pendingPromptQueueActions.size, 0);
      assert(removal.messages.at(-1).message.includes("Removed 2"));
    }
    cases++;
  }
  for (const running of [false, true]) {
    const f = fixture();
    const agent = f.response("accepted").agent; agent.running = running;
    f.c.readResponse = {agent};
    await f.run('runFailedPromptQueueAction("fixture", "retry")');
    assert.equal(f.stats().writes, 0); assert.equal(f.state.pendingPromptQueueActions.size, 0);
    assert(f.messages.at(-1).message.includes(running ? "already running" : "Queue changed")); cases++;
  }
  for (const failure of ["read-error", "invalid", "changed-batch", "missing-scope"]) {
    const f = fixture();
    const initial = f.state.agentDetails.fixture;
    initial.prompt_queue.dispatch_error = {message:"private-error-sentinel"};
    initial.prompt_queue.queue_work = {batch_id:"batch",entry_ids:["a"],unresolved_entry_ids:["a"],dispositions:{},entries:[{id:"a",source:"user"}]};
    if (failure === "missing-scope") delete initial.prompt_queue.queue_work;
    const fresh = structuredClone(initial);
    if (failure === "changed-batch") fresh.prompt_queue.queue_work.batch_id = "new-batch";
    f.c.apiGet = async () => { if (failure === "read-error") throw Object.assign(Error("private"),{status:503}); return failure === "invalid" || failure === "missing-scope" ? {} : {agent:fresh}; };
    await f.run('runFailedPromptQueueAction("fixture", "retry")');
    const pending = f.state.pendingPromptQueueActions.get("fixture");
    if (failure === "changed-batch") {
      assert.equal(pending,undefined); assert.equal(f.stats().writes,0); cases++; continue;
    }
    assert.equal(pending.phase,"uncertain"); assert.deepEqual([...pending.entryIds], failure === "missing-scope" ? [] : ["a"]);
    f.c.apiGet = async () => ({agent:initial});
    await f.run('reconcilePromptQueueAction("fixture", "discard")');
    assert.equal(f.stats().writes,0,"failed recovery must not expand Discard to newer work");
    assert.equal(f.state.pendingPromptQueueActions.size,0); assert(f.state.agentDetails.fixture.prompt_queue.entries.some(entry=>entry.id==="b")); cases++;
  }
  for (const mode of ["started","waiting","refusal","incomplete","empty","batch","ids","status","current","partial"]) {
    const f=fixture(), initial=f.state.agentDetails.fixture;
    initial.prompt_queue.dispatch_error={message:"private"};
    initial.prompt_queue.queue_work={batch_id:"batch",entry_ids:["a","b"],unresolved_entry_ids:["a","b"],dispositions:{},entries:[{id:"a",source:"user"},{id:"b",source:"user"}]};
    f.c.readResponse={agent:structuredClone(initial)};
    const returned=structuredClone(initial);returned.running=!["waiting","refusal"].includes(mode);
    if (mode!=="refusal") returned.prompt_queue.dispatch_error=null;
    let result={status:returned.running?"started":"accepted",batch_id:"batch",processed_entry_ids:["a","b"],current_entry_ids:["a","b"],agent:returned};
    if (mode==="incomplete") result={agent:returned};
    if (mode==="empty") result={};
    if (mode==="batch") result.batch_id="other";
    if (mode==="ids") result.processed_entry_ids=["unknown"];
    if (mode==="partial") result.processed_entry_ids=["a"];
    if (mode==="status") result.status="accepted";
    if (mode==="current") result.current_entry_ids=[];
    let writes=0;
    f.c.apiPost=async()=>{writes++;return result;};
    await f.run('runFailedPromptQueueAction("fixture","retry")');
    const valid=["started","waiting","refusal"].includes(mode);
    assert.equal(f.state.pendingPromptQueueActions.get("fixture")?.phase,valid?undefined:"uncertain");
    if (valid) assert(f.messages.at(-1).message.includes(mode==="started"?"Queue started.":mode==="waiting"?"waiting":"Could not process"));
    else {await f.run('reconcilePromptQueueAction("fixture","retry")');assert.equal(writes,1);}
    cases++;
  }
  const claimed = fixture();
  const claimedAgent = claimed.state.agentDetails.fixture;
  claimedAgent.prompt_queue.dispatch_error = {message:"private-error-sentinel"};
  claimedAgent.prompt_queue.queue_work = {batch_id:"claim",entry_ids:["a","b"],unresolved_entry_ids:["a","b"],dispositions:{},entries:[{id:"a",source:"user"},{id:"b",source:"user"}]};
  claimed.state.pendingPromptQueueActions.set("fixture",{kind:"process",entryIds:["a"],phase:"uncertain"});
  claimed.c.readResponse = {agent:claimedAgent};
  await claimed.run('reconcilePromptQueueAction("fixture", "discard")');
  assert.equal(claimed.stats().writes,0,"subset uncertainty must use canonical failed-batch actions");
  assert.equal(claimed.state.pendingPromptQueueActions.size,0); cases++;
  const failedBatch = () => ({batch_id:"batch",entry_ids:["a"],unresolved_entry_ids:["a"],entries:[{id:"a",source:"user"}],dispositions:{}});
  for (const alter of [b=>({...b,unresolved_entry_ids:[]}), b=>({...b,unresolved_entry_ids:["a","a"]}),
    b=>({...b,unresolved_entry_ids:["foreign"]}), b=>({...b,entry_ids:["a","a"]}), b=>({...b,entries:[]}),
    b=>({...b,entries:[{id:"b"}]}), b=>({...b,batch_id:42}), b=>({...b,dispositions:[]}),
    b=>({...b,dispositions:{a:{entry_id:"a"}}}), b=>({...b,dispositions:{foreign:{entry_id:"foreign"}}})]) {
    const f=fixture(); f.state.agentDetails.fixture.prompt_queue.dispatch_error={message:"private"};
    f.state.agentDetails.fixture.prompt_queue.queue_work=failedBatch();
    const fresh=structuredClone(f.state.agentDetails.fixture);fresh.prompt_queue.queue_work=alter(failedBatch());
    f.c.readResponse={agent:fresh};let confirmations=0;f.c.confirmAction=async()=>{confirmations++;return true;};
    const attempt=f.run('runFailedPromptQueueAction("fixture","discard")');
    await new Promise(resolve=>setImmediate(resolve));
    assert.equal(f.stats().writes,0,"malformed batch cannot mutate");assert.equal(confirmations,0,"malformed batch cannot understate destructive confirmation");
    await attempt;assert.equal(f.state.pendingPromptQueueActions.get("fixture").phase,"uncertain");cases++;
  }
  for (const original of ["missing","expanded"]) {
    const f=fixture();f.state.agentDetails.fixture.prompt_queue.dispatch_error={message:"private"};
    if(original==="expanded")f.state.agentDetails.fixture.prompt_queue.queue_work=failedBatch();
    const fresh=structuredClone(f.state.agentDetails.fixture);
    fresh.prompt_queue.entries=original==="missing"?[{id:"c"},{id:"d"}]:[{id:"a"},{id:"b"}];
    const ids=fresh.prompt_queue.entries.map(entry=>entry.id);
    fresh.prompt_queue.queue_work={batch_id:original==="missing"?"new-batch":"batch",entry_ids:ids,unresolved_entry_ids:ids,entries:fresh.prompt_queue.entries,dispositions:{}};
    f.c.readResponse={agent:fresh};
    await f.run('runFailedPromptQueueAction("fixture","retry")');
    assert.equal(f.stats().writes,0,"unknown or changed original scope must require a new explicit action");
    assert.equal(f.state.pendingPromptQueueActions.size,0);cases++;
  }
  for (const scenario of ["valid","unknown-outcome","missing-reason","wrong-source","resolved-visible"]) {
    const f=fixture();const agent=f.state.agentDetails.fixture;
    agent.prompt_queue.entries=[{id:"a"}];
    agent.prompt_queue.queue_work={batch_id:"batch",entry_ids:["a","b"],unresolved_entry_ids:["a"],entries:[{id:"a",source:"user"},{id:"b",source:"user"}],dispositions:{b:{entry_id:"b",outcome:"completed"}}};
    if(scenario==="unknown-outcome")agent.prompt_queue.queue_work.dispositions.b.outcome="unknown";
    if(scenario==="missing-reason")agent.prompt_queue.queue_work.dispositions.b.outcome="declined_with_reason";
    if(scenario==="wrong-source")agent.prompt_queue.queue_work.entries[1].source="delegation_callback";
    if(scenario==="resolved-visible")agent.prompt_queue.entries.push({id:"b"});
    if(scenario==="valid")assert.equal(f.run('promptQueueReadFailedBatch(findAgent("fixture")).batch_id'),"batch");
    else assert.throws(()=>f.run('promptQueueReadFailedBatch(findAgent("fixture"))'),/invalid_result/);
    cases++;
  }
  if (process.env.TYCHO_QUEUE_RETRY_PROOF_INPUT === "1") {
    for (const row of JSON.parse(fs.readFileSync(0,"utf8"))) {
      const f=fixture(), initial=structuredClone(row.before), result=structuredClone(row.result);
      initial.key="fixture";result.agent.key="fixture";
      f.state.agentDetails.fixture=initial;f.state.agents=[initial];f.c.readResponse={agent:initial};
      let writes=0;f.c.apiPost=async()=>{writes++;return result;};
      await f.run('runFailedPromptQueueAction("fixture","retry")');
      const expected=initial.prompt_queue.queue_work.unresolved_entry_ids;
      assert.deepEqual(result.processed_entry_ids,row.actual_entry_ids);
      const complete=JSON.stringify(expected)===JSON.stringify(row.actual_entry_ids);
      const action=f.state.pendingPromptQueueActions.get("fixture");
      assert.equal(action?.phase,complete?undefined:"uncertain",row.scenario);
      if (!complete) {
        assert.deepEqual([...action.entryIds],expected,"original complete scope must stay intact");
        assert(!f.messages.some(item=>item.message==="Queue started."));
        await f.run('reconcilePromptQueueAction("fixture","retry")');
        assert.equal(writes,1,"recovery cannot automatically repeat or expand the mutation");
      }
      cases++;
    }
  }
  console.log(`remote_ui_queue_result_test: ${cases} cases passed`);
})().catch(error => { console.error(error); process.exitCode = 1; });
