const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");

module.exports = async ({ browser, baseUrl, captureDir }) => {
  await require("./schedules_page_smoke")({ browser, baseUrl, captureDir });
  await require("./schedule_message_ordering_smoke")({ browser, baseUrl, captureDir });
  await require("./schedule_ordering_smoke")({ browser, baseUrl, captureDir });
  const results = [];
  const barrier = () => { let release; const promise = new Promise(resolve => { release = resolve; }); return { promise, release }; };
  for (const width of [1440, 390]) for (const theme of ["dark", "light"]) {
    const context = await browser.newContext({ viewport: { width, height: 900 }, isMobile: width < 500, hasTouch: width < 500 });
    const page = await context.newPage();
    await page.addInitScript(() => { document.hasFocus = () => true; });
    page.setDefaultTimeout(10000);
    const errors = [];
    try {
      page.on("pageerror", error => errors.push(error.message));
      await page.goto(`${baseUrl}/ui#settings`, { waitUntil: "networkidle" });
      await page.locator("[data-appearance-preference]").selectOption(theme);
      const open = async hash => {
        await page.goto(`${baseUrl}/ui${hash}`, { waitUntil: "networkidle" });
        await page.waitForFunction(() => !state.refreshInFlight);
        await page.evaluate(() => {
          clearTimeout(state.timer);
          if (!window.scheduleSaveRefreshCalls) {
            window.scheduleSaveRefreshCalls = [];
            const original = refresh;
            refresh = async options => { scheduleSaveRefreshCalls.push(options || {}); return original(options); };
          }
        });
      };
      const settle = async () => {
        await page.waitForFunction(() => !state.refreshInFlight && state.pendingFormKeys.size === 0);
        await page.waitForTimeout(80);
      };
      const key = `saved-${width}-${theme}`;
      for (const kind of ["create", "edit", "message"]) {
        console.log(`schedule save ${width} ${theme} ${kind}`);
        const message = kind === "message";
        const hash = message ? "#schedule/file-message/message" : kind === "edit" ? `#schedule/${key}/edit` : "#schedule/new";
        const form = page.locator(message ? "#schedule-message-form" : "#schedule-form");
        await open(hash);
        await form.waitFor({ state: "visible" });
        if (message) await page.locator("#schedule-message-content").fill(`File body ${width} ${theme}\nSecond line.\n`);
        else {
          if (kind === "create") await page.locator("#schedule-key").fill(key);
          await page.locator("#schedule-name").fill(`  Normalized ${kind} ${width} ${theme}  `);
          await page.locator("#schedule-message").fill(`  Inline ${kind} body  `);
        }
        const expectedName = `Normalized ${kind} ${width} ${theme}`;
        const held = barrier(), seen = barrier();
        const counts = { writes: 0, catalog: 0, setup: 0, schedules: 0 };
        let counting = true;
        const count = request => {
          if (!counting) return;
          const url = new URL(request.url());
          if (request.method() !== "GET" && url.pathname.startsWith("/schedules")) counts.writes++;
          if (url.pathname === "/servers/resources") counts.catalog++;
          if (/^\/setup(?:\/summary)?$/.test(url.pathname)) counts.setup++;
          if (url.pathname === "/schedules" && request.method() === "GET") counts.schedules++;
        };
        page.on("request", count);
        const holdShell = async route => {
          if (route.request().method() !== "GET") return route.continue();
          seen.release();
          await held.promise;
          return route.continue();
        };
        await page.route(`${baseUrl}/schedules`, holdShell);
        await page.evaluate(() => { clearTimeout(state.timer); scheduleSaveRefreshCalls.length = 0; });
        await form.locator("button[type=submit]").click();
        await Promise.race([seen.promise, page.waitForTimeout(10000).then(() => { throw Error("Expected held request was not sent"); })]);
        const pending = await page.evaluate(({ message, key, expectedName, kind }) => ({
          calls: scheduleSaveRefreshCalls.length, pending: state.pendingFormKeys.size,
          hash: location.hash,
          saved: message ? state.scheduleMessages["file-message"] : findSchedule(key),
        }), { message, key, expectedName, kind });
        assert.equal(pending.calls, 1, "one reconciliation before held shell read");
        assert.equal(pending.pending, 1, "pending lasts through deliberate reconciliation");
        assert.equal(pending.hash, "#schedules");
        if (message) assert.equal(pending.saved.content, `File body ${width} ${theme}\nSecond line.\n`);
        else {
          assert.equal(pending.saved.key, key);
          assert.equal(pending.saved.name, expectedName);
          assert.equal(pending.saved.message, `Inline ${kind} body`);
          assert.equal(pending.saved.project_key, "web");
        }
        held.release();
        await settle();
        counting = false;
        page.off("request", count);
        await page.unroute(`${baseUrl}/schedules`, holdShell);
        assert.deepEqual(counts, { writes: 1, catalog: 1, setup: 1, schedules: 1 });
        assert.equal(await page.evaluate(() => scheduleSaveRefreshCalls.length), 1);
        results.push({ width, theme, kind, counts, forcedRefreshes: 1 });
        if (!message) {
          assert((await page.locator("#view").innerText()).includes(expectedName));
          if (captureDir && kind === "edit") {
            fs.mkdirSync(captureDir, { recursive: true });
            await page.screenshot({ path: path.join(captureDir, `schedule-saved-${theme}-${width}.png`) });
          }
          await page.goBack({ waitUntil: "networkidle" });
          if (kind === "edit") assert.equal(await page.locator("#schedule-name").inputValue(), expectedName);
          await open(`#schedule/${key}/edit`);
          assert.equal(await page.locator("#schedule-key").inputValue(), key);
          assert.equal(await page.locator("#schedule-name").inputValue(), expectedName);
          await page.reload({ waitUntil: "networkidle" });
          assert.equal(await page.locator("#schedule-message").inputValue(), `Inline ${kind} body`);
        } else {
          await open(hash);
          assert.equal(await page.locator("#schedule-message-content").inputValue(), `File body ${width} ${theme}\nSecond line.\n`);
          await page.reload({ waitUntil: "networkidle" });
          assert.equal(await page.locator("#schedule-message-content").inputValue(), `File body ${width} ${theme}\nSecond line.\n`);
        }
      }

      // A real validation error and malformed/mismatched success bodies keep the draft.
      for (const fault of ["validation", "empty", "wrong-key", "bad-message"]) {
        console.log(`schedule fault ${width} ${theme} ${fault}`);
        const isMessage = fault === "bad-message";
        await open(isMessage ? "#schedule/file-message/message" : `#schedule/${key}/edit`);
        const selector = isMessage ? "#schedule-message-content" : "#schedule-name";
        await page.locator(selector).fill(`Draft ${fault}`);
        if (fault === "validation") await page.locator("#schedule-cron").fill("bad cron");
        const endpoint = `${baseUrl}/schedules/${isMessage ? "file-message/message" : key}`;
        const fail = route => route.request().method() === "GET" ? route.continue() : route.fulfill({ json: fault === "wrong-key" ? { schedule: { key: "other" } } : fault === "bad-message" ? { message: { key: "file-message", content: null } } : {} });
        if (fault !== "validation") await page.route(endpoint, fail);
        await page.locator(isMessage ? "#schedule-message-form button[type=submit]" : "#schedule-form button[type=submit]").click();
        await settle();
        assert.equal(await page.locator(selector).inputValue(), `Draft ${fault}`);
        assert.equal(await page.locator(selector).isEnabled(), true);
        assert.notEqual(new URL(page.url()).hash, "#schedules");
        await page.reload({ waitUntil: "networkidle" });
        assert.equal(await page.locator(selector).inputValue(), `Draft ${fault}`);
        if (fault !== "validation") await page.unroute(endpoint, fail);
        await page.evaluate(() => { clearFormDraft(document.querySelector("form")); });
        results.push({ width, theme, fault, draftRetained: true });
      }

      for (const kind of ["create", "edit", "message"]) for (const status of [400, 401, 200]) {
        if (kind === "edit" && status === 200) continue;
        const message = kind === "message";
        const hash = message ? "#schedule/file-message/message" : kind === "create" ? "#schedule/new" : `#schedule/${key}/edit`;
        await open(hash);
        const selector = message ? "#schedule-message-content" : "#schedule-name";
        await page.locator(selector).fill(`Retain ${kind} ${status}`);
        if (kind === "create") {
          await page.locator("#schedule-key").fill(`failed-${width}-${theme}-${status}`);
          await page.locator("#schedule-message").fill("Synthetic error test");
        }
        const endpoint = `${baseUrl}/schedules${kind === "create" ? "" : `/${message ? "file-message/message" : key}`}`;
        let writes = 0;
        const failure = route => {
          if (route.request().method() === "GET") return route.continue();
          writes++;
          return route.fulfill({ status, contentType: "application/json", body: status === 200 ? "invalid JSON" : JSON.stringify({ error: `Synthetic write ${status}` }) });
        };
        await page.route(endpoint, failure);
        await page.locator(message ? "#schedule-message-form button[type=submit]" : "#schedule-form button[type=submit]").click();
        await settle();
        assert.equal(writes, 1);
        assert.equal(new URL(page.url()).hash, hash);
        assert.equal(await page.locator(selector).inputValue(), `Retain ${kind} ${status}`);
        assert.equal(await page.locator(selector).isEnabled(), true);
        await page.unroute(endpoint, failure);
        await page.reload({ waitUntil: "networkidle" });
        assert.equal(await page.locator(selector).inputValue(), `Retain ${kind} ${status}`);
        await page.evaluate(() => clearFormDraft(document.querySelector("form")));
        results.push({ width, theme, kind, writeStatus: status, writes, draftRetained: true });
      }

      // Delayed successful writes must not install an old object or clear a newer
      // draft after a route excursion, including a return to the same form.
      for (const kind of ["create", "edit", "message"]) {
        console.log(`schedule delayed ${width} ${theme} ${kind}`);
        const message = kind === "message";
        const staleKey = `late-${width}-${theme}`;
        const hash = message ? "#schedule/file-message/message" : kind === "create" ? "#schedule/new" : `#schedule/${key}/edit`;
        const selector = message ? "#schedule-message-content" : "#schedule-name";
        await open(hash);
        if (kind === "create") await page.locator("#schedule-key").fill(staleKey);
        await page.locator(selector).fill("Old submitted value");
        if (kind === "create") await page.locator("#schedule-message").fill("Synthetic late message");
        const held = barrier(), seen = barrier();
        const endpoint = kind === "create" ? `${baseUrl}/schedules` : `${baseUrl}/schedules/${message ? "file-message/message" : key}`;
        let writes = 0;
        const delay = async route => {
          if (route.request().method() === "GET") return route.continue();
          writes++;
          const response = await route.fetch();
          seen.release();
          await held.promise;
          await route.fulfill({ response });
        };
        await page.route(endpoint, delay);
        const formSelector = message ? "#schedule-message-form" : "#schedule-form";
        await page.locator(`${formSelector} button[type=submit]`).click();
        await Promise.race([seen.promise, page.waitForTimeout(10000).then(() => { throw Error("Expected held request was not sent"); })]);
        // A second submit event while pending must not write again.
        await page.locator(formSelector).evaluate(form => form.dispatchEvent(new Event("submit", { bubbles: true, cancelable: true })));
        assert.equal(writes, 1);
        await open("#schedules");
        await open(hash);
        await page.waitForFunction(() => state.pendingFormKeys.size === 1);
        // Inputs are still pending on the same route. Inject the user's newer
        // restored draft to exercise a replacement form while the old save waits.
        await page.locator(selector).evaluate(input => { input.disabled = false; });
        await page.locator(selector).fill("Newer draft after navigation");
        await page.locator(selector).evaluate(input => input.blur());
        await page.locator(selector).focus();
        const before = await page.evaluate(({ message, key }) => JSON.stringify(message ? state.scheduleMessages["file-message"] : findSchedule(key)), { message, key });
        held.release();
        await settle();
        assert.equal(new URL(page.url()).hash, hash);
        assert.equal(await page.locator(selector).inputValue(), "Newer draft after navigation");
        assert.equal(await page.locator(selector).evaluate(input => document.activeElement === input), true);
        assert.equal(await page.evaluate(({ message, key }) => JSON.stringify(message ? state.scheduleMessages["file-message"] : findSchedule(key)), { message, key }), before);
        assert.equal(writes, 1);
        await page.unroute(endpoint, delay);
        await page.reload({ waitUntil: "networkidle" });
        assert.equal(await page.locator(selector).inputValue(), "Newer draft after navigation");
        await page.evaluate(() => clearFormDraft(document.querySelector("form")));
        results.push({ width, theme, kind, delayedWrite: "newer route/draft preserved", writes });
      }

      const retiredKey = `retired-${width}-${theme}`;
      const created = await fetch(`${baseUrl}/schedules`, { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ key: retiredKey, cron: "0 9 * * *", project_key: "web", message: "Synthetic retirement" }) });
      assert.equal(created.status, 201);
      await open("#schedules");
      await page.evaluate(() => refresh({ force: true }));
      await open(`#schedule/${retiredKey}/edit`);
      await page.locator("#schedule-name").fill("Delayed retired schedule");
      const retiredHeld = barrier(), retiredSeen = barrier();
      const retiredEndpoint = `${baseUrl}/schedules/${retiredKey}`;
      const holdRetired = async route => {
        const response = await route.fetch();
        retiredSeen.release();
        await retiredHeld.promise;
        return route.fulfill({ response });
      };
      await page.route(retiredEndpoint, holdRetired);
      await page.locator("#schedule-form button[type=submit]").click();
      await retiredSeen.promise;
      await open("#schedules");
      const removed = await fetch(retiredEndpoint, { method: "DELETE" });
      assert.equal(removed.status, 200);
      await page.evaluate(() => refresh({ force: true }));
      assert.equal(await page.evaluate(key => Boolean(findSchedule(key)), retiredKey), false);
      retiredHeld.release();
      await settle();
      assert.equal(new URL(page.url()).hash, "#schedules");
      assert.equal(await page.evaluate(key => Boolean(findSchedule(key)), retiredKey), false);
      await page.unroute(retiredEndpoint, holdRetired);
      results.push({ width, theme, retiredDelayedWrite: "schedule stays absent" });

      // Read failures happen after a validated write. The normalized schedule
      // stays available; auth and normal refresh recovery still work.
      for (const status of [503, 401]) {
        await open(`#schedule/${key}/edit`);
        await page.locator("#schedule-name").fill(`Saved before read ${status}`);
        const failShell = route => route.fulfill({ status, json: { error: `Synthetic shell ${status}` } });
        await page.route(/\/setup(?:\/summary)?$/, failShell);
        await page.locator("#schedule-form button[type=submit]").click();
        await settle();
        assert.equal(new URL(page.url()).hash, "#schedules");
        assert.equal(await page.evaluate(key => findSchedule(key).name, key), `Saved before read ${status}`);
        if (status === 401) assert.equal(await page.locator("#auth-panel").isVisible(), true);
        await page.unroute(/\/setup(?:\/summary)?$/, failShell);
        await page.evaluate(() => refresh({ force: true }));
        assert.equal(await page.locator("#auth-panel").isVisible(), false);
        results.push({ width, theme, readStatus: status, recovered: true });
      }

      // Ordinary poll refresh preserves a focused draft and responsive layout.
      await open(`#schedule/${key}/edit`);
      await page.locator("#schedule-name").fill("Focused polling draft");
      await page.locator("#schedule-name").focus();
      const pollCount = await page.evaluate(() => {
        const count = scheduleSaveRefreshCalls.length;
        state.pollDeferredUntil = 0;
        schedule(120);
        return count;
      });
      await page.waitForFunction(count => scheduleSaveRefreshCalls.length > count && !state.refreshInFlight, pollCount);
      assert.equal(await page.evaluate(() => Boolean(scheduleSaveRefreshCalls.at(-1)?.force)), false);
      assert.equal(await page.locator("#schedule-name").inputValue(), "Focused polling draft");
      assert.equal(await page.locator("#schedule-name").evaluate(input => document.activeElement === input), true);
      const layout = await page.evaluate(() => ({ width: innerWidth, scrollWidth: document.documentElement.scrollWidth }));
      assert(layout.scrollWidth <= layout.width + 1, JSON.stringify(layout));
      if (captureDir) {
        fs.mkdirSync(captureDir, { recursive: true });
        await page.screenshot({ path: path.join(captureDir, `schedule-form-${theme}-${width}.png`), fullPage: true });

      }
      assert.deepEqual(errors, []);
    } catch (error) {
      console.error("Failed schedule case", width, theme, errors, page.url(), await page.locator("#view").innerText(), await page.evaluate(() => ({ failureCount: state.failureCount, active: pollingWindowIsActive(), refreshing: state.refreshInFlight, setup: Boolean(state.setup), projects: state.projects.length, schedules: state.schedules.length, initial: state.initialRouteLoaded })));
      if (captureDir) await page.screenshot({ path: path.join(captureDir, "failure.png") });
      throw error;
    }
    await context.close();
  }
  if (captureDir) fs.writeFileSync(path.join(captureDir, "schedule-save-results.json"), JSON.stringify(results, null, 2));
  console.log("schedule_save_smoke: ok (one reconciliation, normalized identity/body, errors, delayed writes, drafts, polling, desktop/mobile Dark/Nord Light)");
};
