const assert = require("node:assert/strict");

const WINDOW_MS = Number(process.env.TYCHO_REMOTE_UI_POLL_WINDOW_MS || 30000);
const MAX_PER_MINUTE = Number(process.env.TYCHO_REMOTE_UI_POLL_MAX_PER_MINUTE || 0);

const endpoint = (url) => new URL(url).pathname.replace(/\/agents\/[^/]+/, "/agents/:key");

module.exports = async ({ browser, baseUrl, agentKey }) => {
  const context = await browser.newContext({ viewport: { width: 1280, height: 900 } });
  const page = await context.newPage();
  const errors = [];
  page.on("pageerror", (error) => errors.push(error.message));
  await page.goto(`${baseUrl}/ui#agent/${encodeURIComponent(agentKey)}`, { waitUntil: "networkidle" });
  await page.waitForSelector("[data-agent-live-status], .conversation, [data-conversation]", { timeout: 10000 }).catch(() => {});

  const counts = {};
  const inFlight = {};
  let overlaps = 0;
  const key = (request) => `${request.method()} ${endpoint(request.url())}`;
  page.on("request", (request) => {
    const name = key(request);
    counts[name] = (counts[name] || 0) + 1;
    inFlight[name] = (inFlight[name] || 0) + 1;
    if (inFlight[name] > 1) overlaps += 1;
  });
  const done = (request) => { const name = key(request); inFlight[name] = Math.max(0, (inFlight[name] || 1) - 1); };
  page.on("requestfinished", done);
  page.on("requestfailed", done);

  await page.waitForTimeout(WINDOW_MS);
  const total = Object.values(counts).reduce((sum, count) => sum + count, 0);
  const perMinute = Math.round((total * 60000) / WINDOW_MS);
  console.log(JSON.stringify({ windowMs: WINDOW_MS, total, perMinute, overlaps, counts }, null, 2));
  assert.deepEqual(errors, []);
  assert.equal(overlaps, 0, "same endpoint polled while a request was in flight");
  if (MAX_PER_MINUTE) assert(perMinute <= MAX_PER_MINUTE, `${perMinute} requests/min exceeds ${MAX_PER_MINUTE}`);
  assert(!Object.keys(counts).some((name) => name.endsWith("/conversation")), "full conversation snapshot refetched while revision unchanged");
  await context.close();
};
