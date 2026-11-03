const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");

module.exports = async ({ browser, baseUrl, captureDir }) => {
  const results = [];
  const barrier = () => { let release; const promise = new Promise(resolve => { release = resolve; }); return { promise, release }; };
  for (const width of [1440, 390]) for (const theme of ["dark", "light"]) {
    const context = await browser.newContext({ viewport: { width, height: 900 }, isMobile: width < 500, hasTouch: width < 500 });
    const page = await context.newPage();
    const releases = [];
    const errors = [];
    page.on("pageerror", error => errors.push(error.message));
    await page.addInitScript(() => { document.hasFocus = () => true; });
    page.setDefaultTimeout(10000);
    const waitSeen = seen => Promise.race([seen.promise, page.waitForTimeout(10000).then(() => { throw Error("Ordering request did not arrive"); })]);
    const open = async hash => {
      await page.goto(`${baseUrl}/ui${hash}`, { waitUntil: "networkidle" });
      await page.waitForFunction(() => !state.refreshInFlight);
      await page.evaluate(() => clearTimeout(state.timer));
    };
    try {
      await open("#settings");
      await page.locator("[data-appearance-preference]").selectOption(theme);
      for (const change of ["newer", "deleted"]) {
        const key = `ordering-${width}-${theme}-${change}`;
        const endpoint = `${baseUrl}/schedules/${key}`;
        assert.equal((await page.request.post(`${baseUrl}/schedules`, { data: { key, name: "Initial schedule", cron: "0 9 * * *", project_key: "web", message: "Synthetic ordering test" } })).status(), 201);
        await page.evaluate(() => refresh({ force: true }));
        await open(`#schedule/${key}/edit`);
        await page.locator("#schedule-name").fill("Old accepted write");
        const held = barrier(), seen = barrier();
        releases.push(held.release);
        let writes = 0;
        const holdWrite = async route => {
          if (route.request().method() !== "PATCH") return route.continue();
          writes++;
          const response = await route.fetch();
          seen.release();
          await held.promise;
          return route.fulfill({ response });
        };
        await page.route(endpoint, holdWrite);
        await page.locator("#schedule-form button[type=submit]").click();
        await waitSeen(seen);
        if (change === "newer") assert.equal((await page.request.patch(endpoint, { data: { name: "Newer server value" } })).status(), 200);
        else assert.equal((await page.request.delete(endpoint)).status(), 200);
        await page.evaluate(() => refresh({ force: true }));
        const observed = await page.evaluate(key => ({ schedule: findSchedule(key) || null, hash: location.hash, pending: state.pendingFormKeys.size }), key);
        assert.equal(observed.hash, `#schedule/${key}/edit`);
        assert.equal(observed.pending, 1);
        assert.equal(observed.schedule?.name || null, change === "newer" ? "Newer server value" : null);
        const counts = { catalog: 0, setup: 0, schedules: 0 };
        const count = request => {
          const pathname = new URL(request.url()).pathname;
          if (pathname === "/servers/resources") counts.catalog++;
          if (/^\/setup(?:\/summary)?$/.test(pathname)) counts.setup++;
          if (pathname === "/schedules" && request.method() === "GET") counts.schedules++;
        };
        const failRead = route => route.fulfill({ status: 503, json: { error: "Controlled reconciliation failure" } });
        await page.route(`${baseUrl}/schedules`, failRead);
        page.on("request", count);
        held.release();
        await page.waitForFunction(() => state.pendingFormKeys.size === 0 && !state.refreshInFlight);
        await page.waitForTimeout(80);
        page.off("request", count);
        assert.equal(writes, 1);
        assert.deepEqual(counts, { catalog: 1, setup: 1, schedules: 1 });
        const after = await page.evaluate(key => ({ schedule: findSchedule(key) || null, hash: location.hash, connection: state.failureCount }), key);
        assert.equal(after.schedule?.name || null, change === "newer" ? "Newer server value" : null);
        assert.equal(after.hash, `#schedule/${key}/edit`);
        assert(after.connection > 0, "reconciliation error remains visible");
        await page.unroute(`${baseUrl}/schedules`, failRead);
        if (change === "newer") {
          assert.equal(await page.locator("#schedule-name").inputValue(), "Old accepted write");
          assert.equal(await page.locator("#schedule-name").isEnabled(), true);
          await page.reload({ waitUntil: "networkidle" });
          assert.equal(await page.locator("#schedule-name").inputValue(), "Old accepted write");
          assert.equal(await page.evaluate(key => findSchedule(key).name, key), "Newer server value");
          await page.evaluate(() => clearFormDraft(document.querySelector("#schedule-form")));
        }
        await page.unroute(endpoint, holdWrite);
        results.push({ width, theme, case: `same-route-${change}`, writes, reconciliationCounts: counts, preservedName: after.schedule?.name || null, draftRetained: change === "newer" });
        if (change === "newer") assert.equal((await page.request.delete(endpoint)).status(), 200);
      }

      for (const reader of ["direct", "refresh"]) for (const oldStatus of [200, 503, 401]) {
        const endpoint = `${baseUrl}/schedules/file-message/message`;
        assert.equal((await page.request.patch(endpoint, { data: { content: "Old read body" } })).status(), 200);
        await open("#now");
        await page.evaluate(() => { delete state.scheduleMessages["file-message"]; });
        await open("#schedule/file-message/message");
        const saved = `Accepted ${reader} ${oldStatus} ${width} ${theme}\nSecond line.\n`;
        await page.locator("#schedule-message-content").fill(saved);
        await page.locator("#schedule-message-content").blur();
        const held = barrier(), seen = barrier();
        releases.push(held.release);
        let writes = 0;
        const holdRead = async route => {
          if (route.request().method() !== "GET") { writes++; return route.continue(); }
          const response = await route.fetch();
          seen.release();
          await held.promise;
          return oldStatus === 200 ? route.fulfill({ response }) : route.fulfill({ status: oldStatus, json: { error: "Old read error" } });
        };
        await page.route(endpoint, holdRead);
        await page.evaluate(reader => { window.orderingOldRead = reader === "direct" ? ensureScheduleMessage("file-message", true) : refresh({ force: true }); }, reader);
        await waitSeen(seen);
        const counts = { catalog: 0, setup: 0, schedules: 0 };
        const count = request => {
          const pathname = new URL(request.url()).pathname;
          if (pathname === "/servers/resources") counts.catalog++;
          if (/^\/setup(?:\/summary)?$/.test(pathname)) counts.setup++;
          if (pathname === "/schedules" && request.method() === "GET") counts.schedules++;
        };
        page.on("request", count);
        await page.locator("#schedule-message-form button[type=submit]").click();
        await page.waitForFunction(() => location.hash === "#now" && state.pendingFormKeys.size === 0 && !state.refreshInFlight);
        page.off("request", count);
        assert.equal(writes, 1);
        assert.deepEqual(counts, { catalog: 1, setup: 1, schedules: 1 });
        assert.equal(await page.evaluate(() => state.scheduleMessages["file-message"].content), saved);
        held.release();
        await page.evaluate(() => window.orderingOldRead);
        assert.equal(await page.evaluate(() => state.scheduleMessages["file-message"].content), saved);
        assert.equal(await page.evaluate(() => state.scheduleMessages["file-message"].error || null), null);
        await page.unroute(endpoint, holdRead);
        await open("#schedule/file-message/message");
        assert.equal(await page.locator("#schedule-message-content").inputValue(), saved);
        assert.equal((await (await page.request.get(endpoint)).json()).message.content, saved);
        await page.reload({ waitUntil: "networkidle" });
        assert.equal(await page.locator("#schedule-message-content").inputValue(), saved);
        results.push({ width, theme, case: `old-${reader}-read-${oldStatus}`, writes, reconciliationCounts: counts, savedBodyPreserved: true, backAndReload: true });
      }
      assert.deepEqual(errors, []);
    } finally {
      releases.forEach(release => release());
      await context.close();
    }
  }
  if (captureDir) {
    fs.mkdirSync(captureDir, { recursive: true });
    fs.writeFileSync(path.join(captureDir, "schedule-ordering-results.json"), JSON.stringify(results, null, 2));
  }
  console.log("schedule_ordering_smoke: ok (32 held-response cases; same-route change/deletion; old read success/error; direct/forced refresh; desktop/mobile Dark/Nord Light)");
};
