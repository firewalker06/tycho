const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");

module.exports = async ({ browser, baseUrl, captureDir }) => {
  const results = [];
  for (const width of [1440, 390]) {
    const context = await browser.newContext({ viewport: { width, height: 900 } });
    const page = await context.newPage();
    const errors = [];
    page.on("pageerror", e => errors.push(e.message));
    // Every real request is restricted to the throwaway service.
    await context.route("**/*", route => new URL(route.request().url()).origin === baseUrl ? route.continue() : route.abort());
    await page.goto(`${baseUrl}/ui#agents`, { waitUntil: "networkidle" });
    await page.evaluate(() => { clearTimeout(state.timer); state.timer = 1; });
    const options = await (await context.request.get(`${baseUrl}/quick-agent/options`)).json();
    let delay = 600, fail = false, empty = false, peerDelay = 800, peerFail = false;
    let localReads = 0, peerReads = 0;
    let peerStatus = "online", peerCount = 0;
    await page.route(`${baseUrl}/servers/resources`, async route => {
      const data = await (await route.fetch()).json();
      data.servers.push(...Array.from({length:peerCount}, (_,i) => ({key:`fixture-peer${i}`,name:`Peer ${i}`,local:false,status:peerStatus,stale:peerStatus !== "online",agents:[],projects:[{key:"web",name:"Web"}]})));
      await route.fulfill({json:data});
    });
    const forbidden = [];
    await page.route(`${baseUrl}/setup`, async route => {
      if (await page.locator("#quick-agent-dialog").evaluate(el => el.open)) { forbidden.push("setup"); return route.abort(); }
      return route.continue();
    });
    await page.route(`${baseUrl}/settings/quick-agent`, route => { forbidden.push("settings"); return route.abort(); });
    await page.route(`${baseUrl}/projects/*`, async route => {
      if (await page.locator("#quick-agent-dialog").evaluate(el => el.open)) { forbidden.push("local detail"); return route.abort(); }
      return route.continue();
    });
    await page.route(`${baseUrl}/quick-agent/options`, async route => {
      ++localReads;
      const snapshot = JSON.parse(JSON.stringify(options));
      const rejected = fail;
      if (empty) { snapshot.projects = []; snapshot.quick_agent.projects = []; snapshot.quick_agent.effective_project_key = null; }
      await new Promise(r => setTimeout(r, delay));
      await route.fulfill({ status: rejected ? 403 : 200, json: rejected ? { error: "Fixture permission denied" } : snapshot });
    });
    await page.route(`${baseUrl}/servers/*/projects/*`, async route => {
      ++peerReads;
      const rejected = peerFail;
      await new Promise(r => setTimeout(r, peerDelay));
      await route.fulfill({ status: rejected ? 503 : 200, json: rejected ? { error: "Fixture peer unavailable" } : { project: { ...options.projects.find(p => p.key === "web"), agent: "peer-wrapper", model: "peer-default", agent_template_summaries: [{key:"peer-template",agent:"peer-wrapper",model:"peer-default"}] } } });
    });
    const ready = async () => { try { await page.waitForFunction(() => quickAgentCanSubmit(), null, {timeout: 5000}); } catch (error) { console.log("options diagnostic", await page.evaluate(() => ({draft: quickAgent.draft, current: quickAgentReadState(), localReady: quickAgent.localReady, localError: quickAgent.localError, projectError: quickAgent.projectError, loadingKey: quickAgent.loadingKey, projects: quickAgentEligibleProjects().map(p=>p.key), requests:[...quickAgent.projectRequests.keys()]}))); throw error; } };
    const discard = () => page.evaluate(() => closeQuickAgent(true));
    const expand = async () => {
      if (await page.locator("#quick-agent-options").isHidden()) await page.locator("[data-quick-agent-toggle]").click();
    };
    const addPeers = async (status = "online", count = 3) => {
      peerStatus = status; peerCount = count;
      return page.evaluate(({status, count}) => {
      const local = { ...resourceServer("local"), local: true, projects: state.projects.filter(p => p.server_key === "local"), agents: state.agents.filter(a => a.server_key === "local") };
      const peers = Array.from({ length: count }, (_, i) => ({ key: `fixture-peer${i}`, name: `Peer ${i}`, local: false, status, stale: status !== "online", refreshing: status === "loading", agents: [], projects: [{ key: "web", name: "Web" }] }));
      applyResourceCatalog({ servers: [local, ...peers] });
    }, {status, count});
    };
    const capture = async label => {
      assert(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth + 1), "page overflow");
      const rect = await page.locator('#quick-agent-form button[type=submit]').boundingBox();
      assert(rect.x >= 0 && rect.x + rect.width <= width + 1, "submit horizontal overflow");
      if (captureDir) await page.screenshot({ path: path.join(captureDir, `quick-options-${label}-${width}.png`) });
    };
    // Cold/warm editable time is distinct from actual local option readiness.
    for (const cold of [true, false]) {
      await discard();
      const timing = await page.evaluate(async cold => {
        state.setupDetailed = !cold;
        const start = performance.now();
        window.quickOpenedAt = start;
        openQuickAgent();
        await new Promise(requestAnimationFrame);
        const input = document.querySelector("#quick-agent-prompt");
        input.value = "Draft entered before options";
        input.setSelectionRange(4, 9);
        input.dispatchEvent(new CompositionEvent("compositionstart", {bubbles:true}));
        window.quickPromptProbe = input;
        return { editableMs: performance.now() - start, enabled: !input.disabled, createDisabled: document.querySelector('#quick-agent-form button[type=submit]').disabled };
      }, cold);
      assert(timing.editableMs < 100, JSON.stringify(timing));
      assert(timing.enabled && timing.createDisabled);
      await ready();
      timing.optionsReadyMs = await page.evaluate(() => performance.now() - quickOpenedAt);
      const stateAfter = await page.evaluate(() => ({ same: window.quickPromptProbe === document.querySelector("#quick-agent-prompt"), value: quickAgentReadState().promptValue, selection: [quickPromptProbe.selectionStart, quickPromptProbe.selectionEnd], focus: document.activeElement === quickPromptProbe }));
      assert(stateAfter.same && stateAfter.focus);
      assert(await page.evaluate(() => state.skillAutocomplete.composing));
      await page.locator("#quick-agent-prompt").dispatchEvent("compositionend");
      assert.equal(stateAfter.value, "Draft entered before options");
      assert.deepEqual(stateAfter.selection, [4, 9]);
      results.push({ width, cold, ...timing, localOptionsDelayMs: delay, nodeAndSelectionPreserved: true });
    }
    // A contextual peer opens before either source responds. A late Host default
    // must not reroute it, including when Host finishes after peer defaults.
    await addPeers(); await discard(); peerDelay = 200; delay = 600;
    const peerOpening = await page.evaluate(() => {
      history.replaceState(null, "", "#project/fixture-peer0%2Fweb");
      const start = performance.now(); openQuickAgent();
      return {editableMs:performance.now()-start, key:quickAgentReadState().projectKey};
    });
    assert(peerOpening.editableMs < 100);
    assert.equal(peerOpening.key, "fixture-peer0/web");
    await page.locator("#quick-agent-prompt").fill("Context peer draft");
    await ready();
    await page.waitForFunction(() => quickAgent.localReady);
    assert.equal(await page.locator("#quick-agent-project").inputValue(), "fixture-peer0/web");
    assert.equal(await page.locator("#quick-agent-prompt").inputValue(), "Context peer draft");
    results.push({width, contextualPeer:peerOpening, lateHostDefaultPreserved:true});
    await discard();
    await page.evaluate(() => history.replaceState(null, "", "#agents"));
    peerDelay = 800;
    // Local failure/retry, no eligible local, and revoked eligibility retain text.
    await discard(); fail = true;
    await page.evaluate(() => openQuickAgent());
    await page.locator("#quick-agent-prompt").fill("Keep failed local draft");
    await page.locator("[data-quick-agent-retry]").waitFor({ state: "visible" });
    assert(await page.locator('#quick-agent-form button[type=submit]').isDisabled());
    fail = false; delay = 40;
    await page.locator("[data-quick-agent-retry]").click(); await ready();
    assert.equal(await page.locator("#quick-agent-prompt").inputValue(), "Keep failed local draft");
    await discard(); empty = true;
    await page.evaluate(() => openQuickAgent());
    await page.waitForFunction(() => quickAgent.localReady);
    assert(await page.locator('#quick-agent-form button[type=submit]').isDisabled());
    await discard(); empty = false;
    await page.evaluate(() => openQuickAgent()); await ready();
    await page.locator("#quick-agent-prompt").fill("Keep revoked draft");
    empty = true;
    await page.evaluate(() => loadQuickAgentLocalOptions());
    assert(await page.locator('#quick-agent-form button[type=submit]').isDisabled());
    assert.equal(await page.locator("#quick-agent-prompt").inputValue(), "Keep revoked draft");
    empty = false;
    await page.evaluate(() => loadQuickAgentLocalOptions()); await ready();
    // Delayed catalog arrivals update the selector without replacing the form.
    await expand();
    await page.locator("#quick-agent-name").fill("Keep name");
    await page.evaluate(() => { window.formProbe = document.querySelector("#quick-agent-form"); });
    await addPeers("loading");
    assert(await page.locator('#quick-agent-form button[type=submit]').isEnabled());
    await addPeers();
    assert.equal(await page.locator('#quick-agent-project option[value^="fixture-peer"]').count(), 3);
    assert(await page.evaluate(() => formProbe === document.querySelector("#quick-agent-form")));
    // Identical labels have explicit server identity and independent raw keys.
    assert.match(await page.locator('#quick-agent-project option[value="fixture-peer0/web"]').innerText(), /Peer 0/);
    await page.locator("#quick-agent-project").selectOption("fixture-peer0/web");
    await page.locator("#quick-agent-harness").selectOption("claude");
    await page.locator("#quick-agent-model").evaluate(el => { el.add(new Option("Manual model", "manual-model")); });
    await page.locator("#quick-agent-model").selectOption("manual-model");
    await page.locator("#quick-agent-effort").selectOption("high");
    await ready();
    assert.equal(await page.locator("#quick-agent-model").inputValue(), "manual-model");
    assert.equal(await page.locator("#quick-agent-harness").inputValue(), "claude");
    assert.equal(await page.locator("#quick-agent-name").inputValue(), "Keep name");
    assert.equal(await page.locator("#quick-agent-effort").inputValue(), "high");
    // Explicit peer selection cannot change to Host when a peer disappears.
    await addPeers("offline");
    assert.equal(await page.locator("#quick-agent-project").inputValue(), "fixture-peer0/web");
    assert(await page.locator('#quick-agent-form button[type=submit]').isDisabled());
    const peerRefreshes = [];
    await page.route(`${baseUrl}/servers/*/resources/refresh`, async route => {
      peerRefreshes.push(new URL(route.request().url()).pathname);
      peerStatus = "online";
      await route.fulfill({status:202,json:{accepted:true}});
    });
    await page.locator('[data-quick-agent-peer-retry="fixture-peer0"]').click();
    await page.waitForFunction(() => quickAgentEligibleProjects().some(p=>p.key === "fixture-peer0/web"));
    assert.deepEqual(peerRefreshes, ["/servers/fixture-peer0/resources/refresh"]);
    assert.equal(await page.locator("#quick-agent-project").inputValue(), "fixture-peer0/web");
    // Close/reopen in the same task; coalesced reads and generation guards.
    const readsBefore = peerReads;
    await page.locator("#quick-agent-project").selectOption("fixture-peer1/web");
    await page.evaluate(() => { closeQuickAgent(); openQuickAgent(); openQuickAgent(); });
    await expand();
    await page.locator("#quick-agent-model").evaluate(el => { el.add(new Option("Reopened model", "reopened-model")); el.value = "reopened-model"; el.dispatchEvent(new Event("change", {bubbles:true})); });
    await ready();
    assert.equal(peerReads, readsBefore + 1, "same-scope read must coalesce across reopen");
    assert.equal(await page.locator("#quick-agent-model").inputValue(), "reopened-model");
    assert.equal(await page.locator("#quick-agent-project").inputValue(), "fixture-peer1/web");
    // A -> B -> A: the older same-key reply cannot apply to B or reset explicit fields.
    await page.locator("#quick-agent-project").selectOption("fixture-peer2/web");
    await page.locator("#quick-agent-project").selectOption("fixture-peer0/web");
    await page.locator("#quick-agent-project").selectOption("fixture-peer2/web");
    await page.locator("#quick-agent-model").evaluate(el => { el.add(new Option("Switch model", "switch-model")); el.value = "switch-model"; el.dispatchEvent(new Event("change", {bubbles:true})); });
    await ready();
    assert.equal(await page.locator("#quick-agent-model").inputValue(), "switch-model");
    peerFail = true;
    await page.locator("#quick-agent-project").selectOption("fixture-peer0/web");
    await page.locator("[data-quick-agent-retry]").waitFor({state:"visible"});
    assert.equal(await page.locator("#quick-agent-project").inputValue(), "fixture-peer0/web");
    peerFail = false; peerDelay = 50;
    await page.locator("[data-quick-agent-retry]").click(); await ready();
    await page.locator("#quick-agent-model").selectOption("");
    await page.evaluate(() => loadQuickAgentLocalOptions());
    assert.equal(await page.locator("#quick-agent-model").inputValue(), "");
    await capture("peer");
    // Old opening replies cannot reopen the dialog. Close retains text; discard clears it.
    delay = 300;
    await page.evaluate(() => { closeQuickAgent(); openQuickAgent(); closeQuickAgent(); });
    await page.waitForTimeout(350);
    assert.equal(await page.locator("#quick-agent-dialog").evaluate(el => el.open), false);
    await page.evaluate(() => openQuickAgent()); await ready();
    assert.equal(await page.locator("#quick-agent-prompt").inputValue(), "Keep revoked draft");
    await discard(); delay = 30;
    await page.evaluate(() => openQuickAgent()); await ready();
    assert.equal(await page.locator("#quick-agent-prompt").inputValue(), "");
    // All peer detail reads stay held while a real local fake-harness create completes once.
    const held = [];
    await page.route(`${baseUrl}/servers/*/projects/*`, async route => { await new Promise(resolve => held.push(resolve)); await route.abort(); });
    const before = (await (await context.request.get(`${baseUrl}/agents`)).json()).agents.length;
    await expand();
    await page.locator("#quick-agent-project").selectOption("fixture-peer0/web");
    await page.locator("#quick-agent-project").selectOption("fixture-peer1/web");
    await page.locator("#quick-agent-project").selectOption("fixture-peer2/web");
    await page.locator("#quick-agent-project").selectOption("web");
    await ready();
    await page.locator("#quick-agent-prompt").fill(`Local only creation ${width}`);
    await capture("local");
    const sent = [];
    page.on("request", req => { if (req.method() === "POST" && /\/agents$/.test(req.url())) sent.push({url:req.url(),body:req.postDataJSON()}); });
    const responsePromise = page.waitForResponse(r => r.url() === `${baseUrl}/agents` && r.request().method() === "POST");
    await page.locator('#quick-agent-form button[type=submit]').click();
    const response = await responsePromise;
    assert(response.ok(), await response.text());
    const created = (await response.json()).agent;
    await page.waitForFunction(async key => (await (await fetch(`/agents/${key}`)).json()).agent.status === "success", created.key);
    const agents = (await (await context.request.get(`${baseUrl}/agents`)).json()).agents;
    assert.equal(agents.length, before + 1);
    assert.equal(agents.find(a => a.key === created.key).run_count, 1);
    assert.equal(sent.length, 1);
    assert.equal(sent[0].body.project_key, "web");
    assert(sent[0].body.client_request_id);
    assert.equal(held.length, 3, "all remote reads must still be pending at local completion");
    held.forEach(resolve => resolve());
    // Peer submission still freezes the raw key and broker path. No peer server
    // or provider is contacted: an uncertain fixture response retains the record.
    await page.unroute(`${baseUrl}/servers/*/projects/*`);
    await page.route(`${baseUrl}/servers/*/projects/*`, route => route.fulfill({json:{project:{key:"web",name:"Web",agent:"peer-wrapper",model:"peer-model",agent_template_summaries:[]}}}));
    await page.route(`${baseUrl}/servers/fixture-peer0/agents`, route => route.fulfill({status:503,json:{error:"Fixture acceptance unknown"}}));
    await page.goto(`${baseUrl}/ui#agents`, {waitUntil:"networkidle"});
    await page.evaluate(() => { history.replaceState(null,"","#project/fixture-peer0%2Fweb"); openQuickAgent(); });
    await ready();
    await page.locator("#quick-agent-prompt").fill("Peer target snapshot");
    await page.locator('#quick-agent-form button[type=submit]').click();
    await page.locator("[data-retry-agent-create]").waitFor({state:"visible"});
    const peerRecord = await page.evaluate(() => {
      const entry = [...pendingAgentCreations.values()].find(e=>e.payload?.prompt === "Peer target snapshot");
      return {path:entry.request.path,body:entry.request.body,server:entry.request.server,rejected:entry.rejected};
    });
    assert.equal(peerRecord.path,"/servers/fixture-peer0/agents");
    assert.equal(peerRecord.body.project_key,"web");
    assert.equal(peerRecord.body.agent,"peer-wrapper");
    assert.equal(peerRecord.server.key,"fixture-peer0");
    assert.equal(peerRecord.rejected,false);
    results.push({width,peerRecord});
    assert.deepEqual(forbidden, []);
    assert.deepEqual(errors, []);
    results.push({ width, localReads, peerReads, localCreation: sent.filter(request => request.url === `${baseUrl}/agents`), exactlyOneRun: true, staleGuards: true, retainedDraft: true, failureRetry: true });
    await context.close();
  }
  if (captureDir) fs.writeFileSync(path.join(captureDir, "results.json"), JSON.stringify(results, null, 2));
  console.log("quick-agent-options-smoke: ok", JSON.stringify(results));
};
