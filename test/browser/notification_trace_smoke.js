const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");

// Runs with the normal notification fixture. No permission, subscription, or push.
module.exports = async function notificationTraceSmoke({ page, baseUrl, agentKey, captureDir }) {
  const record = "debug:trace-fixture";
  const notificationRoute = `/#notification/${encodeURIComponent(record)}`;
  await page.goto(`${baseUrl}/ui#settings`, { waitUntil: "networkidle" });
  assert(await page.evaluate(() => typeof globalThis.TychoNotificationTrace?.snapshot === "function"), "served page must expose persisted click diagnostics");
  await page.evaluate(async () => {
    await navigator.serviceWorker.register("/service-worker.js", { scope: "/" });
    await navigator.serviceWorker.ready;
  });
  const worker = page.context().serviceWorkers().find((item) => item.url().endsWith("/service-worker.js"));
  assert(worker, "actual Chrome service worker must run");
  const servedWorker = await (await page.request.get(`${baseUrl}/service-worker.js`)).text();
  await worker.evaluate((source) => {
    const original = self.addEventListener;
    self.addEventListener = (name, handler) => { if (name === "notificationclick") self.fixtureClick = handler; };
    try { (0, eval)(source); } finally { self.addEventListener = original; }
  }, servedWorker);
  // Capture and invoke the served production callback with actual Chrome WindowClients.
  // This lacks trusted OS activation. Focus may reject; navigation still runs.
  await worker.evaluate(async (url) => {
    let pending;
    self.fixtureClick({ notification: { data: { url }, close() {} }, waitUntil(value) { pending = value; } });
    await Promise.resolve(pending).catch(() => {});
  }, notificationRoute);
  await page.waitForURL(new RegExp(`#agent/${agentKey}$`));
  await page.evaluate(async (key) => { await ensureAgentDetail(key, true); }, agentKey);
  await page.locator("[data-agent-conversation-pane]").waitFor();
  await page.waitForFunction(async () => {
    const trace = await TychoNotificationTrace.snapshot();
    return trace.events.some((event) => event.name === "conversation.loaded") && trace.events.some((event) => event.name === "view.rendered" && event.view === "conversation");
  });
  if (captureDir) {
    fs.mkdirSync(captureDir, { recursive: true });
    for (const viewport of [{ width: 1440, height: 900 }, { width: 390, height: 844 }]) {
      await page.setViewportSize(viewport);
      await page.screenshot({ path: path.join(captureDir, `integrated-notification-conversation-${viewport.width}.png`) });
    }
  }
  let trace = await page.evaluate(() => TychoNotificationTrace.snapshot());
  if (captureDir) { fs.mkdirSync(captureDir, { recursive: true }); fs.writeFileSync(path.join(captureDir, "trace-probe.json"), JSON.stringify(trace, null, 2)); }
  assert.equal(trace.record_id, record);
  assert(trace.events.some((event) => event.name === "click.received" && event.build));
  assert(trace.events.some((event) => event.name === "client.selected" && event.same_origin === true));
  assert(trace.events.some((event) => event.name === "navigate.resolved"));
  assert(trace.events.some((event) => event.name === "notification.loaded" && event.target_state === "active"));
  assert(trace.events.some((event) => event.name === "request.completed" && event.request === "agent" && event.status === 200));
  assert(trace.events.some((event) => event.name === "conversation.loaded" && event.count > 0));
  assert(!JSON.stringify(trace).includes("Synthetic retained notification"));
  assert.equal(trace.coverage, "joined-click-and-page");
  // Persist through a real cold page load, not only a hash change.
  await page.reload({ waitUntil: "networkidle" });
  trace = await page.evaluate(() => TychoNotificationTrace.snapshot());
  assert(trace.events.some((event) => event.name === "click.received"));
  // Delayed and failed loads must leave status evidence without payload text.
  for (const status of [401, 503]) {
    await page.route(`**/agents/${agentKey}/conversation`, (route) => route.fulfill({ status, json: { error: "PRIVATE-CONVERSATION-TEXT" } }));
    await page.evaluate(async (key) => { delete state.conversations[key]; try { await ensureConversation(findAgent(key), true); } catch (_) {} }, agentKey);
    const failed = await page.evaluate(() => TychoNotificationTrace.snapshot());
    assert(failed.events.some((event) => event.name === "request.completed" && event.request === "conversation" && event.status === status));
    assert(failed.events.some((event) => event.name === "request.failed" && event.status === status));
    assert(!JSON.stringify(failed).includes("PRIVATE-CONVERSATION-TEXT"));
    await page.unroute(`**/agents/${agentKey}/conversation`);
  }
  let release;
  const gate = new Promise((resolve) => { release = resolve; });
  await page.route(`**/agents/${agentKey}/conversation`, async (route) => { await gate; await route.continue(); });
  await page.evaluate((key) => { delete state.conversations[key]; void ensureConversation(findAgent(key), true); }, agentKey);
  await page.locator(".conversation-loading-state").waitFor();
  assert(!await page.getByText("No conversation yet", { exact: true }).count());
  release();
  await page.waitForFunction((key) => !state.loadingConversations[key] && state.conversations[key]?.blocks.length > 0, agentKey);
  await page.unroute(`**/agents/${agentKey}/conversation`);
  await page.goto(`${baseUrl}/ui#settings`, { waitUntil: "networkidle" });
  const downloadPromise = page.waitForEvent("download");
  await page.locator("#notification-debugger > summary").click();
  await page.locator("[data-export-notification-trace]").click();
  const download = await downloadPromise;
  const exported = JSON.parse(fs.readFileSync(await download.path(), "utf8"));
  assert.equal(exported.click_trace.record_id, record, "export survives loss of in-memory preview");
  assert.equal(exported.click_trace.coverage, "joined-click-and-page");
  assert(!/endpoint|authorization|Synthetic retained notification/i.test(JSON.stringify(exported)));
  if (captureDir) {
    fs.mkdirSync(captureDir, { recursive: true });
    fs.writeFileSync(path.join(captureDir, "notification-click-trace.json"), JSON.stringify(exported, null, 2));
    for (const viewport of [{ width: 1440, height: 900 }, { width: 390, height: 844 }]) {
      await page.setViewportSize(viewport);
      await page.locator("[data-export-notification-trace]").scrollIntoViewIfNeeded();
      assert(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth));
      await page.screenshot({ path: path.join(captureDir, `notification-trace-${viewport.width}.png`) });
    }
  }
  await page.locator("[data-clear-notification-trace]").click();
  assert.equal((await page.evaluate(() => TychoNotificationTrace.snapshot())).events.length, 0);
  await page.evaluate(async () => {
    const trace = TychoNotificationTrace;
    await trace.begin("/#notification/ordinary");
    if ((await trace.snapshot()).events.length) throw new Error("ordinary records must not start tracing");
    await trace.begin("/#notification/debug%3Asafety");
    await trace.record("click.received", { body: "PRIVATE", endpoint: "https://push.example.test/PRIVATE", route: "https://other.test/#agent/PRIVATE" });
    for (let index = 0; index < 80; index += 1) await trace.record("view.rendered", { count: index, view: "conversation" });
    const bounded = await trace.snapshot();
    if (bounded.events.length !== 64 || bounded.events[0].name !== "click.received" || JSON.stringify(bounded).includes("PRIVATE")) throw new Error("trace bounds or redaction failed");
    await new Promise((resolve, reject) => {
      const open = indexedDB.open("tycho-notification-trace", 1);
      open.onerror = reject;
      open.onsuccess = () => {
        const db = open.result;
        const tx = db.transaction("trace", "readwrite");
        const store = tx.objectStore("trace");
        const get = store.get("current");
        get.onsuccess = () => store.put({ ...get.result, started_at: Date.now() - 25 * 60 * 60 * 1000 }, "current");
        tx.oncomplete = () => { db.close(); resolve(); };
        tx.onerror = reject;
      };
    });
    if ((await trace.snapshot()).events.length) throw new Error("expired trace was not deleted");
    const descriptor = Object.getOwnPropertyDescriptor(globalThis, "indexedDB");
    Object.defineProperty(globalThis, "indexedDB", { value: undefined, configurable: true });
    try {
      if ((await trace.snapshot()).storage !== "unavailable") throw new Error("storage failure must be explicit");
    } finally { if (descriptor) Object.defineProperty(globalThis, "indexedDB", descriptor); else delete globalThis.indexedDB; }
  });
  const brokenContext = await page.context().browser().newContext();
  const broken = await brokenContext.newPage();
  try {
    await broken.route("**/ui.js?*", (route) => route.fulfill({ contentType: "application/javascript", body: 'throw new Error("PRIVATE-BOOT-FAILURE")' }));
    await broken.goto(`${baseUrl}/ui#notification/debug%3Aboot-fixture`, { waitUntil: "networkidle" });
    await broken.waitForFunction(async () => (await TychoNotificationTrace.snapshot()).events.some((event) => event.name === "page.error"));
    const boot = await broken.evaluate(() => TychoNotificationTrace.snapshot());
    assert.equal(boot.coverage, "page-only");
    assert(!boot.events.some((event) => event.name === "app.started"));
    assert(!JSON.stringify(boot).includes("PRIVATE-BOOT-FAILURE"));
  } finally { await brokenContext.close(); }
  console.log("notification-trace-smoke: ok (synthetic callback, actual worker and page)");
};
