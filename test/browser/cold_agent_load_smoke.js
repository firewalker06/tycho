const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");

module.exports = async ({ browser, baseUrl, agentKey, captureDir }) => {
  const evidence = [];
  // Measure the complete real route request chain in a fresh browser context,
  // then a forced warm refresh. Fixed shell delay models the measured slow shell.
  // Optional old assets are supplied only by the external evidence runner.
  const baseline = process.env.TYCHO_REMOTE_UI_COLD_LOAD_BASELINE;
  if (process.env.TYCHO_REMOTE_UI_COLD_LOAD_BENCHMARK === "1") {
    for (let sample = 0; sample < 5; sample++) {
      const context = await browser.newContext({ viewport: { width: 390, height: 844 }, isMobile: true, hasTouch: true });
      const page = await context.newPage();
      let oldAssetServed = false;
      if (baseline) await page.route("**/ui.js?*", route => {
        oldAssetServed = true;
        return route.fulfill({ contentType: "text/javascript", body: fs.readFileSync(baseline, "utf8") });
      });
      await page.route(/\/(setup\/summary|schedules)$/, async route => {
        const response = await route.fetch();
        await new Promise(resolve => setTimeout(resolve, 250));
        await route.fulfill({ response });
      });
      const requests = [], pending = [];
      page.on("response", response => {
        const pathname = new URL(response.url()).pathname;
        if (response.request().resourceType() !== "fetch") return;
        const record = { path: pathname, status: response.status(), at: Date.now(), serverTiming: response.headers()["server-timing"] || null };
        requests.push(record);
        pending.push(response.body().then(body => { record.bytes = body.length; }, () => { record.bytes = null; }));
      });
      let start = Date.now();
      await page.goto(`${baseUrl}/ui#agent/${encodeURIComponent(agentKey)}`, { waitUntil: "load" });
      await page.waitForFunction(() => state.initialRouteLoaded && document.getElementById("tycho-boot-shell").hidden);
      if (baseline) assert(oldAssetServed, "the pinned baseline asset must be used");
      const firstContentMs = Date.now() - start;
      await page.waitForFunction(() => !state.refreshInFlight);
      const firstChainMs = Date.now() - start;
      start = Date.now();
      await page.evaluate(() => { window.__coldLoadWarm = refresh({ force: true }); });
      await page.waitForFunction(() => !state.refreshInFlight);
      const warmChainMs = Date.now() - start;
      await Promise.all(pending);
      evidence.push({ sample, source: baseline ? "baseline" : "after", firstContentMs, firstChainMs, warmChainMs, requests });
      await page.unrouteAll({ behavior: "ignoreErrors" });
      await context.close();
    }
    if (captureDir) fs.writeFileSync(path.join(captureDir, "chain.json"), JSON.stringify(evidence, null, 2));
    console.log(JSON.stringify(evidence, null, 2));
    return;
  }

  for (const [label, viewport] of [["desktop", { width: 1440, height: 900 }], ["mobile", { width: 390, height: 844 }]]) {
    for (const mode of ["success", "auth", "error", "setup", "navigate", "stale", "settings"]) {
      const context = await browser.newContext({ viewport, isMobile: label === "mobile", hasTouch: label === "mobile" });
      const page = await context.newPage();
      const errors = [];
      page.on("pageerror", error => errors.push(error.message));
      let release, held = 0, shellRequests = 0;
      const barrier = new Promise(resolve => { release = resolve; });
      await page.route(/\/(setup\/summary|schedules)$/, async route => {
        const requestNumber = ++shellRequests;
        const response = await route.fetch();
        if (mode === "stale" && requestNumber > 2) return route.fulfill({ response });
        held++;
        await barrier;
        if (mode === "auth" || mode === "stale") return route.fulfill({ status: 401, contentType: "application/json", body: '{"error":"Synthetic token required"}' });
        if (mode === "error") return route.fulfill({ status: 503, contentType: "application/json", body: '{"error":"Synthetic shell unavailable"}' });
        if (mode === "setup" && route.request().url().includes("setup/summary")) {
          const data = await response.json();
          data.setup.onboarding = { ...data.setup.onboarding, active: true };
          return route.fulfill({ response, json: data });
        }
        await route.fulfill({ response });
      });
      await page.goto(`${baseUrl}/ui#agent/${encodeURIComponent(agentKey)}`, { waitUntil: "load" });
      await page.waitForSelector("#prompt-input", { timeout: 10000 });
      await page.waitForFunction(() => state.conversations[parseRoute().key]?.blocks?.length > 0);
      for (let attempt = 0; held < 2 && attempt < 100; attempt++) await page.waitForTimeout(20);
      assert.equal(held, 2, "both shell responses must still be held");
      await page.waitForFunction(() => document.getElementById("tycho-boot-shell").hidden);
      await page.locator("[data-agent-conversation-scroll]").getByText(/Tail message/).first().waitFor({ state: "visible" });
      const draft = `Unsent ${label} ${mode}`;
      await page.locator("#prompt-input").fill(draft);
      await page.locator("#prompt-input").focus();
      const focused = await page.evaluate(() => document.activeElement.id);
      const routeBefore = await page.evaluate(() => location.hash);
      const scrollBefore = await page.locator("[data-agent-conversation-scroll]").evaluate(el => {
        el.scrollTop = Math.min(400, Math.max(0, (el.scrollHeight - el.clientHeight) / 2));
        return el.scrollTop;
      });
      if (captureDir && mode === "success") await page.screenshot({ path: path.join(captureDir, `cold-agent-before-shell-${label}.png`) });
      let settingsBefore = null, settingsAfter = null;
      if (mode === "settings") {
        const catalogSequence = await page.evaluate(() => state.resourceRequestSequence);
        await page.evaluate(() => navigate({ type: "tab", tab: "settings" }));
        await page.waitForFunction(() => state.setupDetailed && !document.body.dataset.routeLoading);
        await page.locator('[aria-controls="settings-panel-automation"]').click();
        await page.locator("[data-harness-name]").first().waitFor({ state: "visible" });
        settingsBefore = await page.evaluate(() => ({
          hash: location.hash, detailed: state.setupDetailed,
          harnesses: state.setup.harnesses.length, tools: state.setup.tools.length,
          harnessRows: document.querySelectorAll("[data-harness-name]").length,
          catalogSequence: state.resourceRequestSequence,
        }));
        assert(settingsBefore.harnesses > 0 && settingsBefore.tools > 0 && settingsBefore.harnessRows > 0,
          "full Settings readiness must complete before the old shell is released");
        assert.equal(settingsBefore.catalogSequence, catalogSequence,
          "setup ordering must remain independent of catalog generations");
      }
      if (mode === "navigate") await page.evaluate(() => navigate({ type: "tab", tab: "agents" }));
      if (mode === "stale") await page.evaluate(() => refresh({ force: true }));
      release();
      await page.waitForFunction(() => !state.refreshInFlight);
      if (mode === "settings") {
        settingsAfter = await page.evaluate(() => ({
          hash: location.hash, detailed: state.setupDetailed,
          harnesses: state.setup.harnesses.length, tools: state.setup.tools.length,
          harnessRows: document.querySelectorAll("[data-harness-name]").length,
          catalogSequence: state.resourceRequestSequence,
        }));
        console.log(JSON.stringify({ label, mode, settingsBefore, settingsAfter }));
        assert.deepEqual(settingsAfter, settingsBefore,
          "late initial setup summary must not erase newer detailed Settings readiness");
        assert(await page.locator("[data-harness-name]").first().isVisible(), "Settings readiness stays visible");
        if (captureDir) {
          await page.locator("[data-harness-name]").first().evaluate(el => el.scrollIntoView({ block: "center", behavior: "instant" }));
          await page.screenshot({ path: path.join(captureDir, `cold-agent-settings-after-shell-${label}.png`) });
        }
        // Return through real navigation; the conversation draft remains available.
        await page.evaluate(hash => { location.hash = hash; }, routeBefore);
        await page.waitForSelector("#prompt-input");
        assert.equal(await page.locator("#prompt-input").inputValue(), draft);
      }
      if (mode === "stale") {
        assert.equal(await page.locator("#auth-panel").isVisible(), false, "old shell auth error must not replace a newer success");
        assert.equal(await page.evaluate(() => state.failureCount), 0);
        assert.equal(await page.locator("#prompt-input").inputValue(), draft);
      }
      if (mode === "auth") assert.equal(await page.locator("#auth-panel").isVisible(), true);
      if (mode === "error") assert.match(await page.evaluate(() => state.connection), /Offline.*Synthetic shell unavailable/);
      if (mode === "setup") await page.locator(".onboarding-page").waitFor({ state: "visible" });
      if (mode === "navigate") assert.notEqual(await page.evaluate(() => location.hash), routeBefore);
      if (mode === "success" || mode === "error") {
        assert.equal(await page.locator("#prompt-input").inputValue(), draft);
        assert.equal(await page.evaluate(() => document.activeElement.id), focused);
        assert.equal(await page.evaluate(() => location.hash), routeBefore);
        assert.equal(await page.locator("[data-agent-conversation-scroll]").evaluate(el => el.scrollTop), scrollBefore);
      }
      if (["auth", "error", "setup"].includes(mode)) {
        await page.unroute(/\/(setup\/summary|schedules)$/);
        await page.evaluate(() => refresh({ force: true }));
        await page.waitForSelector("#prompt-input");
        assert.equal(await page.locator("#auth-panel").isVisible(), false);
        assert.equal(await page.locator("#prompt-input").inputValue(), draft);
        assert.equal(await page.evaluate(() => state.failureCount), 0);
      }
      assert.equal(await page.evaluate(() => document.documentElement.scrollWidth > innerWidth), false);
      assert.deepEqual(errors, []);
      evidence.push({ label, mode, contentBeforeShell: true, shellResponsesHeld: held, draftPreserved: true, settingsBefore, settingsAfter, passed: true });
      await page.unrouteAll({ behavior: "ignoreErrors" });
      await context.close();
    }
  }
  if (captureDir) fs.writeFileSync(path.join(captureDir, "cold-agent-load-browser.json"), JSON.stringify(evidence, null, 2));
  console.log(JSON.stringify(evidence, null, 2));
};
