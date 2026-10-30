const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");

module.exports = async ({ browser, baseUrl, captureDir }) => {
  const results = [];
  for (const width of [1440, 390]) {
    const context = await browser.newContext({ viewport: { width, height: 900 } });
    await context.route("**/*", route => new URL(route.request().url()).origin === baseUrl ? route.continue() : route.abort());
    const page = await context.newPage();
    const errors = [];
    page.on("pageerror", error => errors.push(error.message));
    await page.goto(`${baseUrl}/ui#agents`, { waitUntil: "networkidle" });
    const project = (await (await context.request.get(`${baseUrl}/projects/web`)).json()).project;
    const workspace = project.path;
    assert(workspace.includes("tycho-remote-ui-smoke"));
    const launchFile = path.join(path.dirname(workspace), "fake-codex.launches");
    const launches = key => fs.existsSync(launchFile) ? fs.readFileSync(launchFile, "utf8").split("\n").filter(line => line === key).length : 0;
    const buttons = () => page.locator("#quick-agent-form button[type=submit]");
    const open = async prompt => {
      await page.goto(`${baseUrl}/ui#agents`, { waitUntil: "networkidle" });
      await page.locator("#quick-agent-fab").click();
      await page.locator("#quick-agent-prompt").fill(prompt);
      await page.waitForFunction(() => quickAgentCanSubmit());
      assert.deepEqual(await buttons().evaluateAll(nodes => nodes.map(node => ({value: node.value, disabled: node.disabled}))), [
        {value: "create", disabled: false}, {value: "create-run", disabled: false},
      ]);
    };
    const agent = async key => {
      for (let attempt = 0; attempt < 100; attempt += 1) {
        const saved = (await (await context.request.get(`${baseUrl}/agents/${key}`)).json()).agent;
        if (!saved.running) return saved;
        await page.waitForTimeout(100);
      }
      throw new Error(`Fixture agent did not finish: ${key}`);
    };
    for (const action of ["create", "create-run", "enter", "name-enter"]) {
      await open(`Quick ${action} ${width}`);
      if (action === "create") {
        for (const close of ["x", "escape", "overlay"]) {
          if (close === "x") await page.locator("[data-quick-agent-close]").click();
          else if (close === "escape") await page.locator("#quick-agent-prompt").press("Escape");
          else await page.locator("#quick-agent-dialog").dispatchEvent("click");
          assert.equal(await page.locator("#quick-agent-dialog").evaluate(dialog => dialog.open), false);
          await page.locator("#quick-agent-fab").click();
          await page.waitForFunction(() => quickAgentCanSubmit());
          assert.equal(await page.locator("#quick-agent-prompt").inputValue(), `Quick ${action} ${width}`);
        }
        assert.equal(await page.locator("[data-quick-agent-discard]").count(), 0);
      }
      // Unknown options must block both buttons and the Enter shortcut.
      await page.evaluate(() => { quickAgent.localReady = false; syncQuickAgentOptions(); });
      assert.deepEqual(await buttons().evaluateAll(nodes => nodes.map(node => node.disabled)), [true, true]);
      await page.locator("#quick-agent-prompt").press("Enter");
      assert(await page.locator("#quick-agent-dialog").evaluate(dialog => dialog.open));
      await page.evaluate(() => { quickAgent.localReady = true; syncQuickAgentOptions(); });
      if (captureDir && action === "create") {
        assert(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth + 1));
        const boxes = await buttons().evaluateAll(nodes => nodes.map(node => { const r = node.getBoundingClientRect(); return {left:r.left,right:r.right,top:r.top,bottom:r.bottom}; }));
        assert(boxes.every(box => box.left >= 0 && box.right <= width && box.top >= 0 && box.bottom <= 900));
        await page.screenshot({path:path.join(captureDir, `quick-create-actions-${width}.png`), animations:"disabled"});
      }
      let release;
      const held = new Promise(resolve => { release = resolve; });
      const sent = [];
      await page.route(`${baseUrl}/agents`, async route => {
        if (route.request().method() !== "POST") return route.continue();
        sent.push(route.request().postDataJSON());
        await held;
        await route.continue();
      });
      const response = page.waitForResponse(r => r.url() === `${baseUrl}/agents` && r.request().method() === "POST");
      if (action === "name-enter") {
        await page.locator("[data-quick-agent-toggle]").click();
        await page.locator("#quick-agent-name").fill("Enter default");
        await page.locator("#quick-agent-name").press("Enter");
      } else if (action === "enter") await page.locator("#quick-agent-prompt").press("Enter");
      else await page.locator(`#quick-agent-form button[value=${action}]`).click();
      await page.locator(".pending-agent-conversation").waitFor();
      const pending = await page.evaluate(() => {
        const entry = [...pendingAgentCreations.values()].find(entry => entry.pending);
        return {body:entry.request.body,disabled:[...entry.form.querySelectorAll('button[type="submit"]')].map(button=>button.disabled)};
      });
      assert.deepEqual(pending.disabled, [true, true]);
      assert.equal(pending.body.start, action !== "create");
      // The detached form cannot submit another action while its request is pending.
      await page.evaluate(() => { const entry = [...pendingAgentCreations.values()].find(entry => entry.pending); beginAgentCreation(entry.payload, entry.form); });
      release();
      const created = (await (await response).json()).agent;
      await page.waitForFunction(() => location.hash.startsWith("#agent/"));
      const saved = await agent(created.key);
      assert.equal(sent.length, 1);
      assert.equal(sent[0].start, action !== "create");
      assert.equal(saved.run_count, action === "create" ? 0 : 1);
      assert.equal(saved.running, false, JSON.stringify({action,key:saved.key,created:created.key,status:saved.status,runCount:saved.run_count}));
      assert.equal(launches(saved.key), action === "create" ? 0 : 1);
      results.push({width,action,requests:sent.length,start:sent[0].start,runCount:saved.run_count,harnessLaunches:launches(saved.key),pendingDisabled:pending.disabled});
      await page.unroute(`${baseUrl}/agents`);
    }
    for (const start of [false, true]) {
      await open(`Uncertain Quick ${start} ${width}`);
      let accepted;
      const sent = [];
      await page.route(`${baseUrl}/agents`, async route => {
        if (route.request().method() !== "POST") return route.continue();
        sent.push(route.request().postDataJSON());
        const response = await route.fetch();
        accepted = (await response.json()).agent;
        await route.abort("connectionfailed");
      }, {times:1});
      await page.locator(`#quick-agent-form button[value=${start ? "create-run" : "create"}]`).click();
      await page.locator("[data-retry-agent-create]").waitFor();
      assert.equal(await page.locator("[data-edit-agent-create]").count(),0);
      await page.reload({waitUntil:"networkidle"});
      const response = page.waitForResponse(r => r.url() === `${baseUrl}/agents` && r.request().method() === "POST");
      await page.locator("[data-retry-agent-create]").click();
      const retried = await response;
      assert.deepEqual(retried.request().postDataJSON(),sent[0]);
      assert.equal((await retried.json()).agent.key,accepted.key);
      await page.waitForFunction(() => location.hash.startsWith("#agent/"));
      const saved = await agent(accepted.key);
      assert.equal(saved.run_count,start ? 1 : 0);
      assert.equal(launches(saved.key),start ? 1 : 0);
      results.push({width,action:"uncertain-receipt-reload-retry",start,sameBody:true,sameAgent:true,runCount:saved.run_count,harnessLaunches:launches(saved.key)});
      // Rejection must preserve the selected action in the shared request snapshot.
      await open(`Rejected Quick ${start} ${width}`);
      await page.route(`${baseUrl}/agents`, route => route.fulfill({status:403,json:{error:"Fixture permission changed",details:{creation_rejected:true}}}),{times:1});
      await page.locator(`#quick-agent-form button[value=${start ? "create-run" : "create"}]`).click();
      await page.locator("[data-edit-agent-create]").waitFor();
      assert.match(await page.locator("[role=alert]").innerText(),/Fixture permission changed/);
      const rejected = await page.evaluate(() => [...pendingAgentCreations.values()].find(entry=>entry.rejected).request.body);
      assert.equal(rejected.start,start);
      await page.locator("[data-edit-agent-create]").click();
      assert.equal(await page.locator("#agent-prompt").inputValue(),`Rejected Quick ${start} ${width}`);
      const correctedResponse = page.waitForResponse(r=>r.url()===`${baseUrl}/agents` && r.request().method()==="POST");
      await page.locator(`#agent-form button[value=${start ? "create-run" : "create"}]`).click();
      const corrected = await correctedResponse;
      assert.equal(corrected.request().postDataJSON().start,start);
      assert.notEqual(corrected.request().postDataJSON().client_request_id,rejected.client_request_id);
      const correctedAgent = (await corrected.json()).agent;
      await page.waitForFunction(()=>location.hash.startsWith("#agent/"));
      assert.equal((await agent(correctedAgent.key)).run_count,start?1:0);
      results.push({width,action:"rejection-edit-correction",start,newRequestId:true});
    }
    assert.deepEqual(errors,[]);
    await context.close();
  }
  if(captureDir) fs.writeFileSync(path.join(captureDir,"create-actions-results.json"),JSON.stringify(results,null,2));
  console.log("quick-agent-create-actions-smoke: ok",JSON.stringify(results));
};
