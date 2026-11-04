const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");

module.exports = async ({ browser, baseUrl, agentKey, captureDir }) => {
  const results = [];
  const gate = () => { let release; const promise = new Promise(resolve => { release = resolve; }); return { promise, release }; };
  for (const width of [1440, 390]) for (const theme of ["dark", "light"]) {
    const context = await browser.newContext({ viewport: { width, height: 900 }, isMobile: width < 500, hasTouch: width < 500 });
    const page = await context.newPage();
    page.setDefaultTimeout(10000);
    await page.addInitScript(() => { document.hasFocus = () => true; });
    const errors = [], diagnostics = [], diagnosticReads = [];
    page.on("pageerror", e => errors.push(e.message));
    page.on("console", message => { if (message.text().startsWith("[Tycho queue]")) diagnosticReads.push(message.args()[1].jsonValue().then(value => diagnostics.push(JSON.stringify(value)))); });
    let held;
    try {
      await page.goto(`${baseUrl}/ui#settings`, { waitUntil: "networkidle" });
      await page.locator("[data-appearance-preference]").selectOption(theme);
      const original = (await (await page.request.get(`${baseUrl}/agents/${agentKey}`)).json()).agent;
      let canonical, failRead = false, preflight = null;
      const raw = (protectedReply = false) => {
        const first = { id: "first", prompt: protectedReply ? "Reply from another agent" : "Prepare the summary", source: protectedReply ? "delegation_callback" : "user", state: "failed" };
        return { ...structuredClone(original), name: "Queue messages", running: false,
          prompt_queue: { entries: [first, { id: "later", prompt: "Check the result", source: "user", state: "queued" }],
            processing_stopped: true, unprocessed_reason: "debug-state-sentinel", processing: { state: "failed", message: "debug-message-sentinel" },
            dispatch_error: { message: "Synthetic token-secret /private/file prompt-secret" },
            queue_work: { batch_id: "batch", entry_ids: ["first"], unresolved_entry_ids: ["first"], dispositions: {}, entries: [first] } } };
      };
      canonical = raw();
      await page.route(`${baseUrl}/agents/${agentKey}`, route => {
        if (preflight === "read-error" || failRead) return route.fulfill({status:failRead ? 401 : 503,json:{error:"token-secret prompt-secret"}});
        if (preflight === "invalid") return route.fulfill({json:{}});
        const agent = structuredClone(canonical);
        if (preflight === "changed-batch") agent.prompt_queue.queue_work.batch_id = "new-batch";
        if (preflight === "empty-unresolved") agent.prompt_queue.queue_work.unresolved_entry_ids = [];
        if (preflight === "duplicate-unresolved") agent.prompt_queue.queue_work.unresolved_entry_ids = ["first","first"];
        if (preflight === "new-scope" || preflight === "expanded-scope") {
          if (preflight === "new-scope") agent.prompt_queue.entries = [{id:"new-first",prompt:"New message one",source:"user",state:"failed"},{id:"new-second",prompt:"New message two",source:"user",state:"failed"}];
          const ids = agent.prompt_queue.entries.map(entry=>entry.id);
          agent.prompt_queue.queue_work={batch_id:preflight==="new-scope"?"new-batch":"batch",entry_ids:ids,unresolved_entry_ids:ids,entries:structuredClone(agent.prompt_queue.entries),dispositions:{}};
          canonical=structuredClone(agent);
        }
        return route.fulfill({ json: { agent } });
      });
      await page.route(/\/servers\/(resources|activity)(\?.*)?$/, async route => {
        const response = await route.fetch();
        if (!response.ok()) return route.fulfill({ response });
        const replace = value => Array.isArray(value) ? value.map(replace) : !value || typeof value !== "object" ? value
          : value.key === agentKey && (value.project_key || value.prompt_queue) ? structuredClone(canonical)
            : Object.fromEntries(Object.entries(value).map(([key, child]) => [key, replace(child)]));
        return route.fulfill({ response, json: replace(await response.json()) });
      });
      await page.goto(`${baseUrl}/ui#agent/${agentKey}`, { waitUntil: "networkidle" });
      for (const scenario of ["retry", "retry-incomplete", "retry-batch", "retry-ids", "retry-status", "retry-empty", "retry-waiting", "retry-refusal", "discard", "retry-invalid", "discard-invalid", "retry-auth", "discard-auth", "discard-partial", "stale", "protected", "newer", "navigation"]) {
        const kind = scenario.startsWith("discard") || scenario === "protected" ? "discard" : "retry";
        canonical = raw(scenario === "protected");
        await page.evaluate(async key => {
          state.pendingPromptQueueActions.delete(key); await ensureAgentDetail(key, true);
          state.renderedViewHtml = ""; render(); clearTimeout(state.timer);
          document.querySelector("[data-prompt-queue]").open = true;
        }, agentKey);
        const product = await page.locator("[data-prompt-queue]").innerText();
        assert(product.includes("Could not process the queue."));
        assert(!/Synthetic|token-secret|private\/file|prompt-secret|debug-.*sentinel/.test(product));
        assert.deepEqual(await page.locator(".prompt-queue-error button").allTextContents(), ["Retry", "Discard"]);
        assert.equal(await page.locator("[data-queue-action]").count(), 0);
        if (scenario === "protected") {
          assert.equal(await page.locator("[data-discard-prompt-queue]").isEnabled(), false);
          await page.evaluate(key => runFailedPromptQueueAction(key, "discard"), agentKey);
          assert.equal(await page.evaluate(key => state.pendingPromptQueueActions.get(key)?.phase, agentKey), "uncertain");
          results.push({ width, theme, scenario, writes: 0 }); continue;
        }
        const seen = gate(); held = gate(); let writes = 0;
        const endpoint = `${baseUrl}/agents/${agentKey}/prompt-queue/${kind}`;
        const handler = async route => {
          writes++;
          assert.deepEqual(route.request().postDataJSON(), { expected_entry_ids: ["first", "later"], expected_batch_id: "batch" });
          const returned = raw();
          returned.prompt_queue.dispatch_error = null;
          returned.prompt_queue.entries = returned.prompt_queue.entries.filter(entry => entry.id !== "first");
          returned.prompt_queue.queue_work = null;
          returned.running = kind === "retry";
          if (["retry-waiting","retry-refusal"].includes(scenario)) {
            returned.running=false;
            returned.prompt_queue.entries=structuredClone(canonical.prompt_queue.entries);
            returned.prompt_queue.queue_work=structuredClone(canonical.prompt_queue.queue_work);
            if (scenario==="retry-refusal") returned.prompt_queue.dispatch_error={message:"token-secret"};
          }
          const response = { status:returned.running?"started":"accepted",batch_id:"batch",processed_entry_ids:["first"],current_entry_ids:returned.prompt_queue.entries.map(entry=>entry.id),agent: returned, discarded: kind === "discard", batch: { batch_id: "batch", state:"resolved", entry_ids: ["first"], unresolved_entry_ids: [], dispositions: { first: { entry_id: "first", outcome: "declined_with_reason", reason: "Operator discarded" } } } };
          seen.release(); await held.promise;
          if (scenario.endsWith("auth") || scenario === "stale") return route.fulfill({ status: scenario === "stale" ? 409 : 401, json: { error: "token-secret prompt-secret" } });
          if (scenario.endsWith("invalid")) return route.fulfill({ json: {} });
          if (scenario==="retry-incomplete") return route.fulfill({json:{agent:returned}});
          if (scenario==="retry-empty") return route.fulfill({status:200,body:""});
          if (scenario==="retry-batch") response.batch_id="other-batch";
          if (scenario==="retry-ids") response.processed_entry_ids=["later"];
          if (scenario==="retry-status") response.status="accepted";
          if (scenario === "discard-partial") { response.batch.unresolved_entry_ids = ["first"]; return route.fulfill({ json: response }); }
          canonical = structuredClone(returned);
          if (scenario === "newer") canonical.prompt_queue.entries.push({ id: "newer", prompt: "New message", source: "user", state: "queued" });
          return route.fulfill({ json: response });
        };
        await page.route(endpoint, handler);
        await page.locator(`[data-${kind === "retry" ? "retry" : "discard"}-prompt-queue]`).focus();
        await page.keyboard.press("Enter");
        if (kind === "discard") await page.locator("[data-confirmation-accept]").click();
        await Promise.race([seen.promise, page.waitForTimeout(10000).then(() => { throw Error(`No recovery write: ${scenario}`); })]);
        // A second invocation during the held write must be ignored.
        await page.evaluate(({ key, kind }) => runFailedPromptQueueAction(key, kind), { key: agentKey, kind });
        await page.evaluate(async () => refresh({ force: true }));
        if (scenario === "navigation") await page.evaluate(() => navigate({ type: "tab", tab: "agents" }));
        held.release();
        const uncertain = /invalid|auth|partial|incomplete|batch|ids|status|empty/.test(scenario) || scenario === "stale";
        await page.waitForFunction(({ key, uncertain }) => uncertain ? state.pendingPromptQueueActions.get(key)?.phase === "uncertain" : !state.pendingPromptQueueActions.has(key), { key: agentKey, uncertain });
        await page.waitForFunction(() => !state.refreshInFlight);
        assert.equal(writes, 1);
        if (uncertain) {
          assert((await page.locator("[data-prompt-queue]").innerText()).includes("Could not confirm"));
          assert(!/token-secret|prompt-secret|Synthetic|debug-.*sentinel/.test(await page.locator("[data-prompt-queue]").innerText()));
          // Retry after uncertainty only reads the queue; it cannot repeat this POST.
          await page.locator("[data-review-queue-action]").focus(); await page.keyboard.press("Enter");
          await page.waitForFunction(key => !state.pendingPromptQueueActions.has(key), agentKey);
          assert.equal(writes, 1);
        }
        if (["retry-waiting","retry-refusal"].includes(scenario)) assert((await page.locator(".growl").innerText()).includes(scenario==="retry-refusal"?"Could not process the queue.":"Queue is waiting to start."));
        if (scenario === "newer") assert(await page.evaluate(key => findAgent(key).prompt_queue.entries.some(entry => entry.id === "newer"), agentKey));
        if (scenario === "navigation") {
          assert.equal(await page.evaluate(() => location.hash), "#agents");
          await page.evaluate(key => navigate({ type: "agent", key }), agentKey);
          await page.locator("[data-prompt-queue]").waitFor();
        }
        await page.unroute(endpoint, handler);
        results.push({ width, theme, scenario, writes });
      }
      await page.waitForFunction(() => !state.refreshInFlight && !state.activityInFlight);
      for (const scenario of ["discard", "protected", "changed", "auth"]) {
        if (captureDir) fs.appendFileSync(path.join(captureDir, "recovery-progress.log"), `${width} ${theme} uncertain-${scenario}\n`);
        await page.waitForFunction(() => !state.refreshInFlight && !state.activityInFlight);
        await page.evaluate(() => {clearTimeout(state.timer);clearTimeout(state.activityTimer);});
        failRead = false; canonical = raw(scenario === "protected");
        canonical.prompt_queue.dispatch_error = null; canonical.prompt_queue.queue_work = null;
        await page.evaluate(async key => {
          state.pendingPromptQueueActions.delete(key); await ensureAgentDetail(key, true);
          state.promptQueueSelections.set(key, new Set(["first"]));
          state.pendingPromptQueueActions.set(key, {kind:"process", entryIds:["first"], phase:"uncertain", expanded:true, message:"Could not confirm queue processing."});
          state.renderedViewHtml = ""; render(); clearTimeout(state.timer);
          document.querySelector("[data-prompt-queue]").open = true;
        }, agentKey);
        let writes = 0;
        const endpoint = `${baseUrl}/agents/${agentKey}/prompt-queue/remove`;
        const remove = async route => {
          writes++;
          assert.deepEqual(route.request().postDataJSON(), {entry_ids:["first"],expected_entry_ids:["first","later"],expected_batch_id:""});
          canonical.prompt_queue.entries = canonical.prompt_queue.entries.filter(entry => entry.id !== "first");
          return route.fulfill({json:{status:"removed", removed_entry_ids:["first"],current_entry_ids:["later"],agent:canonical}});
        };
        await page.route(endpoint, remove);
        failRead = scenario === "auth";
        await page.locator("[data-discard-queue-action]").press("Enter");
        if (["discard", "changed"].includes(scenario)) {
          await page.locator("[data-confirmation-accept]").waitFor();
          assert((await page.locator("#confirmation-description").innerText()).includes("1 selected message"));
          if (scenario === "changed") {
            canonical.prompt_queue.entries.push({id:"newer",prompt:"New message",source:"user"});
            await page.evaluate(async key => ensureAgentDetail(key, true), agentKey);
          }
          await page.locator("[data-confirmation-accept]").click();
        }
        await page.waitForFunction(({key, done}) => done ? !state.pendingPromptQueueActions.has(key) : state.pendingPromptQueueActions.get(key)?.phase === "uncertain", {key:agentKey,done:scenario === "discard"});
        assert.equal(writes, scenario === "discard" ? 1 : 0);
        assert(canonical.prompt_queue.entries.some(entry => entry.id === "later"), "uncertain discard must retain newer messages");
        if (scenario === "discard") assert((await page.locator(".growl").innerText()).includes("Removed 1 queued message"));
        failRead = false;
        await page.unroute(endpoint, remove);
        results.push({width,theme,scenario:`uncertain-${scenario}`,writes});
      }
      for (const failure of ["read-error", "invalid", "changed-batch", "empty-unresolved", "duplicate-unresolved", "new-scope", "expanded-scope"]) {
        await page.waitForFunction(()=>!state.refreshInFlight && !state.activityInFlight);
        canonical = raw(); failRead = false; preflight = null;
        if (failure === "new-scope") canonical.prompt_queue.queue_work = null;
        await page.evaluate(async key => {
          state.pendingPromptQueueActions.delete(key); await ensureAgentDetail(key,true);
          state.renderedViewHtml="";render();clearTimeout(state.timer);clearTimeout(state.activityTimer);
          document.querySelector("[data-prompt-queue]").open=true;
        },agentKey);
        let writes=0;
        const deny = async route => {writes++;return route.fulfill({status:500,json:{error:"Unexpected mutation"}});};
        await page.route("**/prompt-queue/**",deny);
        preflight=failure;
        await page.locator("[data-retry-prompt-queue]").press("Enter");
        if (["changed-batch","new-scope","expanded-scope"].includes(failure)) {
          await page.waitForFunction(key=>!state.pendingPromptQueueActions.has(key),agentKey);
          assert.equal(writes,0); preflight=null; await page.unroute("**/prompt-queue/**",deny);
          results.push({width,theme,scenario:`failed-preflight-${failure}`,writes}); continue;
        }
        await page.waitForFunction(key=>state.pendingPromptQueueActions.get(key)?.phase==="uncertain",agentKey);
        assert.deepEqual(await page.evaluate(key=>state.pendingPromptQueueActions.get(key).entryIds,agentKey),["first"]);
        await page.waitForFunction(()=>!state.refreshInFlight && !state.activityInFlight);
        await page.evaluate(()=>{clearTimeout(state.timer);clearTimeout(state.activityTimer);});
        assert(!/token-secret|prompt-secret/.test(await page.locator("body").innerText()), "queue read errors must remain outside product text");
        preflight=null;
        await page.locator("[data-discard-queue-action]").press("Enter");
        await page.waitForFunction(key=>!state.pendingPromptQueueActions.has(key),agentKey);
        assert.equal(writes,0);assert(canonical.prompt_queue.entries.some(entry=>entry.id==="later"));
        assert.equal(await page.locator("[data-discard-prompt-queue]").isVisible(),true,"return to guarded failed-batch actions");
        await page.unroute("**/prompt-queue/**",deny);
        results.push({width,theme,scenario:`failed-preflight-${failure}`,writes});
      }
      canonical=raw();
      canonical.prompt_queue.queue_work={batch_id:"batch",entry_ids:["first","later"],unresolved_entry_ids:["first","later"],dispositions:{},entries:structuredClone(canonical.prompt_queue.entries)};
      await page.evaluate(async key=>{
        state.pendingPromptQueueActions.delete(key);await ensureAgentDetail(key,true);
        state.pendingPromptQueueActions.set(key,{kind:"process",entryIds:["first"],phase:"uncertain",expanded:true,message:"Could not confirm queue processing."});
        state.renderedViewHtml="";render();clearTimeout(state.timer);document.querySelector("[data-prompt-queue]").open=true;
      },agentKey);
      let subsetWrites=0;
      const denySubset=async route=>{subsetWrites++;return route.fulfill({status:500,json:{error:"Unexpected subset removal"}});};
      await page.route("**/prompt-queue/remove",denySubset);
      await page.locator("[data-discard-queue-action]").press("Enter");
      await page.waitForFunction(key=>!state.pendingPromptQueueActions.has(key),agentKey);
      assert.equal(subsetWrites,0);
      let batchWrites=0;
      const discardBatch=async route=>{
        batchWrites++;assert.deepEqual(route.request().postDataJSON(),{expected_entry_ids:["first","later"],expected_batch_id:"batch"});
        canonical.prompt_queue.entries=[];canonical.prompt_queue.dispatch_error=null;canonical.prompt_queue.queue_work=null;
        return route.fulfill({json:{discarded:true,agent:canonical,batch:{batch_id:"batch",state:"resolved",unresolved_entry_ids:[],dispositions:{first:{outcome:"declined_with_reason",reason:"Operator discarded"},later:{outcome:"declined_with_reason",reason:"Operator discarded"}}}}});
      };
      await page.route("**/prompt-queue/discard",discardBatch);
      await page.locator("[data-discard-prompt-queue]").press("Enter");
      await page.locator("[data-confirmation-accept]").waitFor();
      assert((await page.locator("#confirmation-description").innerText()).includes("2 queued messages"));
      await page.locator("[data-confirmation-accept]").click();
      await page.waitForFunction(key=>!state.pendingPromptQueueActions.has(key),agentKey);
      assert.equal(batchWrites,1);assert.equal(subsetWrites,0);
      await page.unroute("**/prompt-queue/remove",denySubset);await page.unroute("**/prompt-queue/discard",discardBatch);
      results.push({width,theme,scenario:"claimed-subset-requires-whole-batch-confirmation",writes:batchWrites,subsetWrites});
      await page.waitForFunction(()=>!state.refreshInFlight && !state.activityInFlight);
      canonical=raw();
      const completed={entry_id:"first",outcome:"completed"};
      canonical.prompt_queue.queue_work={batch_id:"batch",entry_ids:["first","later"],unresolved_entry_ids:["later"],entries:structuredClone(canonical.prompt_queue.entries),dispositions:{first:completed}};
      canonical.prompt_queue.entries=[canonical.prompt_queue.entries[1],{id:"newer",prompt:"New message",source:"user",state:"queued"}];
      await page.evaluate(async key=>{
        await ensureAgentDetail(key,true);state.renderedViewHtml="";render();clearTimeout(state.timer);clearTimeout(state.activityTimer);
        document.querySelector("[data-prompt-queue]").open=true;
      },agentKey);
      let partialWrites=0;
      const discardRemaining=async route=>{
        partialWrites++;assert.deepEqual(route.request().postDataJSON(),{expected_entry_ids:["later","newer"],expected_batch_id:"batch"});
        canonical.prompt_queue.entries=canonical.prompt_queue.entries.filter(entry=>entry.id==="newer");
        canonical.prompt_queue.dispatch_error=null;canonical.prompt_queue.queue_work=null;
        return route.fulfill({json:{discarded:true,agent:canonical,batch:{batch_id:"batch",state:"resolved",unresolved_entry_ids:[],dispositions:{first:completed,later:{entry_id:"later",outcome:"declined_with_reason",reason:"Operator discarded"}}}}});
      };
      await page.route("**/prompt-queue/discard",discardRemaining);
      await page.locator("[data-discard-prompt-queue]").press("Enter");
      await page.locator("[data-confirmation-accept]").waitFor();
      assert((await page.locator("#confirmation-description").innerText()).includes("1 queued message?"));
      await page.locator("[data-confirmation-accept]").press("Enter");
      await page.waitForFunction(key=>!state.pendingPromptQueueActions.has(key),agentKey);
      assert.equal(partialWrites,1);assert.deepEqual(canonical.prompt_queue.entries.map(entry=>entry.id),["newer"]);
      await page.unroute("**/prompt-queue/discard",discardRemaining);
      results.push({width,theme,scenario:"discard-only-unresolved-with-prior-outcome",writes:partialWrites});
      await Promise.all(diagnosticReads);
      assert(diagnostics.length > 0);
      assert(!/token-secret|prompt-secret|private\/file|debug-.*sentinel|Prepare the summary/.test(diagnostics.join("\n")));
      assert.deepEqual(errors, []);
    } finally { held?.release(); await context.close(); }
  }
  if (captureDir) fs.writeFileSync(path.join(captureDir, "queue-recovery-results.json"), JSON.stringify(results, null, 2));
  console.log(`queue_recovery_smoke: ${results.length} cases passed; guarded Retry/Discard, protected replies, private diagnostics, current reads, keyboard and mobile`);
};
