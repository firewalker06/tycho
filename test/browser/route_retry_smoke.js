const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");

module.exports = async ({ browser, baseUrl, agentKey, captureDir }) => {
  const detail = await (await fetch(`${baseUrl}/agents/${encodeURIComponent(agentKey)}`)).json();
  const document = detail.agent.attachments.find(a => a.title === "Cold route guide");
  const image = detail.agent.attachments.find(a => a.title === "Retry image");
  assert(document && image);
  const key = encodeURIComponent(agentKey);
  const routes = [
    { name: "project-diff", hash: "#project/web/diff?scope=worktree", endpoint: /\/projects\/web\/git\/diff(?:\?|$)/, selector: ".diff-viewer", text: "Cold route diff fixture" },
    { name: "pull-requests", hash: `#agent/${key}/pr-diffs`, endpoint: /\/agents\/[^/]+\/pull-requests(?:\?|$)/, selector: ".pr-diff-list", text: "123" },
    { name: "attachment", hash: `#attachment/${encodeURIComponent(document.id)}`, endpoint: new RegExp(`/attachments/${document.id}(?:\\?|$)`), selector: ".attachment-viewer", text: "Workspace guide" },
    { name: "image", hash: `#agent/${key}/attachment/${encodeURIComponent(image.id)}`, endpoint: new RegExp(`/attachments/${image.id}/blob(?:\\?|$)`), selector: ".attachment-viewer img", text: null },
  ];
  const evidence = [];
  for (const [viewportName, viewport] of [["desktop", { width: 1440, height: 900 }], ["mobile", { width: 390, height: 844 }]]) {
    for (const route of routes) {
      const scenarios = ["active-503", ...(routes.indexOf(route) < 2 ? ["inactive-503", "active-rejected", "inactive-rejected", "blur-failure", "blur-recovery", "backoff"] : [])];
      for (const scenario of scenarios) {
        const context = await browser.newContext({ viewport, isMobile: viewportName === "mobile", hasTouch: viewportName === "mobile" });
        const page = await context.newPage();
        const errors = [];
        page.on("pageerror", e => errors.push(e.message));
        let healthy = false, attempts = 0, releaseFailure, releaseRecovery, signalFailure, signalRecovery;
        const failureHeld = new Promise(resolve => { signalFailure = resolve; });
        const recoveryHeld = new Promise(resolve => { signalRecovery = resolve; });
        const failureBarrier = new Promise(resolve => { releaseFailure = resolve; });
        const recoveryBarrier = new Promise(resolve => { releaseRecovery = resolve; });
        // Exercise real automatic timers with advertised fixture intervals. No
        // refresh(), schedule(), or route navigation drives the recovery.
        await page.route(/\/setup(?:\/summary)?$/, async r => {
          const response = await r.fetch(); const data = await response.json();
          data.setup.refresh_intervals = { active_ms: 120, idle_ms: 120, hidden_ms: 500 };
          await r.fulfill({ response, json: data });
        });
        await page.route(route.endpoint, async r => {
          attempts++;
          if (!healthy) {
            if (scenario === "blur-failure") { signalFailure(); await failureBarrier; }
            if (scenario.endsWith("rejected")) return r.abort("failed");
            return r.fulfill({ status: 503, contentType: "application/json", body: '{"error":"Temporary selected-route failure"}' });
          }
          const response = await r.fetch();
          if (scenario === "blur-recovery") { signalRecovery(); await recoveryBarrier; }
          await r.fulfill({ response });
        });
        if (scenario.startsWith("inactive")) await page.addInitScript(() => { document.hasFocus = () => false; });
        await page.goto(`${baseUrl}/ui${route.hash}`, { waitUntil: "load" });
        if (scenario.startsWith("inactive")) {
          await page.waitForTimeout(150); assert.equal(attempts, 0);
          await page.evaluate(() => { delete document.hasFocus; window.dispatchEvent(new Event("focus")); });
        }
        if (scenario === "blur-failure") {
          await Promise.race([failureHeld, page.waitForTimeout(10000).then(() => { throw Error("failure request not held"); })]);
          await page.evaluate(() => { document.hasFocus = () => false; window.dispatchEvent(new Event("blur")); });
          releaseFailure();
        }
        await page.waitForFunction(() => state.failureCount > 0 && !state.refreshInFlight);
        assert.equal(await page.evaluate(() => state.initialRouteLoaded), false, `${route.name}: failed endpoint must not initialize`);
        if (scenario === "backoff") {
          await page.waitForFunction(() => state.failureCount >= 2 && !state.refreshInFlight);
          const backedOff = attempts;
          await page.waitForTimeout(180);
          assert.equal(attempts, backedOff, "repeated route errors retain the longer backoff");
        }
        const failedAttempts = attempts;
        healthy = true;
        if (scenario === "blur-failure") {
          await page.waitForTimeout(250); assert.equal(attempts, failedAttempts);
          assert.equal(await page.evaluate(() => state.timer), null);
          await page.evaluate(() => { delete document.hasFocus; window.dispatchEvent(new Event("focus")); });
        }
        if (scenario === "blur-recovery") {
          await Promise.race([recoveryHeld, page.waitForTimeout(10000).then(() => { throw Error("automatic recovery request not held"); })]);
          const heldAttempts = attempts;
          await page.evaluate(() => { document.hasFocus = () => false; window.dispatchEvent(new Event("blur")); });
          releaseRecovery();
          await page.waitForFunction(() => !state.refreshInFlight);
          assert.equal(await page.evaluate(() => state.initialRouteLoaded), false);
          assert.equal(await page.evaluate(() => state.timer), null);
          await page.waitForTimeout(250); assert.equal(attempts, heldAttempts);
          await page.evaluate(() => { delete document.hasFocus; for (let i = 0; i < 8; i++) { window.dispatchEvent(new Event("focus")); document.dispatchEvent(new Event("visibilitychange")); } });
        }
        await page.waitForFunction(() => state.initialRouteLoaded && !state.refreshInFlight && document.getElementById("tycho-boot-shell").hidden);
        const content = page.locator(route.selector).first();
        await content.waitFor({ state: "visible" });
        if (route.text) assert((await content.textContent()).includes(route.text));
        else await content.evaluate(img => img.decode());
        const recoveredAttempts = attempts;
        assert.equal(recoveredAttempts, failedAttempts + 1, "one automatic healthy route request, including return after held completion");
        const hash = await page.evaluate(() => location.hash);
        await page.evaluate(() => { for (let i = 0; i < 8; i++) { window.dispatchEvent(new Event("focus")); document.dispatchEvent(new Event("visibilitychange")); } });
        await page.waitForTimeout(350); // More than two automatic catalog cycles.
        assert.equal(attempts, recoveredAttempts, "loaded workspace does not retry endpoint or duplicate requests");
        assert.equal(await page.evaluate(() => location.hash), hash);
        assert.deepEqual(errors, []);
        if (captureDir && scenario === "active-503" && routes.indexOf(route) < 2) {
          const file = content.locator(".diff-file").first();
          if (await file.count() && !(await file.evaluate(el => el.open))) await file.locator("summary").click();
          await page.screenshot({ path: path.join(captureDir, `recovered-${route.name}-${viewportName}.png`) });
        }
        evidence.push({ viewport: viewportName, route: route.name, scenario, failedAttempts, recoveredAttempts, automaticRecovery: true, readyAfterFailure: false, selectedRoutePreserved: true, fixtureIntervalsMs: { active: 120, idle: 120, backoff: 500 } });
        await context.close();
      }
    }
  }
  console.log(JSON.stringify(evidence, null, 2));
  if (captureDir) fs.writeFileSync(path.join(captureDir, "route-retry-evidence.json"), JSON.stringify(evidence, null, 2));
};
