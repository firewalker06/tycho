const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");

module.exports = async ({ browser, baseUrl, captureDir }) => {
  assert.equal(new URL(baseUrl).hostname, "127.0.0.1", "Synthetic loopback fixture required");
  const evidence = [];
  if (captureDir) fs.mkdirSync(captureDir, { recursive: true });
  const gate = () => { let release; const promise = new Promise(resolve => {release = resolve;}); return {promise, release}; };
  for (const width of [1440, 390]) {
    for (const scenario of ["ordered-held-refresh", "lost-processed-reload", "malformed", "wrong-server", "read-auth-navigation", "immediate", "input-rejection", "consumed-before-read"]) {
      const context = await browser.newContext({ viewport: {width, height: 900}, isMobile: width < 500, hasTouch: width < 500 });
      const page = await context.newPage();
      page.setDefaultTimeout(10000);
      console.log(`Receipt case: ${width} ${scenario}`);
      const errors = [];
      page.on("pageerror", error => errors.push(error.message));
      const create = await context.request.post(`${baseUrl}/agents`, {data: {project_key: "web", name: "Receipt fixture", prompt: ["immediate","input-rejection"].includes(scenario) ? "Synthetic idle fixture" : "QUEUE_SMOKE_HOLD", start: !["immediate","input-rejection"].includes(scenario)}});
      assert.equal(create.status(), 201);
      const agent = (await create.json()).agent;
      const key = agent.key;
      const receiptGate = gate(), readGate = gate();
      let writes = 0, heldReads = 0, refreshes = 0;
      const ids = [], outcomes = [], sizes = [], payloads = [];
      let holdReads = false;
      try {
        await page.goto(`${baseUrl}/ui#agent/${encodeURIComponent(key)}`, {waitUntil: "networkidle"});
        await page.waitForSelector("#composer");
        await page.evaluate(() => { clearTimeout(state.timer); const original = refresh; globalThis.__receiptRefreshes = 0; refresh = async (...args) => {globalThis.__receiptRefreshes++; return original(...args);}; });
        await page.route(new RegExp(`/agents/${key}$`), async route => {
          if (route.request().method() !== "GET" || !holdReads) return route.continue();
          const response = await route.fetch();
          heldReads++;
          await readGate.promise;
          if (scenario === "read-auth-navigation") return route.fulfill({status: 401, contentType: "application/json", body: JSON.stringify({error: "Synthetic read token required"})});
          return route.fulfill({response});
        });
        if (scenario === "read-auth-navigation") await page.route(/\/(setup|setup\/summary)$/, async route => {
          if (!holdReads) return route.continue();
          await readGate.promise;
          return route.fulfill({status:401,contentType:"application/json",body:JSON.stringify({error:"Synthetic read token required"})});
        });
        await page.route(new RegExp(`/agents/${key}/messages$`), async route => {
          const body = route.request().postDataJSON();
          writes++; ids.push(body.client_request_id); payloads.push(JSON.stringify(body));
          if ((body.prompt.includes("second message") || body.prompt.includes("corrected message"))) await page.evaluate(() => {globalThis.__receiptSecondObserved = true;});
          assert.equal(body.response_mode, "receipt");
          assert.equal(body.expected_server_id, agent.delegation.server_id);
          const response = await route.fetch();
          if (scenario === "input-rejection" && writes === 1) {
            assert.equal(response.status(),409);
            outcomes.push("rejected"); sizes.push((await response.body()).length);
            return route.fulfill({response});
          }
          assert([200,202].includes(response.status()), `receipt status ${response.status()}`);
          const data = await response.json();
          outcomes.push(data.receipt.outcome);
          sizes.push((await response.body()).length);
          if (writes === 1) {
            holdReads = true;
            if (scenario === "lost-processed-reload") return route.abort("connectionreset");
            if (scenario === "malformed") return route.fulfill({status: 200,contentType:"application/json",body:"invalid"});
            if (scenario === "wrong-server") return route.fulfill({status:202,contentType:"application/json",body:JSON.stringify({...data, receipt:{...data.receipt,server_id:"wrong-server"}})});
            await receiptGate.promise;
          }
          return route.fulfill({response});
        });
        const send = async text => {
          if (!(await page.locator("#prompt-input").isVisible())) await page.locator("details.focused-composer > summary").click();
          await page.locator("#prompt-input").fill(text);
          await page.locator("#composer").evaluate(form => form.requestSubmit());
        };
        if (scenario === "lost-processed-reload") {
          await page.locator("[data-prompt-attachment-input]").setInputFiles({name:"receipt-note.txt",mimeType:"text/plain",buffer:Buffer.from("Synthetic receipt attachment")});
          await page.waitForFunction(key => pendingAttachmentsFor(key).length === 1,key);
        }
        if(scenario === "input-rejection") await page.evaluate(key => {findAgent(key).suspended_inquiry = {id:"stale"};},key);
        await send(`Synthetic first message ${scenario}`);
        if (scenario === "input-rejection") {
          await page.locator("[data-composer-submission-error]").waitFor();
          assert.equal(await page.locator("[data-retry-prompt]").count(),0,"Bound rejection allows correction, not uncertain retry");
          assert.equal(await page.locator("#prompt-input").inputValue(),`Synthetic first message ${scenario}`);
          await page.waitForFunction(key => !findAgent(key).suspended_inquiry,key);
          await send("Synthetic corrected message");
          await page.waitForFunction(() => globalThis.__receiptSecondObserved || state.promptOutbox.entries.size > 0);
          await page.waitForFunction(() => state.promptOutbox.entries.size === 0);
          assert.notEqual(ids[0],ids[1],"A corrected rejected message is a new intent");
          readGate.release();
        } else if (["ordered-held-refresh", "read-auth-navigation", "immediate", "consumed-before-read"].includes(scenario)) {
          await page.waitForFunction(() => state.promptOutbox?.entries.size === 1);
          await page.waitForFunction(() => [...state.promptOutbox.entries.values()][0].status === "sending");
          if (scenario === "immediate") {
            assert.equal(await page.locator("[data-prompt-queue-entry]").count(), 0, "Idle send must not claim queued");
            await page.locator(".message-send-status").filter({hasText:"Sending"}).waitFor();
          } else {
            await page.locator("details[data-prompt-queue] > summary").filter({hasText:"queueing"}).waitFor();
            await page.locator("details[data-prompt-queue] > summary").click();
            await page.locator(".prompt-queue-entry-meta").filter({hasText:"Queueing"}).waitFor();
            assert.equal(await page.locator(".prompt-queue-entry-meta").filter({hasText:/· Queued/}).count(), 0, "No queued claim before validated receipt");
          }
          if (scenario === "read-auth-navigation") {
            await page.locator("#prompt-input").fill("Keep newer draft");
            await page.evaluate(() => {location.hash="#settings";});
            await page.waitForFunction(() => parseRoute().tab === "settings");
          }
          if (scenario === "consumed-before-read") {
            const read = await context.request.post(`${baseUrl}/agents/${key}/prompt-queue/read`,{data:{}});
            assert.equal(read.status(),200);
            const batch = await read.json();
            const complete = await context.request.post(`${baseUrl}/agents/${key}/queue-work/${batch.batch.batch_id}/complete`,{data:{dispositions:batch.entries.map(entry=>({entry_id:entry.id,outcome:"completed"}))}});
            assert.equal(complete.status(),200);
          }
          receiptGate.release();
          await page.waitForFunction(() => state.promptOutbox.entries.size === 0);
          if (scenario === "ordered-held-refresh") {
            await page.locator(".prompt-queue-entry-meta").filter({hasText:/· Queued/}).waitFor();
            assert(await page.locator("[data-edit-queued-prompt]").first().isDisabled(), "Receipt-only queue controls stay disabled");
            await page.waitForFunction(() => state.refreshInFlight);
            await send("Synthetic second message while refresh waits");
            await page.waitForFunction(() => globalThis.__receiptSecondObserved || [...state.promptOutbox.entries.values()].some(entry => entry.payload.prompt.includes("second message")));
            await page.waitForFunction(() => state.promptOutbox.entries.size === 0);
            assert.equal(writes, 2, "Second ordered write must pass the held read");
            assert.notEqual(ids[0], ids[1]);
            assert(heldReads > 0, "A real detail response was held");
          }
          readGate.release();
          if (scenario === "consumed-before-read") {
            await page.waitForFunction(key => optimisticPromptQueueEntries(key).length === 0 && findAgent(key).prompt_queue.entries.length === 0,key);
          }
          if (scenario === "read-auth-navigation") {
            await page.waitForFunction(() => !document.querySelector("#auth-panel").classList.contains("hidden"));
            assert.equal(await page.evaluate(() => parseRoute().tab), "settings", "Acceptance must not steal navigation");
            assert.equal(await page.evaluate(key => state.composerSubmissionErrors.has(key),key), false, "Read auth failure cannot reject accepted write");
          } else {
            await page.waitForFunction(() => !state.refreshInFlight);
            if (scenario === "immediate") await page.locator(".message-send-status").filter({hasText:"Sent"}).waitFor({timeout:3000}).catch(()=>{});
          }
        } else {
          await page.locator("[data-retry-prompt]").waitFor();
          assert.equal(writes, 1);
          if (scenario === "lost-processed-reload") {
            const read = await context.request.post(`${baseUrl}/agents/${key}/prompt-queue/read`, {data:{}});
            assert.equal(read.status(),200);
            readGate.release(); holdReads = false;
            await page.reload({waitUntil:"networkidle"});
            await page.locator("[data-retry-prompt]").waitFor();
          }
          await page.locator("[data-retry-prompt]").click();
          await page.waitForFunction(() => state.promptOutbox.entries.size === 0);
          assert.equal(writes,2);
          assert.equal(ids[0],ids[1],"Retry must preserve exact request identity");
          assert.equal(payloads[0],payloads[1],"Retry must preserve the exact message, files and contexts");
          if (scenario === "lost-processed-reload") assert.equal(outcomes[1],"replayed","Consumed prompt cannot be queued twice");
          readGate.release();
        }
        if (scenario === "ordered-held-refresh") {
          await page.waitForFunction(() => !state.refreshInFlight && !state.promptOutbox.entries.size);
          for (const appearance of ["dark","light"]) {
            await page.evaluate(mode => TychoAppearance.setPreference(mode),appearance);
            assert(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth+1), "horizontal overflow");
            if(captureDir) await page.screenshot({path:path.join(captureDir,`receipt-${width}-${appearance}.png`)});
          }
          refreshes = await page.evaluate(() => globalThis.__receiptRefreshes);
          assert(refreshes <= 2, `Reconciliation burst was not coalesced: ${refreshes}`);
        }
        assert.deepEqual(errors,[]);
        evidence.push({width,scenario,writes,unique_intents:new Set(ids).size,outcomes,bytes:sizes,exact_retry:payloads.length > 1 && ids[0]===ids[1] ? payloads[0]===payloads[1] : null,held_reads:heldReads,refreshes});
      } catch(error) {
        if(captureDir) await page.screenshot({path:path.join(captureDir,`failure-${width}-${scenario}.png`)}).catch(()=>{});
        throw error;
      } finally {
        receiptGate.release(); readGate.release();
        await context.request.post(`${baseUrl}/agents/${key}/archive`,{data:{}});
        await context.close();
      }
    }
  }
  if(captureDir) fs.writeFileSync(path.join(captureDir,"prompt-receipt-browser.json"),JSON.stringify(evidence,null,2));
  console.log(JSON.stringify(evidence,null,2));
  console.log("prompt_receipt_smoke: ok");
};
