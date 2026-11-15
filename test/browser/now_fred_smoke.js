const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");

module.exports = async ({ browser, baseUrl, captureDir }) => {
  const pairs = { d: "All done. Hooray!", e: "Nothing left? Thought so.", f: "And… relax. All done." };
  for (const width of [1440, 390]) for (const mode of ["dark", "light"]) {
    const context = await browser.newContext({viewport: {width, height: 900}, serviceWorkers: "block", reducedMotion: "no-preference"});
    const page = await context.newPage();
    const errors = [];
    page.on("pageerror", e => errors.push(e.message));
    await page.addInitScript(() => { document.hasFocus = () => true; Math.random = () => window.__fredRandom || 0; });
    try {
      await page.clock.install();
      await page.goto(`${baseUrl}/ui#now`);
      await page.waitForFunction(() => state.lastUpdatedAt !== null && !state.refreshInFlight);
      await page.evaluate(() => { state.agents = []; render(); });
      await page.locator("[data-now-fred]").waitFor();
      await page.clock.pauseAt(new Date());
      // Restart just the mascot cadence under the clock; keep the production model.
      await page.evaluate(() => { nowFred.update({empty: true, shown: false}); syncNowFred(); });
      const checkPair = async () => {
        assert.equal(await page.locator("[data-now-fred]").count(), 1);
        const id = await page.locator("[data-now-fred]").getAttribute("data-now-fred");
        assert.equal(await page.locator("[data-now-fred] p").textContent(), pairs[id]);
        assert.equal(await page.locator("[data-now-fred] img").getAttribute("src"), `/now-fred/${id}.webp`);
        await page.locator("[data-now-fred] img").evaluate(img => img.decode());
        assert.deepEqual(await page.locator("[data-now-fred] img").evaluate(img => [img.naturalWidth, img.naturalHeight, img.clientWidth, img.clientHeight]), [384, 256, 192, 128]);
        return id;
      };
      let id = await checkPair();
      const first = id;
      await page.evaluate(() => { for (let i = 0; i < 6; i++) render(); });
      assert.equal(await checkPair(), first, "rerenders preserve selection");
      await page.evaluate(() => refresh({force: true}));
      await page.evaluate(() => { state.agents = []; render(); });
      assert.equal(await checkPair(), first, "polling preserves selection");
      await page.waitForFunction(() => !state.refreshInFlight && !state.activityInFlight);
      await page.evaluate(() => { clearTimeout(state.timer); clearTimeout(state.activityTimer); schedule = () => {}; scheduleAgentActivity = () => {}; });
      for (let i = 0; i < 3; i++) {
        await page.clock.runFor(30000);
        const next = await checkPair();
        assert.notEqual(next, id, "rotation avoids immediate repeat");
        id = next;
      }
      await page.emulateMedia({reducedMotion: "reduce"});
      await page.clock.runFor(100);
      await page.evaluate(() => syncNowFred());
      await page.clock.runFor(60000);
      assert.equal(await checkPair(), id, "reduced motion keeps a static selection");
      await page.emulateMedia({reducedMotion: "no-preference"});
      await page.evaluate(() => { Object.defineProperty(document, "hidden", {configurable: true, value: true}); document.dispatchEvent(new Event("visibilitychange")); });
      await page.clock.runFor(60000);
      assert.equal(await checkPair(), id, "hidden page stops rotation");
      await page.evaluate(() => { Object.defineProperty(document, "hidden", {configurable: true, value: false}); document.dispatchEvent(new Event("visibilitychange")); });
      await page.clock.runFor(30000);
      assert.notEqual(await checkPair(), id);
      id = await checkPair();
      await page.evaluate(() => window.dispatchEvent(new PageTransitionEvent("pagehide")));
      await page.clock.runFor(60000);
      assert.equal(await checkPair(), id, "page disposal stops rotation");
      await page.evaluate(() => window.dispatchEvent(new PageTransitionEvent("pageshow")));
      await checkPair();
      await page.evaluate(() => { state.connection = "Offline: synthetic failure"; render(); });
      assert.equal(await page.locator("[data-now-fred]").count(), 0, "errors cannot show success");
      assert(await page.getByText("Cannot confirm all clear", {exact: true}).isVisible());
      await page.evaluate(() => { state.lastUpdatedAt = null; state.connection = "Connecting"; render(); });
      assert.equal(await page.locator("[data-now-fred]").count(), 0, "loading cannot show success");
      await page.evaluate(() => { state.lastUpdatedAt = new Date(); state.connection = "Connected"; state.servers.forEach(s => s.stale = false); render(); });
      await checkPair();
      await page.evaluate(() => { state.agents = [{key: "fixture-running", running: true, name: "Working", status: "running"}]; render(); });
      assert.equal(await page.locator("[data-now-fred]").count(), 0, "work removes empty state");
      await page.clock.runFor(30000);
      assert.equal(await page.locator("[data-now-fred]").count(), 0, "nonempty work stays free of a rotation timer");
      await page.evaluate(() => { state.agents = []; render(); });
      await page.goto(`${baseUrl}/ui#agents`);
      assert.equal(await page.locator("[data-now-fred]").count(), 0, "route exit removes mascot");
      await page.goto(`${baseUrl}/ui#now`);
      await page.waitForFunction(() => !state.refreshInFlight && state.lastUpdatedAt);
      await page.evaluate(() => { state.agents = []; render(); });
      await page.emulateMedia({reducedMotion: "reduce"});
      await page.clock.runFor(100);
      await page.evaluate(() => syncNowFred());
      for (const backdrop of [false, true]) {
        await page.evaluate(({mode, backdrop}) => {
          TychoAppearance.setPreference(mode);
          TychoAppearance.setTheme(mode, backdrop ? (mode === "dark" ? "builtin:depok-city" : "builtin:senggigi-beach") : (mode === "dark" ? "dracula" : "nord"));
        }, {mode, backdrop});
        if (backdrop) await page.waitForFunction(() => document.documentElement.dataset.imageBackdrop === "theme");
        for (const variant of ["d", "e", "f"]) {
          // Select through the real controller, without adding a production test switch.
          await page.evaluate(variant => {
            nowFred.update({empty: false, shown: false});
            window.__fredRandom = variant === "f" ? .99 : 0;
            // The controller captured the init-script function: alternate entries until selected.
            for (let i = 0; i < 6; i++) { render(); if (document.querySelector("[data-now-fred]")?.dataset.nowFred === variant) break; nowFred.update({empty: false, shown: false}); }
          }, variant);
          const selected = await checkPair();
          assert.equal(selected, variant);
          assert(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth));
          const box = await page.locator("[data-now-fred]").boundingBox();
          assert(box.x >= 0 && box.x + box.width <= width && box.y + box.height <= 900);
          if (captureDir) { fs.mkdirSync(captureDir, {recursive: true}); await page.screenshot({path: path.join(captureDir, `${width}-${mode}-${backdrop ? "photo" : "plain"}-${variant}-${selected}.png`)}); }
        }
      }
      assert.deepEqual(errors, []);
    } finally { await context.close(); }
  }
  console.log("Now FRED: pairing, lifecycle, loading/error/work, desktop/mobile, Dark/Light and photo cases passed.");
};
