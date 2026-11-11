const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");

module.exports = async ({ browser, baseUrl, captureDir }) => {
  const results = [];
  const barrier = () => { let release; const promise = new Promise(resolve => { release = resolve; }); return { promise, release }; };
  for (const width of [1440, 390]) for (const theme of ["dark", "light"]) {
    const context = await browser.newContext({ viewport: { width, height: 900 }, isMobile: width < 500, hasTouch: width < 500 });
    const page = await context.newPage();
    const releases = [], errors = [];
    const endpoint = `${baseUrl}/schedules/file-message/message`;
    page.on("pageerror", error => errors.push(error.message));
    await page.addInitScript(() => { document.hasFocus = () => true; });
    page.setDefaultTimeout(10000);
    const gate = () => { const held = barrier(); releases.push(held.release); return held; };
    const wait = seen => Promise.race([seen.promise, page.waitForTimeout(10000).then(() => { throw Error("Expected message ordering request was not sent"); })]);
    const open = async hash => {
      await page.goto(`${baseUrl}/ui${hash}`, { waitUntil: "networkidle" });
      await page.waitForFunction(() => !state.refreshInFlight);
      await page.evaluate(() => clearTimeout(state.timer));
    };
    const prepare = async () => {
      assert.equal((await page.request.patch(endpoint, { data: { content: "Initial body" } })).status(), 200);
      await open("#schedules");
      await page.evaluate(() => { delete state.scheduleMessages["file-message"]; });
      await open("#schedule/file-message/message");
      await page.locator("#schedule-message-form").waitFor();
      await page.evaluate(() => clearFormDraft(document.querySelector("#schedule-message-form")));
      await page.locator("#schedule-message-content").fill("Submitted body");
      await page.locator("#schedule-message-content").blur();
    };
    const draft = () => page.evaluate(() => {
      const key = formDraftStorageKey(document.querySelector("#schedule-message-form"));
      return { key, value: safeLocalStorageGet(key) };
    });
    const order = () => page.evaluate(() => JSON.stringify(scheduleMessageOrder("file-message")));
    const cache = () => page.evaluate(() => state.scheduleMessages["file-message"]);
    const settleSave = () => page.waitForFunction(() => state.pendingFormKeys.size === 0 && !state.refreshInFlight);
    const countReads = () => {
      const counts = { catalog: 0, setup: 0, schedules: 0 };
      const listener = request => {
        const pathname = new URL(request.url()).pathname;
        if (pathname === "/servers/resources") counts.catalog++;
        if (/^\/setup(?:\/summary)?$/.test(pathname)) counts.setup++;
        if (pathname === "/schedules" && request.method() === "GET") counts.schedules++;
      };
      page.on("request", listener);
      return { counts, stop: () => page.off("request", listener) };
    };
    const keepDraft = async expected => assert.equal(await page.evaluate(key => safeLocalStorageGet(key), expected.key), expected.value);
    const checkCanonical = async expectedDraft => {
      await keepDraft(expectedDraft);
      await page.evaluate(key => safeLocalStorageRemove(key), expectedDraft.key);
      await page.evaluate(() => ensureScheduleMessage("file-message", true));
      await open("#schedules");
      await open("#schedule/file-message/message");
      const server = (await (await page.request.get(endpoint)).json()).message.content;
      assert.equal(await page.locator("#schedule-message-content").inputValue(), server);
      await page.reload({ waitUntil: "networkidle" });
      assert.equal(await page.locator("#schedule-message-content").inputValue(), server);
    };
    const completeRead = (route, response, status) => status === 200 ? route.fulfill({ response }) : status === "invalid" ? route.fulfill({ json: { message: {} } }) : route.fulfill({ status, json: { error: `Controlled current reader ${status}` } });
    try {
      await open("#settings");
      await page.locator("[data-appearance-preference]").selectOption(theme);
      // A body observation, unlike a loading/error state, supersedes a write's
      // dispatch snapshot. Both reconciliation outcomes retain the user draft.
      for (const reconciliation of [200, 503]) {
        await prepare();
        const savedDraft = await draft(), held = gate(), seen = gate();
        let writes = 0;
        const holdWrite = async route => {
          if (route.request().method() !== "PATCH") return route.continue();
          writes++;
          const response = await route.fetch(); seen.release(); await held.promise;
          return route.fulfill({ response });
        };
        await page.route(endpoint, holdWrite);
        await page.locator("#schedule-message-form button[type=submit]").click();
        await wait(seen);
        assert.equal((await page.request.patch(endpoint, { data: { content: "Newer observed body" } })).status(), 200);
        await page.evaluate(() => refresh({ force: true }));
        assert.equal((await cache()).content, "Newer observed body");
        const fail = route => route.fulfill({ status: 503, json: { error: "Controlled reconciliation failure" } });
        if (reconciliation === 503) await page.route(`${baseUrl}/schedules`, fail);
        const reads = countReads(); held.release(); await settleSave(); await page.waitForTimeout(80); reads.stop();
        assert.equal(writes, 1); assert.deepEqual(reads.counts, { catalog: 1, setup: 1, schedules: 1 });
        assert.equal(new URL(page.url()).hash, "#schedule/file-message/message");
        assert.equal((await cache()).content, "Newer observed body");
        assert.equal(await page.locator("#schedule-message-content").inputValue(), "Submitted body");
        await keepDraft(savedDraft);
        if (reconciliation === 503) await page.unroute(`${baseUrl}/schedules`, fail);
        await page.unroute(endpoint, holdWrite);
        await checkCanonical(savedDraft);
        results.push({ width, theme, case: "newer-body-before-write-reply", reconciliation, writes, reconciliationCounts: reads.counts, draftAndBodyRetained: true });
      }
      // A stale save may validate its reply, but cannot change either the cache
      // or the generation of a reader that started after its dispatch.
      for (const stale of ["navigation", "draft"]) for (const reader of ["direct", "refresh"]) for (const status of [200, 503, 401, "invalid"]) {
        await prepare();
        const writeHeld = gate(), writeSeen = gate(), readHeld = gate(), readSeen = gate();
        let writes = 0;
        const hold = async route => {
          const response = await route.fetch();
          if (route.request().method() === "PATCH") { writes++; writeSeen.release(); await writeHeld.promise; return route.fulfill({ response }); }
          readSeen.release(); await readHeld.promise; return completeRead(route, response, status);
        };
        await page.route(endpoint, hold);
        await page.locator("#schedule-message-form button[type=submit]").click(); await wait(writeSeen);
        if (stale === "navigation") {
          await page.evaluate(() => navigate({ type: "tab", tab: "schedules" }));
          await page.waitForFunction(() => location.hash === "#schedules");
          await page.evaluate(() => navigate({ type: "scheduleMessage", key: "file-message" }));
          await page.locator("#schedule-message-form").waitFor();
        } else {
          // Inject a restored newer draft while the original form is pending.
          await page.locator("#schedule-message-content").evaluate(input => { input.disabled = false; });
          await page.locator("#schedule-message-content").fill("Newer stored draft");
          await page.locator("#schedule-message-content").blur();
        }
        const savedDraft = await draft();
        assert.equal((await page.request.patch(endpoint, { data: { content: "Current reader body" } })).status(), 200);
        await page.evaluate(reader => { clearTimeout(state.timer); window.messageReader = reader === "direct" ? ensureScheduleMessage("file-message", true) : refresh({ force: true }); }, reader);
        await wait(readSeen);
        const before = await order(), pendingCache = await cache(), reads = countReads();
        writeHeld.release(); await page.waitForFunction(() => state.pendingFormKeys.size === 0); await page.waitForTimeout(80); reads.stop();
        assert.equal(await order(), before, "stale save has no ordering side effects");
        assert.deepEqual(await cache(), pendingCache, "stale save leaves the current reader pending");
        assert.deepEqual(reads.counts, { catalog: 0, setup: 0, schedules: 0 }, "stale save adds no second route reconciliation");
        readHeld.release(); await page.evaluate(() => window.messageReader);
        assert(!(await cache()).loading, "a completed current reader cannot leave a loading residue");
        if (status === 200) assert.equal((await cache()).content, "Current reader body");
        else assert((await cache()).error.includes(String(status)));
        await keepDraft(savedDraft); assert.equal(writes, 1);
        await page.unroute(endpoint, hold);
        await checkCanonical(savedDraft);
        results.push({ width, theme, case: "stale-save-keeps-new-reader", stale, reader, status, writes, saveSideEffects: false, completedReaderNotLoading: true });
      }
      // Readers that begin after dispatch but before the write commits are
      // earlier than an eligible accepted update, even if they finish last.
      for (const reader of ["direct", "refresh"]) for (const status of [200, 503, 401]) {
        await prepare();
        const commit = gate(), writeSeen = gate(), readHeld = gate(), readSeen = gate();
        let writes = 0;
        const hold = async route => {
          if (route.request().method() === "PATCH") { writes++; writeSeen.release(); await commit.promise; return route.continue(); }
          const response = await route.fetch(); readSeen.release(); await readHeld.promise; return completeRead(route, response, status);
        };
        await page.route(endpoint, hold);
        await page.locator("#schedule-message-form button[type=submit]").click(); await wait(writeSeen);
        await page.evaluate(reader => { window.messageReader = reader === "direct" ? ensureScheduleMessage("file-message", true) : refresh({ force: true }); }, reader);
        await wait(readSeen);
        const reads = countReads(); commit.release(); await settleSave(); reads.stop();
        assert.equal((await cache()).content, "Submitted body");
        assert.deepEqual(reads.counts, { catalog: 1, setup: 1, schedules: 1 });
        readHeld.release(); await page.evaluate(() => window.messageReader);
        assert.equal((await cache()).content, "Submitted body"); assert(!(await cache()).loading); assert(!(await cache()).error);
        assert.equal(writes, 1); await page.unroute(endpoint, hold);
        await open("#schedule/file-message/message");
        assert.equal(await page.locator("#schedule-message-content").inputValue(), "Submitted body");
        await page.reload({ waitUntil: "networkidle" }); assert.equal(await page.locator("#schedule-message-content").inputValue(), "Submitted body");
        results.push({ width, theme, case: "reader-after-dispatch-before-commit", reader, status, writes, reconciliationCounts: reads.counts, acceptedBodyRetained: true });
      }
      // Invalid/failed writes also leave an already pending newer reader alone.
      for (const writeStatus of [400, "invalid"]) for (const readStatus of [200, 503]) {
        await prepare();
        const writeHeld = gate(), writeSeen = gate(), readHeld = gate(), readSeen = gate();
        let writes = 0;
        const hold = async route => {
          if (route.request().method() === "PATCH") {
            writes++; writeSeen.release(); await writeHeld.promise;
            return route.fulfill({ status: writeStatus === "invalid" ? 200 : writeStatus, json: writeStatus === "invalid" ? {} : { error: "Controlled write failure" } });
          }
          const response = await route.fetch(); readSeen.release(); await readHeld.promise; return completeRead(route, response, readStatus);
        };
        await page.route(endpoint, hold);
        await page.locator("#schedule-message-form button[type=submit]").click(); await wait(writeSeen);
        const savedDraft = await draft();
        await page.evaluate(() => { window.messageReader = refresh({ force: true }); }); await wait(readSeen);
        const before = await order(); writeHeld.release(); await page.waitForFunction(() => state.pendingFormKeys.size === 0);
        assert.equal(await order(), before);
        readHeld.release(); await page.evaluate(() => window.messageReader);
        assert(!(await cache()).loading); await keepDraft(savedDraft); assert.equal(writes, 1);
        await page.unroute(endpoint, hold); await checkCanonical(savedDraft);
        results.push({ width, theme, case: "failed-write-keeps-reader", writeStatus, readStatus, writes, completedReaderNotLoading: true });
      }
      // A reader started after acceptance has current authority. An older
      // reader completing while it waits cannot cancel it or restore old data.
      for (const status of [200, 503, 401]) {
        await prepare();
        const oldHeld = gate(), oldSeen = gate(), currentHeld = gate(), currentSeen = gate();
        let getCount = 0, writes = 0;
        const hold = async route => {
          if (route.request().method() === "PATCH") { writes++; return route.continue(); }
          const response = await route.fetch();
          if (++getCount === 1) { oldSeen.release(); await oldHeld.promise; }
          else { currentSeen.release(); await currentHeld.promise; }
          return completeRead(route, response, status);
        };
        await page.route(endpoint, hold);
        await page.evaluate(() => { window.oldMessageReader = ensureScheduleMessage("file-message", true); }); await wait(oldSeen);
        const reads = countReads();
        await page.locator("#schedule-message-form button[type=submit]").click(); await settleSave(); reads.stop();
        assert.equal((await cache()).content, "Submitted body");
        assert.deepEqual(reads.counts, { catalog: 1, setup: 1, schedules: 1 });
        assert.equal((await page.request.patch(endpoint, { data: { content: "Body after acceptance" } })).status(), 200);
        await page.evaluate(() => { window.messageReader = ensureScheduleMessage("file-message", true); }); await wait(currentSeen);
        const before = await order(), pendingCache = await cache();
        oldHeld.release(); await page.evaluate(() => window.oldMessageReader);
        assert.equal(await order(), before); assert.deepEqual(await cache(), pendingCache);
        currentHeld.release(); await page.evaluate(() => window.messageReader);
        assert(!(await cache()).loading);
        if (status === 200) assert.equal((await cache()).content, "Body after acceptance");
        else assert((await cache()).error.includes(String(status)));
        assert.equal(writes, 1); await page.unroute(endpoint, hold);
        await page.evaluate(() => ensureScheduleMessage("file-message", true));
        await open("#schedule/file-message/message");
        assert.equal(await page.locator("#schedule-message-content").inputValue(), "Body after acceptance");
        await page.reload({ waitUntil: "networkidle" });
        assert.equal(await page.locator("#schedule-message-content").inputValue(), "Body after acceptance");
        results.push({ width, theme, case: "reader-after-acceptance-keeps-authority", status, writes, reconciliationCounts: reads.counts, completedReaderNotLoading: true });
      }
      // Observed deletion retires the body and any pending reader. Neither an
      // old write nor an old read may restore that resource's message cache.
      for (const readStatus of [200, 503]) {
        const key = `message-retired-${width}-${theme}-${readStatus}`, retiredEndpoint = `${baseUrl}/schedules/${key}/message`;
        assert.equal((await page.request.post(`${baseUrl}/schedules`, { data: { key, cron: "0 9 * * *", project_key: "web", message_source: "file", message_file: "schedules/message.md" } })).status(), 201);
        await open("#schedules"); await page.evaluate(() => refresh({ force: true })); await open(`#schedule/${key}/message`);
        await page.locator("#schedule-message-content").fill("Retired write");
        const writeHeld = gate(), writeSeen = gate(), readHeld = gate(), readSeen = gate();
        let writes = 0;
        const hold = async route => {
          const response = await route.fetch();
          if (route.request().method() === "PATCH") { writes++; writeSeen.release(); await writeHeld.promise; return route.fulfill({ response }); }
          readSeen.release(); await readHeld.promise; return completeRead(route, response, readStatus);
        };
        await page.route(retiredEndpoint, hold);
        await page.locator("#schedule-message-form button[type=submit]").click(); await wait(writeSeen);
        await page.evaluate(key => { window.messageReader = ensureScheduleMessage(key, true); }, key); await wait(readSeen);
        assert.equal((await page.request.delete(`${baseUrl}/schedules/${key}`)).status(), 200);
        await page.evaluate(() => refresh({ force: true }));
        assert.equal(await page.evaluate(key => state.scheduleMessages[key], key), undefined);
        const fail = route => route.fulfill({ status: 503, json: { error: "Controlled deleted-record reconciliation failure" } });
        await page.route(`${baseUrl}/schedules`, fail); const reads = countReads();
        writeHeld.release(); await settleSave(); reads.stop(); readHeld.release(); await page.evaluate(() => window.messageReader);
        assert.equal(await page.evaluate(key => state.scheduleMessages[key], key), undefined);
        assert.equal(await page.evaluate(key => Boolean(findSchedule(key)), key), false);
        assert.equal(writes, 1); assert.deepEqual(reads.counts, { catalog: 1, setup: 1, schedules: 1 });
        await page.unroute(`${baseUrl}/schedules`, fail); await page.unroute(retiredEndpoint, hold);
        results.push({ width, theme, case: "deleted-message-rejects-old-write-and-read", readStatus, writes, reconciliationCounts: reads.counts, cacheAbsent: true });
      }
      assert.deepEqual(errors, []);
    } finally {
      releases.forEach(release => release());
      await context.close();
    }
  }
  if (captureDir) {
    fs.mkdirSync(captureDir, { recursive: true });
    fs.writeFileSync(path.join(captureDir, "schedule-message-ordering-results.json"), JSON.stringify(results, null, 2));
  }
  console.log(`schedule_message_ordering_smoke: ok (${results.length} response permutations; body versions, stale saves, readers, failures, deletion)`);
};
