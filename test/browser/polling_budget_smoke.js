const assert = require("node:assert/strict");

// Budgets are the measured request rate plus a margin. Override with env vars
// only when measuring a new baseline.
const IDLE_WINDOW_MS = Number(process.env.TYCHO_REMOTE_UI_POLL_WINDOW_MS || 60000);
const IDLE_MAX_PER_MINUTE = Number(process.env.TYCHO_REMOTE_UI_POLL_IDLE_MAX_PER_MINUTE || 24);
const RUNNING_WINDOW_MS = 24000;
const RUNNING_MAX_PER_MINUTE = Number(process.env.TYCHO_REMOTE_UI_POLL_RUNNING_MAX_PER_MINUTE || 70);
const MESSAGE_VISIBLE_MS = 16000;
const HIDDEN_WINDOW_MS = 20000;

const endpoint = (url) => {
  const parsed = new URL(url);
  return `${parsed.pathname.replace(/\/agents\/[^/]+/, "/agents/:key")}`;
};
const isPoll = (request) => ["fetch", "xhr"].includes(request.resourceType());

async function post(baseUrl, path, body) {
  const response = await fetch(`${baseUrl}${path}`, {
    method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(body),
  });
  assert(response.ok, `${path}: ${response.status}`);
  return response.json();
}

function counter(page) {
  const counts = {};
  const inFlight = {};
  const state = { overlaps: 0, snapshots: 0 };
  const name = (request) => `${request.method()} ${endpoint(request.url())}`;
  page.on("request", (request) => {
    if (!isPoll(request)) return;
    const key = name(request);
    counts[key] = (counts[key] || 0) + 1;
    inFlight[key] = (inFlight[key] || 0) + 1;
    if (inFlight[key] > 1) state.overlaps += 1;
    if (/\/conversation$/.test(new URL(request.url()).pathname)) state.snapshots += 1;
  });
  const done = (request) => { if (isPoll(request)) { const key = name(request); inFlight[key] = Math.max(0, (inFlight[key] || 1) - 1); } };
  page.on("requestfinished", done);
  page.on("requestfailed", done);
  return { counts, state, total: () => Object.values(counts).reduce((sum, count) => sum + count, 0) };
}

async function measure(page, windowMs, label, maxPerMinute) {
  const poll = counter(page);
  await page.waitForTimeout(windowMs);
  const perMinute = Math.round((poll.total() * 60000) / windowMs);
  console.log(JSON.stringify({ label, windowMs, total: poll.total(), perMinute, overlaps: poll.state.overlaps, counts: poll.counts }, null, 2));
  assert.equal(poll.state.overlaps, 0, `${label}: same endpoint polled while a request was in flight`);
  assert.equal(poll.state.snapshots, 0, `${label}: full conversation snapshot refetched while revision unchanged`);
  assert(perMinute <= maxPerMinute, `${label}: ${perMinute} requests/min exceeds budget ${maxPerMinute}`);
}

module.exports = async ({ browser, baseUrl, agentKey }) => {
  const context = await browser.newContext({ viewport: { width: 1280, height: 900 } });
  const page = await context.newPage();
  const errors = [];
  page.on("pageerror", (error) => errors.push(error.message));
  await page.goto(`${baseUrl}/ui#agent/${encodeURIComponent(agentKey)}`, { waitUntil: "networkidle" });
  await page.waitForSelector("#prompt-input", { timeout: 15000 });

  // Idle conversation: no run, nothing changes.
  await measure(page, IDLE_WINDOW_MS, "idle conversation", IDLE_MAX_PER_MINUTE);

  // A run started by another client must show its reply promptly, even though the idle page reuses the catalog.
  // The page stages new blocks behind a "Load N new messages" control, so that control is the prompt signal.
  assert.equal(await page.locator("[data-load-pending-conversation]").count(), 0, "pending messages before the run started");
  await post(baseUrl, `/agents/${encodeURIComponent(agentKey)}/messages`, { prompt: "Review the workspace.", start: true });
  await page.waitForSelector("[data-load-pending-conversation]", { timeout: MESSAGE_VISIBLE_MS });

  // Hidden tab: polling backs off. Refresh skips while hidden and activity uses the hidden interval.
  await page.evaluate(() => {
    Object.defineProperty(document, "hidden", { configurable: true, get: () => true });
    document.dispatchEvent(new Event("visibilitychange"));
  });
  await page.waitForTimeout(6000);
  const hiddenPoll = counter(page);
  await page.waitForTimeout(HIDDEN_WINDOW_MS);
  console.log(JSON.stringify({ label: "hidden tab", windowMs: HIDDEN_WINDOW_MS, total: hiddenPoll.total(), counts: hiddenPoll.counts }));
  assert(hiddenPoll.total() <= 1, `hidden tab made ${hiddenPoll.total()} requests in ${HIDDEN_WINDOW_MS} ms`);
  await page.evaluate(() => {
    delete document.hidden;
    document.dispatchEvent(new Event("visibilitychange"));
  });

  // Running agent: keep the fast cadence and still stay inside the budget.
  const running = post(baseUrl, `/agents/${encodeURIComponent(agentKey)}/messages`, { prompt: "QUEUE_SMOKE_HOLD polling budget", start: true });
  await running;
  await page.waitForTimeout(1500);
  await measure(page, RUNNING_WINDOW_MS, "running agent", RUNNING_MAX_PER_MINUTE);
  assert.deepEqual(errors, []);
  await context.close();
};
