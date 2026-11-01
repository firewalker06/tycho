const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");

module.exports = async ({ browser, baseUrl, agentKey, captureDir }) => {
  const results = [];
  for (const [device, viewport] of Object.entries({ desktop: { width: 1440, height: 1000 }, mobile: { width: 390, height: 844 } })) {
    const context = await browser.newContext({ viewport, hasTouch: device === "mobile", reducedMotion: "reduce", permissions: ["clipboard-read", "clipboard-write"] });
    const page = await context.newPage();
    const errors = [];
    page.on("pageerror", error => errors.push(error.message));
    const capture = async name => {
      await page.waitForFunction(() => document.getElementById("growl").classList.contains("hidden"));
      if (captureDir) await page.screenshot({ path: path.join(captureDir, `${device}-${name}.png`), mask: [page.getByText("PRIVATE_PROMPT_SENTINEL", { exact: true })] });
    };
    const style = control => control.evaluate(element => {
      const css = getComputedStyle(element);
      const box = element.getBoundingClientRect();
      return { border: css.borderTopColor, borderWidth: css.borderTopWidth, background: css.backgroundColor, opacity: css.opacity, color: css.color, width: box.width, height: box.height, outline: css.outlineStyle, outlineWidth: css.outlineWidth };
    });
    const settle = control => control.evaluate(async element => {
      await Promise.all(element.getAnimations().filter(animation => Number.isFinite(animation.effect.getComputedTiming().endTime)).map(animation => animation.finished.catch(() => {})));
    });
    const check = async (selector, label) => {
      await page.waitForFunction(() => !document.body.dataset.routeLoading && !state.refreshInFlight);
      const control = page.locator(selector).first();
      await control.evaluate(element => element.scrollIntoView({ block: "center", behavior: "instant" }));
      await page.mouse.move(0, 0);
      await control.blur();
      await settle(control);
      const normal = await style(control);
      assert.equal(normal.border, "rgba(0, 0, 0, 0)", `${label}: border`);
      assert.equal(normal.borderWidth, "1px", `${label}: retained border geometry`);
      // Real Tab traversal must reach the control, rather than programmatic focus alone.
      await page.locator("body").evaluate(element => { element.tabIndex = -1; element.focus(); });
      let reached = false;
      for (let index = 0; index < 180; index++) {
        await page.keyboard.press("Tab");
        if (await control.evaluate(element => element === document.activeElement)) { reached = true; break; }
      }
      assert(reached, `${label}: Tab reachable`);
      const focused = await style(control);
      assert(focused.outline === "solid" && parseFloat(focused.outlineWidth) >= 2, `${label}: focus ring`);
      if (label === "Previous summary") await capture(`${preference}-summary-keyboard-focus`);
      await control.blur();
      await control.hover();
      await settle(control);
      const hover = await style(control);
      assert.equal(hover.border, normal.border, `${label}: hover border`);
      assert.notEqual(hover.background, normal.background, `${label}: hover cue`);
      await page.mouse.down();
      await settle(control);
      const pressed = await style(control);
      assert.equal(pressed.border, normal.border, `${label}: pressed border`);
      assert.equal(pressed.width, normal.width, `${label}: width`);
      assert.equal(pressed.height, normal.height, `${label}: height`);
      await page.mouse.move(0, 0);
      await page.mouse.up();
      results.push({ device, preference, label, normal, focused, hover, pressed });
    };
    const preserved = async selector => {
      const control = page.locator(selector).first();
      const css = await style(control);
      assert(parseFloat(css.borderWidth) > 0 && css.border !== "rgba(0, 0, 0, 0)", `${selector}: preserved border`);
    };
    let preference;
    for (preference of ["dark", "light", "system"]) {
      await page.goto(`${baseUrl}/ui#agents`, { waitUntil: "networkidle" });
      await page.reload({ waitUntil: "networkidle" });
      await page.evaluate(value => window.TychoAppearance.setPreference(value), preference);
      if (preference === "system") {
        for (const colorScheme of ["dark", "light"]) {
          await page.emulateMedia({ colorScheme });
          await page.waitForFunction(value => document.documentElement.dataset.appearance === value, colorScheme);
        }
      }
      if (device === "desktop") {
        await check(".agent-sort-trigger", "Sort agents");
        await page.locator(".agent-sort-trigger").press("Enter");
        assert(await page.locator(".agent-sort-menu").evaluate(element => element.open));
        assert.equal((await style(page.locator(".agent-sort-trigger"))).border, "rgba(0, 0, 0, 0)");
        await capture(`${preference}-agents-sort-open`);
        await page.keyboard.press("Escape");
        await check(".agent-bulk-select-button", "Select agents");
        await page.locator(".agent-bulk-select-button").press("Enter");
        assert.equal(await page.locator(".agent-bulk-select-button").getAttribute("aria-pressed"), "true");
        assert.equal((await style(page.locator(".agent-bulk-select-button"))).border, "rgba(0, 0, 0, 0)");
        await capture(`${preference}-agents-selected`);
        await page.locator(".agent-bulk-options [data-cancel-bulk-archive]").click();
      } else {
        assert(!await page.locator(".agent-sort-trigger").isVisible(), "Mobile uses the existing toolbar menu");
        await preserved(".agent-mobile-toolbar-trigger");
        await page.locator(".agent-mobile-toolbar-trigger").press("Enter");
        await capture(`${preference}-agents-mobile-menu`);
        await page.keyboard.press("Escape");
      }
      await page.goto(`${baseUrl}/ui#settings`, { waitUntil: "networkidle" });
      await page.waitForFunction(() => state.setupDetailed && !document.body.dataset.routeLoading);
      await page.evaluate(async () => refresh({ force: true }));
      await page.locator(".copy-url-button").waitFor();
      await check(".copy-url-button", "Settings Copy URL");
      await page.locator(".copy-url-button").click();
      assert.equal(await page.evaluate(() => navigator.clipboard.readText()), await page.locator(".copy-url-button").getAttribute("data-copy"));
      await capture(`${preference}-settings-copy`);
      await check(".local-server-list-item .server-row-actions [data-copy]", "Host copy");
      const host = page.locator(".local-server-list-item .server-row-actions [data-copy]");
      await host.click();
      assert.equal(await page.evaluate(() => navigator.clipboard.readText()), await host.getAttribute("data-copy"));
      await capture(`${preference}-settings-host`);
      await page.getByLabel("Server actions", { exact: true }).click();
      await page.locator("[data-toggle-server-form]").click();
      await preserved(".server-connection-grid input");
      await preserved('#server-connection-form button[type="submit"]');
      await page.goto(`${baseUrl}/ui#agent/${agentKey}/summary`, { waitUntil: "networkidle" });
      await page.waitForFunction(() => !document.body.dataset.routeLoading && parseRoute().type === "agentSummary");
      await page.locator(".agent-summary-navigation").waitFor();
      for (const direction of ["Previous", "Next"]) {
        const arrow = page.getByRole("button", { name: `${direction} summary`, exact: true });
        if (await arrow.isEnabled()) await check(`button[aria-label="${direction} summary"]`, `${direction} summary`);
      }
      const disabled = page.locator(".agent-summary-navigation button:disabled");
      assert.equal(await disabled.count(), 1, "Latest summary has one disabled arrow");
      assert.equal((await style(disabled)).border, "rgba(0, 0, 0, 0)");
      const hash = await page.evaluate(() => location.hash);
      await disabled.evaluate(element => element.click());
      assert.equal(await page.evaluate(() => location.hash), hash, "Disabled arrow does not navigate");
      await capture(`${preference}-summary-latest`);
      await page.getByRole("button", { name: "Previous summary", exact: true }).press("Enter");
      await page.waitForFunction(before => location.hash !== before, hash);
      await check('button[aria-label="Next summary"]', "Next summary after previous");
      await page.getByRole("button", { name: "Next summary", exact: true }).press("Enter");
      await page.evaluate(async () => refresh({ force: true }));
      assert.equal(await page.locator(".agent-summary-navigation button:disabled").count(), 1);
      await page.goto(`${baseUrl}/ui#agent/${agentKey}`, { waitUntil: "networkidle" });
      await page.locator(".agent-floating-pill[data-open-agent-pr-diffs]").click();
      await page.waitForFunction(() => parseRoute().type === "agentPullRequests" && !document.body.dataset.routeLoading && !state.refreshInFlight);
      await page.locator("[data-toggle-pr-diff-full-view]").waitFor();
      await check("[data-toggle-pr-diff-full-view]", "PR Full view");
      await check('.pr-diff-title-actions a[aria-label="Open pull request"]', "PR external link");
      const external = page.locator('.pr-diff-title-actions a[aria-label="Open pull request"]');
      assert.equal(await external.getAttribute("href"), "https://github.com/example/web/pull/123");
      assert.equal(await external.getAttribute("target"), "_blank");
      for (const selector of ["[data-refresh-agent-prs]", "[data-refresh-all-pr-diffs]", "[data-refresh-pr-diff]", "[data-remove-pr-diff]", '.pr-diff-add-form button[type="submit"]']) await preserved(selector);
      await page.locator("[data-toggle-pr-diff-full-view]").press("Enter");
      assert.equal(await page.locator("[data-toggle-pr-diff-full-view]").innerText(), "Exit full view");
      await page.evaluate(async () => refresh({ force: true }));
      assert.equal(await page.locator("[data-toggle-pr-diff-full-view]").innerText(), "Exit full view");
      await capture(`${preference}-pr-full-view`);
      await page.locator("[data-toggle-pr-diff-full-view]").press("Enter");
      await capture(`${preference}-pr-diff`);
      assert(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth), "No horizontal overflow");
    }
    assert.deepEqual(errors, []);
    await context.close();
  }
  if (captureDir) fs.writeFileSync(path.join(captureDir, "utility-borders-results.json"), JSON.stringify(results, null, 2));
  console.log("utility-borders-smoke: desktop/mobile Dark/Nord Light/System, Tab, state cues, clipboard, summary navigation, PR view, polling, and protected borders passed");
};
