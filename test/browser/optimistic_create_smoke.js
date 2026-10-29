const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");

module.exports = async ({ browser, baseUrl, captureDir }) => {
  const receipts = [];
  if (captureDir) fs.mkdirSync(captureDir, { recursive: true });
  for (const width of [1440, 390]) {
    const context = await browser.newContext({ viewport: { width, height: 900 }, isMobile: width < 500 });
    const page = await context.newPage();
    const errors = [];
    page.on("pageerror", error => errors.push(error.message));
    const capture = async label => {
      assert(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth + 1), "horizontal overflow");
      if (captureDir) await page.screenshot({ path: path.join(captureDir, `create-${label}-${width}.png`) });
    };
    const createCount = async () => (await (await context.request.get(`${baseUrl}/agents`)).json()).agents.length;
    const openForm = async quick => {
      await page.goto(`${baseUrl}/ui#${quick ? "agents" : "project/web"}`, { waitUntil: "networkidle" });
      if (quick) {
        await page.locator("#quick-agent-fab").click();
        await page.locator("#quick-agent-prompt").fill(`Keep quick prompt ${width}`);
      } else {
        await page.locator("#view [data-create-agent=web]").first().click();
        await page.locator("#agent-prompt").fill(`Keep project prompt ${width}`);
        assert.equal(await page.locator("#agent-form select[name=project_key]").count(), 0, "removed Project field returned");
      }
    };
    for (const quick of [true, false]) {
      await openForm(quick);
      let release;
      const held = new Promise(resolve => { release = resolve; });
      let calls = 0;
      let payload;
      await page.route(`${baseUrl}/agents`, async route => {
        if (route.request().method() !== "POST") return route.continue();
        calls += 1;
        payload = route.request().postDataJSON();
        await held;
        await route.continue();
      });
      const before = await createCount();
      const start = Date.now();
      const submit = quick ? "#quick-agent-form button[type=submit]" : "#agent-form button[value=create]";
      await page.locator(submit).click();
      await page.locator(".pending-agent-conversation").waitFor();
      const visibleMs = Date.now() - start;
      assert(visibleMs < 1500, `pending view took ${visibleMs}ms`);
      assert.equal(await page.locator("#quick-agent-dialog").evaluate(el => el.open), false);
      assert.match(await page.locator(".pending-agent-conversation").innerText(), /Creating your agent/);
      assert.equal(await page.locator(".pending-agent-conversation h1").evaluate(el => el === document.activeElement), true, "pending heading did not receive focus");
      assert.equal(await page.locator("#composer").count(), 0, "pending request must not allow agent actions");
      await page.locator(".pending-agent-conversation summary").click();
      assert.match(await page.locator(".creation-request-prompt").innerText(), new RegExp(`Keep ${quick ? "quick" : "project"} prompt ${width}`));
      await page.evaluate(() => refresh({ force: true }));
      assert.equal(await page.locator(".pending-agent-conversation details").getAttribute("open"), "");
      assert.equal(calls, 1);
      assert.equal(await createCount(), before);
      await capture(quick ? "quick-pending" : "project-pending");
      if (!quick) {
        // Going Back to the create form must retain this request and must not submit again.
        await page.goBack();
        await page.locator(".pending-agent-conversation").waitFor();
        assert.equal(await page.locator("#agent-form").count(), 0);
      }
      release();
      await page.waitForFunction(() => location.hash.startsWith("#agent/"));
      await page.locator("#composer").waitFor();
      const key = await page.evaluate(() => parseRoute().key);
      const agent = (await (await context.request.get(`${baseUrl}/agents/${key}`)).json()).agent;
      assert.equal(agent.project_key, "web");
      assert.equal(agent.prompt, payload.prompt);
      assert.equal(payload.start, quick);
      assert.equal(agent.run_count, quick ? 1 : 0);
      assert.equal(await createCount(), before + 1);
      await capture(quick ? "quick-success" : "project-success");
      receipts.push({ width, flow: quick ? "quick" : "project-create-only", visibleMs, postCount: calls, runCount: agent.run_count });
      await page.unroute(`${baseUrl}/agents`);
    }

    // A definitive server error preserves request data and supports keyboard retry.
    await openForm(false);
    const beforeFailure = await createCount();
    let releaseFailure;
    const failureHeld = new Promise(resolve => { releaseFailure = resolve; });
    await page.route(`${baseUrl}/agents`, async route => {
      await failureHeld;
      await route.fulfill({ status: 503, contentType: "application/json", body: JSON.stringify({ error: "Fixture create service unavailable" }) });
    }, { times: 1 });
    await page.locator("#agent-form button[value=create-run]").click();
    await page.locator(".pending-agent-conversation").waitFor();
    releaseFailure();
    const retry = page.locator("[data-retry-agent-create]");
    await retry.waitFor();
    assert.equal(await retry.evaluate(el => el === document.activeElement), true, "failure did not focus retry");
    assert.match(await page.locator("[role=alert]").innerText(), /Fixture create service unavailable/);
    await page.locator(".pending-agent-conversation summary").click();
    assert.equal(await page.locator(".creation-request-prompt").innerText(), `Keep project prompt ${width}`);
    await page.evaluate(() => refresh({ force: true }));
    await capture("error");
    let releaseRetry;
    const retryHeld = new Promise(resolve => { releaseRetry = resolve; });
    let retryCalls = 0;
    await page.route(`${baseUrl}/agents`, async route => { retryCalls++; await retryHeld; await route.continue(); });
    await retry.focus();
    await page.keyboard.press("Enter");
    await page.locator(".pending-agent-conversation[aria-busy=true]").waitFor();
    await page.evaluate(() => {
      const entry = [...pendingAgentCreations.values()].find(entry => entry.pending);
      sendPendingAgentCreation(entry);
      sendPendingAgentCreation(entry);
    });
    assert.equal(retryCalls, 1);
    releaseRetry();
    await page.waitForFunction(() => location.hash.startsWith("#agent/"));
    assert.equal(await createCount(), beforeFailure + 1);
    await page.unroute(`${baseUrl}/agents`);

    // The server accepts, but the response is lost. Reload then retry with the same ID.
    await openForm(false);
    const beforeLoss = await createCount();
    let accepted;
    await page.route(`${baseUrl}/agents`, async route => {
      const response = await route.fetch();
      assert.equal(response.status(), 201);
      accepted = (await response.json()).agent;
      await route.abort("connectionfailed");
    }, { times: 1 });
    await page.locator("#agent-form button[value=create]").click();
    await retry.waitFor();
    await page.reload({ waitUntil: "networkidle" });
    await retry.waitFor();
    await retry.click();
    await page.waitForFunction(() => location.hash.startsWith("#agent/"));
    assert.equal(await page.evaluate(() => parseRoute().key), accepted.key);
    assert.equal(await createCount(), beforeLoss + 1, "lost response retry duplicated agent");

    // A user who leaves the pending view keeps their chosen page after success.
    await openForm(false);
    let releaseNavigation;
    const navigationHeld = new Promise(resolve => { releaseNavigation = resolve; });
    await page.route(`${baseUrl}/agents`, async route => { await navigationHeld; await route.continue(); }, { times: 1 });
    await page.locator("#agent-form button[value=create]").click();
    await page.locator(".pending-agent-conversation").waitFor();
    await page.evaluate(() => navigate({ type: "project", key: "web" }));
    await page.waitForFunction(() => location.hash === "#project/web");
    releaseNavigation();
    await page.waitForFunction(() => [...pendingAgentCreations.values()].every(entry => !entry.pending));
    assert.equal(await page.evaluate(() => location.hash), "#project/web", "success overrode user navigation");
    assert.deepEqual(errors, []);
    await context.close();
  }
  console.log(JSON.stringify({ test: "optimistic-create", receipts }));
  if (captureDir) fs.writeFileSync(path.join(captureDir, "browser-receipts.json"), JSON.stringify(receipts, null, 2));
};
