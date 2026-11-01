const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");

module.exports = async ({ browser, baseUrl, agentKey, captureDir }) => {
  const results = [];
  for (const [device, viewport] of Object.entries({ desktop: { width: 1440, height: 1000 }, mobile: { width: 390, height: 844 } })) {
    const context = await browser.newContext({ viewport, hasTouch: device === "mobile" });
    const page = await context.newPage();
    const errors = [];
    const attachmentRequests = [];
    page.on("request", request => { if (/\/attachments\//.test(request.url())) attachmentRequests.push(request.url()); });
    page.on("pageerror", error => errors.push(error.message));
    const capture = async name => {
      if (captureDir) await page.screenshot({ path: path.join(captureDir, `${device}-${name}.png`) });
    };
    const openFlyout = async () => {
      const toggle = page.locator("[data-toggle-attachments]");
      if (await toggle.getAttribute("aria-expanded") !== "true") {
        if (device === "mobile") await toggle.tap(); else await toggle.click();
      }
      await page.locator("[data-attachment-flyout]").waitFor({ state: "visible" });
    };
    // Optional baseline evidence uses the exact pre-change assets from outside the checkout.
    const before = process.env.TYCHO_REMOTE_UI_FILTER_BEFORE_DIR;
    if (before) {
      await page.route("**/ui.js*", route => route.fulfill({ path: path.join(before, "app.js"), contentType: "text/javascript" }));
      await page.route("**/ui.css*", route => route.fulfill({ path: path.join(before, "app.css"), contentType: "text/css" }));
      await page.goto(`${baseUrl}/ui#agent/${agentKey}`, { waitUntil: "networkidle" });
      await openFlyout();
      assert.equal(await page.locator("[data-attachment-type-filter]").count(), 0, "baseline assets must have no filters");
      assert.equal(await page.locator(".attachment-icon").first().evaluate(el => getComputedStyle(el).borderTopWidth), "1px");
      await capture("before-flyout");
      const first = await page.locator(".attachment-main[href^='#agent/']").first().getAttribute("href");
      await page.goto(`${baseUrl}/ui${first}`, { waitUntil: "networkidle" });
      await page.locator(".attachment-nav-drawer > summary").click();
      await capture("before-navigation");
      await page.unroute("**/ui.js*");
      await page.unroute("**/ui.css*");
    }
    await page.goto(`${baseUrl}/ui#agent/${agentKey}`, { waitUntil: "networkidle" });
    if (before) await page.reload({ waitUntil: "networkidle" });
    const flyout = page.locator("[data-attachment-flyout]");
    const button = (root, type) => root.locator(`[data-attachment-type-filter="${type}"]`);
    for (const preference of ["dark", "light", "system"]) {
      await page.evaluate(preference => window.TychoAppearance.setPreference(preference), preference);
      if (preference === "system") {
        await page.emulateMedia({ colorScheme: "dark" });
        await page.waitForFunction(() => document.documentElement.dataset.appearance === "dark");
        await page.emulateMedia({ colorScheme: "light" });
        await page.waitForFunction(() => document.documentElement.dataset.appearance === "light");
      }
      await openFlyout();
      await button(flyout, "all").click();
      assert.equal(await flyout.locator(".attachment-item").count(), 7);
      await capture(`${preference}-all`);
      const requestsBefore = attachmentRequests.length;
      await button(flyout, "images").focus();
      await page.keyboard.press("Enter");
      assert.equal(await button(flyout, "images").getAttribute("aria-pressed"), "true");
      assert.equal(await flyout.locator(".attachment-item").count(), 1);
      assert.equal(await button(flyout, "images").evaluate(el => el === document.activeElement), true);
      const focus = await button(flyout, "images").evaluate(el => ({ width: getComputedStyle(el).outlineWidth, visible: el.matches(":focus-visible") }));
      assert(focus.visible && parseFloat(focus.width) >= 2);
      await capture(`${preference}-images-focus`);
      await page.evaluate(async () => { await refresh({ force: true }); });
      assert.equal(await button(flyout, "images").getAttribute("aria-pressed"), "true");
      assert.equal(await flyout.locator(".attachment-item").count(), 1);
      await button(flyout, "files").click();
      assert.equal(await flyout.locator(".attachment-item").count(), 5);
      assert((await button(flyout, "files").getAttribute("aria-label")).includes("excluding images"));
      await button(flyout, "links").click();
      assert.equal(await flyout.locator(".attachment-item").count(), 1);
      assert.equal(await flyout.locator(".attachment-main").getAttribute("target"), "_blank");
      await button(flyout, "all").click();
      assert.equal(attachmentRequests.length, requestsBefore, "filters do not request attachment detail or blobs");
      assert.equal(await flyout.locator("img").count(), 0, "list does not eagerly load image previews");
      assert.equal(await flyout.locator(".attachment-icon").first().evaluate(el => getComputedStyle(el).borderTopWidth), "0px");
      assert(parseFloat(await flyout.locator("[data-delete-attachment]").first().evaluate(el => getComputedStyle(el).borderTopWidth)) >= 1);
      const first = await flyout.locator(".attachment-main[href^='#agent/']").first().getAttribute("href");
      await page.goto(`${baseUrl}/ui${first}`, { waitUntil: "networkidle" });
      const drawer = page.locator(".attachment-nav-drawer");
      await drawer.locator("summary").click();
      assert.equal(await drawer.locator("[aria-current='page']").count(), 1);
      await button(drawer, "links").click();
      assert.equal(await drawer.locator(".attachment-nav-item").count(), 1);
      assert.equal(new URL(page.url()).hash, first);
      assert.equal(await drawer.locator(".attachment-filter-selection-note").innerText(), "The open attachment is outside this filter.");
      assert.equal(await drawer.locator("[aria-current='page']").count(), 0);
      assert.equal(await drawer.locator(".attachment-nav-index").innerText(), "7");
      assert.equal(await drawer.locator(".attachment-nav-icon").evaluate(el => getComputedStyle(el).borderTopWidth), "0px");
      await capture(`${preference}-navigation-links`);
      await page.evaluate(async () => { await refresh({ force: true }); });
      assert.equal(await button(drawer, "links").getAttribute("aria-pressed"), "true");
      await button(drawer, "all").click();
      assert.equal(await drawer.locator("[aria-current='page']").count(), 1);
      assert.equal(await drawer.locator(".attachment-nav-item").count(), 7);
      await capture(`${preference}-navigation-all`);
      assert(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth), "no horizontal overflow");
      await page.goto(`${baseUrl}/ui#agent/${agentKey}`, { waitUntil: "networkidle" });
    }
    // Synthetic live catalog updates, duplicates, unknown metadata and empty groups.
    await openFlyout();
    await page.evaluate(key => {
      const agent = findAgent(key);
      const file = agent.attachments.find(item => item.title === "Notes");
      agent.attachments = [file, { ...file, title: "Duplicate" }, { ...file, id: "unknown", path: "/synthetic/unknown", type: "future", format: "future", title: "Unknown format" }];
      render();
    }, agentKey);
    await button(flyout, "images").click();
    assert.equal(await flyout.locator(".attachment-item").count(), 0);
    assert((await flyout.innerText()).includes("No attachments of this type"));
    assert((await flyout.innerText()).includes("0 of 2 shown"));
    await capture("empty-images");
    await button(flyout, "files").click();
    assert.equal(await flyout.locator(".attachment-item").count(), 2);
    await page.evaluate(key => {
      findAgent(key).attachments.push({ id: "updated", type: "file", path: "/synthetic/added", title: "Added file" });
      render();
    }, agentKey);
    assert.equal(await flyout.locator(".attachment-item").count(), 3);
    await button(flyout, "all").click();
    assert.equal(await flyout.locator(".attachment-item").count(), 3);
    assert.deepEqual(errors, []);
    results.push({ device, themes: ["dark", "light", "system"], checks: "counts, keyboard, touch, focus, polling, selection, reset, updates, duplicates, unknown, empty, borders, overflow" });
    await context.close();
  }
  if (captureDir) fs.writeFileSync(path.join(captureDir, "browser-results.json"), JSON.stringify(results, null, 2));
  console.log(`attachment-filter-smoke: ${JSON.stringify(results)}`);
};
