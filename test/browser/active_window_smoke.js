const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");

const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));
const facts = page => page.evaluate(() => ({
  active: pollingWindowIsActive(), hidden: document.hidden, focused: document.hasFocus(),
  refreshTimer: state.timer !== null, activityTimer: state.activityTimer !== null,
  refreshing: state.refreshInFlight, activity: state.activityInFlight,
}));

module.exports = async ({ browser, baseUrl, agentKey, captureDir }) => {
  const evidence = [];
  for (const [label, viewport] of [["desktop", { width: 1440, height: 900 }], ["mobile", { width: 390, height: 844 }]]) {
    const context = await browser.newContext({ viewport, isMobile: label === "mobile", hasTouch: label === "mobile" });
    const page = await context.newPage();
    const errors = [];
    page.on("pageerror", error => errors.push(error.message));
    const requests = [];
    page.on("request", request => {
      if (["fetch", "xhr"].includes(request.resourceType())) requests.push({ time: Date.now(), path: new URL(request.url()).pathname });
    });
    await page.goto(`${baseUrl}/ui#agent/${encodeURIComponent(agentKey)}`, { waitUntil: "load" });
    await page.waitForSelector("#prompt-input", { timeout: 15000 });
    await page.waitForFunction(() => !state.refreshInFlight && !state.activityInFlight);
    assert(requests.length > 0, `${label}: active startup loads data`);
    assert.equal((await facts(page)).active, true);
    evidence.push({ label, phase: "native active startup", requests: requests.length, ...await facts(page) });
    requests.length = 0;
    // Chrome's headless focus stays on the page. Model inactive startup at the
    // browser document boundary for repeatable hide and blur checks.
    await page.addInitScript(() => {
      document.hasFocus = () => false;
    });
    await page.reload({ waitUntil: "load" });
    await page.waitForFunction(() => typeof syncPollingWindow === "function");
    await sleep(500);
    assert.equal(requests.length, 0, `${label}: inactive startup network`);
    assert.equal((await facts(page)).refreshTimer, false);
    await page.evaluate(() => { delete document.hasFocus; window.dispatchEvent(new Event("focus")); });
    await page.waitForSelector("#prompt-input", { timeout: 15000 });
    await page.waitForFunction(() => !state.refreshInFlight && !state.activityInFlight);
    await page.locator("#prompt-input").fill("Keep this unsent draft after focus returns.");
    const hash = await page.evaluate(() => location.hash);
    const draft = await page.locator("#prompt-input").inputValue();
    // Deterministic visible blur also covers platforms that keep headless focus.
    await page.evaluate(() => { document.hasFocus = () => false; window.dispatchEvent(new Event("blur")); });
    const before = requests.length;
    await sleep(3600); // Longer than the fast activity interval.
    assert.equal(requests.length, before, `${label}: visible blurred requests`);
    assert.equal((await facts(page)).refreshTimer, false);
    assert.equal((await facts(page)).activityTimer, false);
    evidence.push({ label, phase: "visible blur", durationMs: 3600, newRequests: requests.length - before, ...await facts(page) });

    // Start both real requests, hold their responses, hide, and release.
    await page.evaluate(() => { delete document.hasFocus; window.dispatchEvent(new Event("focus")); });
    await page.waitForFunction(() => !state.refreshInFlight && !state.activityInFlight);
    let release;
    const barrier = new Promise(resolve => { release = resolve; });
    let held = 0;
    await page.route(/\/servers\/(resources|activity)$/, async route => {
      if (route.request().method() !== "GET") return route.continue();
      const response = await route.fetch();
      held++;
      await barrier;
      await route.fulfill({ response });
    });
    await page.evaluate(() => {
      clearTimeout(state.timer); clearTimeout(state.activityTimer);
      state.timer = state.activityTimer = null;
      state.pollDeferredUntil = 0; state.lastCatalogAt = 0;
      schedule(0); scheduleAgentActivity(0);
    });
    for (let tries = 0; held < 2 && tries < 100; tries++) await sleep(50);
    assert(held >= 2, `${label}: both requests held`);
    await page.evaluate(() => {
      Object.defineProperty(document, "hidden", { configurable: true, get: () => true });
      document.dispatchEvent(new Event("visibilitychange"));
    });
    const hiddenStart = requests.length;
    release();
    await page.waitForFunction(() => !state.refreshInFlight && !state.activityInFlight);
    await sleep(3600);
    assert.equal(requests.length, hiddenStart, `${label}: hidden continuation requests`);
    assert.equal((await facts(page)).refreshTimer, false);
    assert.equal((await facts(page)).activityTimer, false);
    evidence.push({ label, phase: "hidden after in-flight completion", durationMs: 3600, held, newRequests: requests.length - hiddenStart, ...await facts(page) });
    await page.unroute(/\/servers\/(resources|activity)$/);

    // Explicit refresh remains usable while inactive, including error recovery.
    await page.route("**/servers/resources", route => route.fulfill({ status: 503, contentType: "application/json", body: '{"error":"Synthetic recovery check"}' }));
    await page.evaluate(() => refresh({ force: true, preserveFocusedWorkspace: true }));
    assert.equal((await facts(page)).refreshTimer, false);
    await page.unroute("**/servers/resources");
    await page.evaluate(() => refresh({ force: true, preserveFocusedWorkspace: true }));
    assert.equal((await facts(page)).refreshTimer, false);
    assert.equal(await page.locator("#prompt-input").inputValue(), draft);
    const countsBeforeResume = requests.filter(item => /\/servers\/(resources|activity)$/.test(item.path)).length;
    await page.evaluate(() => {
      delete document.hidden; delete document.hasFocus;
      state.pollDeferredUntil = 0; state.lastCatalogAt = 0;
      // Keep focus restoration deterministic on mobile headless Chrome.
      document.hasFocus = () => true;
      for (let i = 0; i < 8; i++) {
        document.dispatchEvent(new Event("visibilitychange"));
        window.dispatchEvent(new Event("focus"));
      }
    });
    await page.waitForFunction(() => !state.refreshInFlight && !state.activityInFlight && state.timer !== null && state.activityTimer !== null);
    await sleep(400);
    const resumed = requests.filter(item => /\/servers\/(resources|activity)$/.test(item.path)).length - countsBeforeResume;
    assert.equal(resumed, 2, `${label}: repeated events start exactly one request per loop`);
    assert.equal(await page.evaluate(() => location.hash), hash);
    assert.equal(await page.locator("#prompt-input").inputValue(), draft);
    assert.equal(await page.evaluate(() => document.documentElement.scrollWidth > innerWidth), false);
    evidence.push({ label, phase: "repeat focus", events: 16, newCatalogAndActivityRequests: resumed, draftPreserved: true, routePreserved: true });
    if (captureDir) await page.screenshot({ path: path.join(captureDir, `active-window-${label}.png`) });
    await page.evaluate(() => navigate({ type: "agentForm", mode: "create", projectKey: "web" }));
    await page.waitForSelector("#agent-prompt");
    await page.locator(".agent-options > summary").click();
    await page.locator("#agent-name").fill("Unsent creation name");
    await page.locator("#agent-prompt").fill("Unsent creation prompt");
    const createHash = await page.evaluate(() => location.hash);
    await page.evaluate(() => {
      document.hasFocus = () => false; window.dispatchEvent(new Event("blur"));
      document.hasFocus = () => true; window.dispatchEvent(new Event("focus"));
    });
    // Form quiet time remains in force on focus return. Explicit refresh also
    // preserves the live creation fields through a real catalog fetch.
    await page.evaluate(() => refresh({ force: true }));
    assert.equal(await page.locator("#agent-name").inputValue(), "Unsent creation name");
    assert.equal(await page.locator("#agent-prompt").inputValue(), "Unsent creation prompt");
    assert.equal(await page.evaluate(() => location.hash), createHash);
    assert.equal(await page.locator(".agent-options").evaluate(element => element.open), true);
    evidence.push({ label, phase: "creation form", namePreserved: true, promptPreserved: true, routePreserved: true });
    assert.deepEqual(errors, []);
    await context.close();
  }
  console.log(JSON.stringify(evidence, null, 2));
  if (captureDir) fs.writeFileSync(path.join(captureDir, "active-window-evidence.json"), JSON.stringify(evidence, null, 2));
};
