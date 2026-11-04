const fs = require("fs");
const path = require("path");
const { spawn } = require("child_process");
const assert = require("assert");

module.exports = async function attachmentLoadSmoke({ browser, baseUrl, agentKey, logsDir, ruby, captureDir }) {
  const results = [];
  const pending = [];
  async function holdLock() {
    const child = spawn(ruby, ["--disable-gems", "-e", 'File.open(ARGV[0], "a") { |f| f.flock(File::LOCK_EX); STDOUT.sync = true; puts "ready"; STDIN.gets }', path.join(logsDir, "managed_agents.json.lock")]);
    pending.push(child);
    await new Promise((resolve, reject) => { child.stdout.once("data", resolve); child.once("error", reject); child.once("exit", () => reject(new Error("lock holder exited"))); });
    return () => { if (!child.stdin.writableEnded) child.stdin.end("release\n"); };
  }
  try {
    for (const width of [1440, 390]) for (const theme of ["dark", "light"]) {
      const page = await browser.newPage({ viewport: { width, height: 900 } });
      const errors = [];
      page.on("pageerror", (error) => errors.push(error.message));
      // A stalled optional dependency must not prevent safe source text from showing.
      await page.route(/cdn\.jsdelivr\.net\/.*(marked|purify)/, () => {});
      await page.addInitScript((appearance) => {
        localStorage.setItem("hq.remote.appearance", appearance);
        window.attachmentLongTasks = [];
        new PerformanceObserver((list) => window.attachmentLongTasks.push(...list.getEntries().map(({ startTime, duration }) => ({ startTime, duration })))).observe({ type: "longtask", buffered: true });
      }, theme);
      const detail = (await (await page.request.get(`${baseUrl}/agents/${agentKey}`)).json()).agent;
      const attachment = detail.attachments.find((item) => item.title === "Release review");
      await page.goto(`${baseUrl}/ui#agent/${agentKey}/summary/preview-current`, { waitUntil: "domcontentloaded" });
      const button = page.locator(`.agent-detail-pane [data-preview-summary-attachment="${attachment.id}"]`).first();
      await button.waitFor();
      for (let sample = 0; sample < 5; sample += 1) {
        const release = await holdLock();
        const timer = setTimeout(release, 1200);
        const started = performance.now();
        try {
          const responsePromise = page.waitForResponse((response) => response.url() === `${baseUrl}/attachments/${attachment.id}`);
          const contentReady = (async () => {
            const response = await responsePromise;
            const body = await response.body();
            await page.waitForFunction(() => Array.from(document.querySelectorAll(".markdown-viewer, .attachment-text-viewer")).some((node) => node.textContent.includes("The release is ready for operator review.")));
            return { response, body, elapsed: performance.now() - started };
          })();
          await button.click();
          if (sample === 0 && captureDir) {
            await page.waitForTimeout(300);
            await page.screenshot({ path: path.join(captureDir, `load-${width}-${theme}-during-lock.png`) });
          }
          const { response, body, elapsed } = await contentReady;
          const timing = await page.evaluate((url) => {
            const entry = performance.getEntriesByName(url).at(-1);
            return entry?.toJSON();
          }, response.url());
          results.push({ width, theme, sample, hold_ms: 1200, visible_ms: elapsed, bytes: body.length, server_timing: response.headers()["server-timing"], resource: timing, long_tasks: await page.evaluate(() => window.attachmentLongTasks) });
          assert.strictEqual(response.status(), 200);
          assert.strictEqual(await page.locator(".summary-attachment-preview-pane script").count(), 0);
          assert(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth), "horizontal overflow");
          await page.goto(`${baseUrl}/ui#agent/${agentKey}/summary/preview-current`, { waitUntil: "domcontentloaded" });
          await page.reload({ waitUntil: "domcontentloaded" });
          await button.waitFor();
        } finally { clearTimeout(timer); release(); }
      }
      assert.deepStrictEqual(errors, []);
      await page.close();
    }
  } finally {
    pending.forEach((child) => child.stdin.end());
    if (captureDir) fs.writeFileSync(path.join(captureDir, "browser-timing.json"), JSON.stringify(results, null, 2));
    console.log(JSON.stringify(results.map(({ resource, ...rest }) => rest)));
  }
  assert(results.every((sample) => sample.visible_ms < 1000), "attachment content waited for the 1200ms lifecycle lock");
  // Route a synthetic peer to this same isolated service. This tests client destination handling,
  // not a physical peer network. No configured peer or private attachment is used.
  for (const width of [1440, 390]) for (const theme of ["dark", "light"]) {
    const page = await browser.newPage({ viewport: { width, height: 900 } });
    await page.addInitScript((appearance) => localStorage.setItem("hq.remote.appearance", appearance), theme);
    await page.route("**/*", async (route) => {
      const url = new URL(route.request().url());
      if (url.hostname === "cdn.jsdelivr.net") return route.abort();
      if (url.pathname === "/servers/resources") {
        const response = await route.fetch();
        const data = await response.json();
        const local = data.servers.find((server) => server.local);
        data.servers.push({ ...local, key: "fixture-peer", name: "Synthetic peer", local: false, url: baseUrl });
        return route.fulfill({ response, json: data });
      }
      if (url.pathname.startsWith("/servers/fixture-peer/")) {
        return route.fulfill({ response: await route.fetch({ url: `${baseUrl}${url.pathname.replace("/servers/fixture-peer", "")}${url.search}` }) });
      }
      return route.continue();
    });
    const detail = (await (await page.request.get(`${baseUrl}/agents/${agentKey}`)).json()).agent;
    const text = detail.attachments.find((item) => item.title === "Notes");
    const image = detail.attachments.find((item) => item.title === "Diagram");
    const binary = detail.attachments.find((item) => item.title === "Download package");
    const original = fs.readFileSync(text.path);
    try {
      const release = await holdLock();
      const timer = setTimeout(release, 1200);
      const started = performance.now();
      const responses = await Promise.all([text, image, binary].map((item) => page.request.get(`${baseUrl}/attachments/${item.id}/blob`)));
      assert(performance.now() - started < 1000, "concurrent downloads waited for lifecycle lock");
      clearTimeout(timer); release();
      for (let index = 0; index < responses.length; index += 1) {
        assert.strictEqual(responses[index].status(), 200);
        assert.deepStrictEqual(await responses[index].body(), fs.readFileSync([text, image, binary][index].path));
      }
      const url = `${baseUrl}/ui#agent/${encodeURIComponent(`fixture-peer/${agentKey}`)}/attachment/${encodeURIComponent(`fixture-peer/${text.id}`)}`;
      await page.goto(url, { waitUntil: "domcontentloaded" });
      await page.locator(".agent-attachment-viewer").getByText("Plain text preview", { exact: false }).waitFor();
      fs.writeFileSync(text.path, "Changed file after first read.");
      await page.evaluate(async () => refresh({ force: true, forceAttachment: true }));
      await page.locator(".agent-attachment-viewer").getByText("Changed file after first read.", { exact: false }).waitFor();
      const pattern = `**/servers/fixture-peer/attachments/${text.id}`;
      await page.route(pattern, (route) => route.fulfill({ status: 401, json: { error: "Unauthorized" } }));
      await page.evaluate(async () => refresh({ force: true, forceAttachment: true }));
      assert(await page.locator("#auth-panel").isVisible(), "auth failure did not show the token form");
      await page.unroute(pattern);
      await page.evaluate(async () => refresh({ force: true, forceAttachment: true }));
      await page.locator(".agent-attachment-viewer").getByText("Changed file after first read.", { exact: false }).waitFor();
      assert(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth));
    } finally { fs.writeFileSync(text.path, original); await page.close(); }
  }
  console.log("Concurrent text/image/binary bytes, file freshness, synthetic peer, auth error and retry: passed");
};
