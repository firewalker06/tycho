const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");

module.exports = async ({ browser, baseUrl, captureDir }) => {
  if (captureDir) fs.mkdirSync(captureDir, { recursive: true });
  const capture = async (page, name) => {
    if (captureDir) await page.screenshot({ path: path.join(captureDir, `${name}.png`) });
  };
  for (const [device, viewport] of Object.entries({ desktop: { width: 1440, height: 900 }, mobile: { width: 390, height: 844 } })) {
    for (const mode of ["dark", "light"]) {
      for (const variant of ["legacy", "curves"]) {
        const context = await browser.newContext({ viewport, serviceWorkers: "block" });
        await context.addInitScript(({ mode, variant }) => {
          if (!location.protocol.startsWith("http")) return;
          const random = Math.random;
          let draws = 0;
          Math.random = () => ++draws === 2 ? (variant === "legacy" ? .25 : .75) : draws === 1 ? .25 : random();
          localStorage.setItem("hq.remote.appearance", mode);
          if (localStorage.getItem("hq.remote.startup-message") === null) localStorage.setItem("hq.remote.startup-message", "The factory must grow…");
        }, { mode, variant });
        const page = await context.newPage();
        const errors = [];
        page.on("pageerror", e => errors.push(e.message));
        let release;
        const gate = new Promise(resolve => { release = resolve; });
        await page.route("**/ui.js?*", async route => { await gate; await route.continue(); });
        const navigation = page.goto(`${baseUrl}/ui`, { waitUntil: "load" });
        await page.locator("#tycho-boot-message").filter({ hasText: "The factory must grow…" }).waitFor();
        assert.equal(await page.evaluate(() => typeof state), "undefined", "custom text before app execution");
        assert.equal(await page.locator("#tycho-boot-shell").getAttribute("data-animation"), variant);
        const moving = page.locator(variant === "legacy" ? ".tycho-boot-mark" : ".tycho-boot-signal").first();
        assert.equal(await moving.evaluate(el => getComputedStyle(el).animationDuration), variant === "legacy" ? "2s" : "1.2s");
        const before = await moving.evaluate(el => getComputedStyle(el).transform);
        await page.waitForTimeout(650); // The original legacy orbit rests for its first 25%.
        assert.notEqual(await moving.evaluate(el => getComputedStyle(el).transform), before);
        if (variant === "legacy") {
          assert(await page.locator(".tycho-boot-particle").count() > 0);
          assert.equal(await page.locator(".tycho-boot-orbit").isVisible(), false);
          const duration = await page.locator(".tycho-boot-particle").first().evaluate(el => parseFloat(getComputedStyle(el).animationDuration));
          assert(duration >= .6 && duration <= .9);
        } else {
          assert.equal(await page.locator(".tycho-boot-particle").count(), 0);
          assert.equal(await page.locator(".tycho-boot-mark").evaluate(el => getComputedStyle(el).animationName), "none");
        }
        const dots = await page.locator(".tycho-boot-mark rect").evaluateAll(els => els.map(el => ({ y: +el.getAttribute("y"), height: +el.getAttribute("height") })));
        assert.equal(dots[1].y - dots[0].y - dots[0].height, dots[2].y - dots[1].y - dots[1].height);
        console.log(JSON.stringify({ device, mode, variant, assetVersion: await page.evaluate(() => document.documentElement.dataset.assetVersion) }));
        await capture(page, `startup-${variant}-${device}-${mode}`);
        await page.waitForTimeout(150);
        await capture(page, `startup-${variant}-${device}-${mode}-motion`);
        assert.equal(await page.locator(".tycho-boot-signal").count(), 3);
        assert.equal(await page.locator(".tycho-boot-caption").count(), 0);
        const textStyle = await page.locator("#tycho-boot-message").evaluate(el => ({size:parseFloat(getComputedStyle(el).fontSize),weight:getComputedStyle(el).fontWeight}));
        assert.equal(textStyle.size, device === "desktop" ? 35 : 21);
        assert.equal(textStyle.weight, "700");
        await page.emulateMedia({ reducedMotion: "reduce" });
        assert.equal(await moving.evaluate(el => getComputedStyle(el).animationName), "none");
        assert.equal(await page.locator(".tycho-boot-mark").evaluate(el => getComputedStyle(el).animationName), "none");
        await page.waitForFunction(() => document.querySelectorAll(".tycho-boot-particle").length === 0);
        await capture(page, `startup-${variant}-${device}-${mode}-reduced`);
        assert(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth));
        await page.emulateMedia({ reducedMotion: "no-preference" });
        assert.equal(await page.locator("#tycho-boot-shell").getAttribute("data-animation"), variant);
        if (variant === "legacy") await page.waitForFunction(() => document.querySelectorAll(".tycho-boot-particle").length > 0);
        assert.equal(await page.locator("#tycho-boot-shell").evaluate(el => getComputedStyle(el).overflowX), "hidden");
        await page.locator("#tycho-boot-message").evaluate(el => { el.textContent = "Coordinating the next generation of agents across every project while the factory continues to grow"; });
        assert(await page.locator("#tycho-boot-message").evaluate(el => el.scrollWidth <= el.clientWidth));
        assert(await page.locator("#tycho-boot-retry").evaluate(el => el.getBoundingClientRect().bottom <= innerHeight));
        await capture(page, `startup-long-${variant}-${device}-${mode}`);
        release(); await navigation; await page.unroute("**/ui.js?*");
        await page.locator("#tycho-boot-shell").waitFor({ state: "hidden" });
        assert.equal(await page.locator("#app").getAttribute("aria-busy"), "false");
        assert.equal(await page.locator(".tycho-boot-particle").count(), 0, "ready handoff cleans particles");
        await page.goto(`${baseUrl}/ui#settings`);
        const input = page.locator("#startup-message");
        await input.waitFor();
        assert.equal(await input.inputValue(), "The factory must grow…");
        assert.equal(await input.evaluate(el => el.tagName), "TEXTAREA");
        assert.equal(await input.evaluate(el => el.labels[0].textContent), "Startup text");
        assert.equal(await input.getAttribute("placeholder"), "The factory must grow\nOrchestrating the orchestrator");
        assert.equal(await page.locator("#startup-message-help, #appearance-help").count(), 0);
        await input.fill("");
        await page.evaluate(() => refresh({ force: true }));
        assert.equal(await input.inputValue(), "", "placeholder is not input content");
        assert.equal(await page.evaluate(() => localStorage.getItem("hq.remote.startup-message")), "", "placeholder is never saved");
        await page.reload();
        await page.locator("#tycho-boot-shell").waitFor({ state: "hidden" });
        await input.waitFor();
        assert.equal(await input.inputValue(), "", "empty value remains empty after reload");
        assert.equal(await input.getAttribute("placeholder"), "The factory must grow\nOrchestrating the orchestrator");
        assert.equal(await page.evaluate(() => localStorage.getItem("hq.remote.startup-message")), "");
        await input.scrollIntoViewIfNeeded();
        await capture(page, `startup-settings-${variant}-${device}-${mode}`);
        await input.fill("Your agent can do what?\n\nSecond candidate");
        await page.evaluate(() => refresh({ force: true }));
        assert.equal(await input.inputValue(), "Your agent can do what?\n\nSecond candidate");
        await input.scrollIntoViewIfNeeded();
        await page.waitForTimeout(250);
        await capture(page, `startup-settings-filled-${variant}-${device}-${mode}`);
        // Hold actual route data: readiness must keep the shell until the data arrives.
        let releaseData, signalData;
        const dataHeld = new Promise(resolve => { signalData = resolve; });
        const dataGate = new Promise(resolve => { releaseData = resolve; });
        await page.route(/\/servers\/resources(?:\?|$)/, async route => { signalData(); await dataGate; await route.continue(); });
        await page.goto("about:blank");
        await page.goto(`${baseUrl}/ui#agents`);
        await dataHeld;
        await page.waitForTimeout(250);
        await page.locator("#tycho-boot-message").filter({ hasText: /Your agent can do what\?|Second candidate/ }).waitFor();
        assert.equal(await page.locator("#tycho-boot-shell").evaluate(el => el.hidden), false);
        assert.equal(await page.locator("#tycho-boot-shell").getAttribute("data-animation"), variant);
        releaseData();
        await page.locator("#tycho-boot-shell").waitFor({ state: "hidden" });
        await page.unroute(/\/servers\/resources(?:\?|$)/);
        // Safe literal content persists through reload and Settings rendering.
        await page.goto(`${baseUrl}/ui#settings`);
        await input.fill('<img src=x onerror="window.injected=true">');
        await page.reload(); await input.waitFor();
        assert.equal(await input.inputValue(), '<img src=x onerror="window.injected=true">');
        assert.equal(await page.evaluate(() => window.injected), undefined);
        await input.fill("   ");
        await page.route("**/ui.js?*", route => route.abort());
        await page.reload();
        assert(["The factory must grow", "Orchestrating the orchestrator"].includes(await page.locator("#tycho-boot-message").textContent()));
        // Use the real fallback timeout when the main script cannot load.
        await page.locator("#tycho-boot-retry").waitFor({ state: "visible", timeout: 20000 });
        assert((await page.locator("#tycho-boot-message").textContent()).includes("could not finish loading"));
        assert.equal(await page.locator(".tycho-boot-particle").count(), 0, "failure cleans particles");
        assert.equal(await moving.evaluate(el => getComputedStyle(el).animationPlayState), "paused");
        await capture(page, `startup-script-error-${variant}-${device}-${mode}`);
        await page.unroute("**/ui.js?*");
        await page.locator("#tycho-boot-retry").click();
        await page.locator("#tycho-boot-shell").waitFor({ state: "hidden" });
        assert.deepEqual(errors, []);
        await context.close();
        console.log(`Startup passed: ${variant}/${device}/${mode}, pre-app text, animation, reduced motion, readiness, Settings, escaping, fallback/retry`);
      }
    }
  }
  const denied = await browser.newContext({ serviceWorkers: "block" });
  await denied.addInitScript(() => {
    const get = Storage.prototype.getItem;
    const set = Storage.prototype.setItem;
    Storage.prototype.getItem = function (key) { if (key === "hq.remote.startup-message") throw Error("denied"); return get.call(this, key); };
    Storage.prototype.setItem = function (key, value) { if (key === "hq.remote.startup-message") throw Error("full"); return set.call(this, key, value); };
  });
  const deniedPage = await denied.newPage();
  await deniedPage.goto(`${baseUrl}/ui#settings`);
  await deniedPage.locator("#startup-message").fill("Cannot persist");
  assert((await deniedPage.locator("#startup-message-status").textContent()).includes("cannot be saved"));
  assert.equal(await deniedPage.evaluate(() => TychoStartup.getState().persistent), false);
  await denied.close();
  const auth = await browser.newContext({ serviceWorkers: "block" });
  const authPage = await auth.newPage();
  await authPage.route(/\/servers\/resources(?:\?|$)/, route => route.fulfill({ status: 401, contentType: "application/json", body: '{"error":"Unauthorized"}' }));
  await authPage.goto(`${baseUrl}/ui#agents`);
  await authPage.locator("#auth-panel").waitFor({ state: "visible" });
  await authPage.locator("#tycho-boot-shell").waitFor({ state: "hidden" });
  await auth.close();
  const context = await browser.newContext({ serviceWorkers: "block" });
  const page = await context.newPage();
  await page.route(/\/servers\/resources(?:\?|$)/, route => route.abort("internetdisconnected"));
  await page.goto(`${baseUrl}/ui#agents`);
  await page.locator('#tycho-boot-shell[data-state="offline"]').waitFor();
  await page.locator("#tycho-boot-retry").waitFor({ state: "visible" });
  await page.unroute(/\/servers\/resources(?:\?|$)/);
  await page.locator("#tycho-boot-retry").click();
  await page.locator("#tycho-boot-shell").waitFor({ state: "hidden" });
  await context.close();
};
