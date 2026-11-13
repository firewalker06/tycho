const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");

module.exports = async ({ browser, baseUrl, captureDir }) => {
  const results = [];
  for (const width of [1440, 390]) for (const theme of ["dark", "light"]) for (const status of ["paused", "stopped"]) {
    const context = await browser.newContext({ viewport: { width, height: 900 }, isMobile: width < 500, hasTouch: width < 500 });
    const page = await context.newPage();
    const errors = [];
    page.on("pageerror", error => errors.push(error.message));
    await page.addInitScript(() => { document.hasFocus = () => true; });
    page.setDefaultTimeout(15000);
    const key = `manual-${status}-${width}-${theme}`;
    const endpoint = `${baseUrl}/agents/${key}/prompt-queue/process`;
    try {
      await page.goto(`${baseUrl}/ui#settings`, { waitUntil: "networkidle" });
      await page.locator("[data-appearance-preference]").selectOption(theme);
      const scheduleBefore = await (await page.request.get(`${baseUrl}/schedules/${key}`)).json();
      await page.goto(`${baseUrl}/ui#agent/${key}`, { waitUntil: "networkidle" });
      await page.locator("[data-prompt-queue] > summary").click();
      const queue = page.locator("[data-prompt-queue]");
      const all = page.locator('[data-queue-action="process-all"]');
      assert.equal(await all.innerText(), "Process queue once");
      assert(await all.isEnabled());
      assert((await queue.innerText()).includes(`The schedule stays ${status}. Automatic dispatch stays off.`));
      await page.locator('[data-select-queue-entry="first"]').focus();
      await page.keyboard.press("Space");
      await page.evaluate(async () => refresh({ force: true }));
      assert(await page.locator('[data-select-queue-entry="first"]').isChecked(), "polling must keep the selection");
      assert(await queue.evaluate(node => node.open), "polling must keep the queue open");
      await all.scrollIntoViewIfNeeded();
      const bounds = await queue.evaluate(node => ({ overflow: node.scrollWidth > node.clientWidth,
        right: node.getBoundingClientRect().right, viewport: innerWidth }));
      assert(!bounds.overflow && bounds.right <= bounds.viewport, "queue must fit the viewport");
      if (captureDir) await page.screenshot({ path: path.join(captureDir, `manual-queue-${status}-${width}-${theme}.png`) });
      let release;
      const gate = new Promise(resolve => { release = resolve; });
      let writes = 0;
      await page.route(endpoint, async route => {
        writes++;
        assert.deepEqual(route.request().postDataJSON(), { entry_ids: ["first"], expected_entry_ids: ["first", "later"] });
        await gate;
        await route.continue();
      });
      const requestSeen = page.waitForRequest(endpoint);
      await page.locator('[data-queue-action="process-selected"]').click();
      await requestSeen;
      assert(await all.isDisabled(), "concurrent clicks must be disabled");
      await page.evaluate(async () => refresh({ force: true }));
      assert(await all.isDisabled(), "polling must preserve the pending action");
      const responseSeen = page.waitForResponse(endpoint);
      release();
      const response = await responseSeen;
      const result = await response.json();
      assert(response.ok() && ["started", "accepted"].includes(result.status));
      assert.deepEqual(result.processed_entry_ids, ["first"]);
      await page.waitForFunction(key => !state.pendingPromptQueueActions.has(key), key);
      // Poll the real server through native fake-harness completion, then prove later work remains queued.
      let agent;
      for (let attempt = 0; attempt < 100; attempt++) {
        agent = (await (await page.request.get(`${baseUrl}/agents/${key}`)).json()).agent;
        if (!agent.running && agent.run_count === 2) break;
        await page.waitForTimeout(100);
      }
      assert.equal(agent.run_count, 2);
      assert.equal(agent.running, false);
      await page.waitForTimeout(5500);
      agent = (await (await page.request.get(`${baseUrl}/agents/${key}`)).json()).agent;
      assert.equal(agent.run_count, 2, "automatic processing must stay suppressed");
      assert.deepEqual(agent.prompt_queue.entries.map(entry => entry.id), ["later"]);
      const scheduleAfter = await (await page.request.get(`${baseUrl}/schedules/${key}`)).json();
      // session_run_count is a derived agent metric, not persisted schedule state.
      delete scheduleBefore.schedule.session_run_count;
      delete scheduleAfter.schedule.session_run_count;
      assert.deepEqual(scheduleAfter, scheduleBefore, "manual action must leave schedule controls and history unchanged");
      assert.equal(writes, 1);
      await page.goto(`${baseUrl}/ui#agent/${key}-inquiry`, { waitUntil: "networkidle" });
      await page.locator("[data-prompt-queue] > summary").click();
      assert((await page.locator("[data-prompt-queue]").innerText()).includes("Answer the inquiry or send a new prompt"));
      assert(await page.locator('[data-queue-action="process-all"]').isDisabled());
      await page.evaluate(async () => refresh({ force: true }));
      assert(await page.locator('[data-queue-action="process-all"]').isDisabled());
      if (captureDir && status === "stopped") await page.screenshot({ path: path.join(captureDir, `manual-queue-inquiry-${width}-${theme}.png`) });
      assert.deepEqual(errors, []);
      results.push({ width, theme, status, writes, runCount: agent.run_count, remaining: ["later"] });
    } finally { await context.close(); }
  }
  if (captureDir) fs.writeFileSync(path.join(captureDir, "manual-queue-results.json"), JSON.stringify(results, null, 2));
  console.log(`manual_schedule_queue_smoke: ${results.length} real API/fake-harness desktop/mobile cases passed`);
};
