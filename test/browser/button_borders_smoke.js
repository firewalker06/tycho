const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");

module.exports = async ({ browser, baseUrl, agentKey, captureDir }) => {
  const results = [];
  const capture = async (page, name) => {
    if (captureDir) await page.screenshot({ path: path.join(captureDir, `${name}.png`), mask: [page.getByText("PRIVATE_PROMPT_SENTINEL", { exact: true })] });
  };
  for (const [device, viewport] of Object.entries({ desktop: { width: 1440, height: 1000 }, mobile: { width: 390, height: 844 } })) {
    const context = await browser.newContext({ viewport, hasTouch: device === "mobile", colorScheme: "light", reducedMotion: "reduce" });
    const page = await context.newPage();
    const settle = async control => control.evaluate(async element => {
      await Promise.all(element.getAnimations().filter(animation => Number.isFinite(animation.effect.getComputedTiming().endTime)).map(animation => animation.finished.catch(() => {})));
    });
    const errors = [];
    page.on("pageerror", error => errors.push(error.message));
    await page.goto(`${baseUrl}/ui#agent/${agentKey}`, { waitUntil: "networkidle" });
    await page.locator("#prompt-input").waitFor();
    const selectors = ["#back-button", ".summary-attachment-trigger", ".agent-floating-pill[data-open-agent-summary]", ".agent-floating-pill[data-open-agent-pr-diffs]"];
    for (const preference of ["dark", "light", "system"]) {
      await page.evaluate(preference => window.TychoAppearance.setPreference(preference), preference);
      if (preference === "system") {
        await page.emulateMedia({ colorScheme: "dark" });
        await page.waitForFunction(() => document.documentElement.dataset.appearance === "dark");
        await page.emulateMedia({ colorScheme: "light" });
        await page.waitForFunction(() => document.documentElement.dataset.appearance === "light");
      }
      assert.equal(await page.locator("html").getAttribute("data-appearance"), preference === "dark" ? "dark" : "light");
      const controls = [];
      for (const selector of selectors) {
        const locator = page.locator(selector);
        assert(await locator.count() > 0, `${selector} exists`);
        for (const control of await locator.all()) {
          if (!await control.isVisible()) continue;
          const before = await control.boundingBox();
          const border = await control.evaluate(element => getComputedStyle(element).borderTopColor);
          assert.equal(border, "rgba(0, 0, 0, 0)", `${selector} has no decorative border`);
          await page.keyboard.press("Tab");
          await control.focus();
          const focus = await control.evaluate(element => ({ visible: element.matches(":focus-visible"), width: getComputedStyle(element).outlineWidth, style: getComputedStyle(element).outlineStyle }));
          assert(focus.visible && parseFloat(focus.width) >= 2 && focus.style === "solid", `${selector} keeps keyboard focus`);
          if (selector === "#back-button") await capture(page, `${device}-${preference}-keyboard-focus`);
          await control.hover();
          await settle(control);
          const hover = await control.evaluate(element => getComputedStyle(element).backgroundColor);
          await page.mouse.move(0, 0);
          await settle(control);
          const normal = await control.evaluate(element => getComputedStyle(element).backgroundColor);
          await control.hover();
          await page.mouse.down();
          await settle(control);
          const pressed = await control.evaluate(element => getComputedStyle(element).backgroundColor);
          // Release outside the target so this state check does not activate navigation.
          await page.mouse.move(0, 0);
          await page.mouse.up();
          assert.notEqual(pressed, normal, `${selector} has pressed feedback`);
          await control.evaluate(element => { element.disabled = true; });
          assert(!await control.isEnabled(), "disabled controls cannot activate");
          await control.evaluate(element => { element.disabled = false; });
          assert.notEqual(hover, normal, `${selector} has hover feedback`);
          const after = await control.boundingBox();
          assert.equal(after.width, before.width, "focus and hover preserve width");
          assert.equal(after.height, before.height, "focus and hover preserve height");
          assert(before.width >= 38 && before.height >= 38, "control keeps its hit area");
          controls.push({ selector, border, focus, width: before.width, height: before.height });
        }
      }
      await page.locator("#prompt-input").fill("Keep this draft through polling.");
      await page.evaluate(() => refresh({ force: true }));
      assert.equal(await page.locator("#prompt-input").inputValue(), "Keep this draft through polling.");
      assert(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth), "no horizontal overflow");
      await page.locator("#prompt-input").blur();
      await capture(page, `${device}-${preference}-conversation`);
      const trigger = page.getByRole("button", { name: "Show delegated actions (5)", exact: true });
      await trigger.focus();
      await page.keyboard.press("Enter");
      await page.getByRole("region", { name: "Summary delegated actions", exact: true }).waitFor({ state: "visible" });
      assert.equal(await trigger.getAttribute("aria-expanded"), "true");
      await capture(page, `${device}-${preference}-agents-open`);
      await page.keyboard.press("Escape");
      assert.equal(await trigger.getAttribute("aria-expanded"), "false");
      const attachments = page.getByRole("button", { name: "Choose summary attachment", exact: true }).first();
      if (device === "mobile") await attachments.tap(); else await attachments.click();
      assert.equal(await attachments.getAttribute("aria-expanded"), "true");
      await page.keyboard.press("Escape");
      await page.locator(".agent-floating-pill[data-open-agent-summary]").click();
      await page.locator(".agent-summary-viewer").waitFor();
      await capture(page, `${device}-${preference}-summary`);
      await page.locator(device === "desktop" ? "#header-detail-close" : "#back-button").click();
      await page.locator(".agent-floating-pill[data-open-agent-pr-diffs]").click();
      await page.locator(".agent-pr-diff-shell").waitFor();
      await capture(page, `${device}-${preference}-pr-diffs`);
      await page.locator(device === "desktop" ? "#header-detail-close" : "#back-button").click();
      await page.waitForFunction(() => parseRoute().type === "agent" && !document.body.dataset.routeLoading);
      await page.locator(".agent-workspace.conversation-only").waitFor();
      // Set only browser memory to render the running state; no harness is started.
      await page.evaluate(key => { findAgent(key).running = true; render(); }, agentKey);
      const stop = page.locator(".stop-fab");
      await stop.waitFor({ state: "visible" });
      const stopStyle = await stop.evaluate(element => ({ border: getComputedStyle(element).borderTop, width: getComputedStyle(element).borderTopWidth, color: getComputedStyle(element).borderTopColor, html: element.outerHTML }));
      assert(parseFloat(stopStyle.width) > 0 && stopStyle.color !== "rgba(0, 0, 0, 0)", `Stop keeps its border: ${JSON.stringify(stopStyle)}`);
      await capture(page, `${device}-${preference}-stop-preserved`);
      await page.evaluate(key => { findAgent(key).running = false; render(); }, agentKey);

      results.push({ device, preference, controls });
    }
    const audit = [];
    for (const route of ["now", "agents", "settings"]) {
      await page.goto(`${baseUrl}/ui#${route}`, { waitUntil: "networkidle" });
      const buttons = await page.locator("button, summary, a.ui-button").evaluateAll(elements => elements.filter(element => element.getClientRects().length).map(element => {
        const css = getComputedStyle(element);
        return { label: element.getAttribute("aria-label") || element.innerText.trim(), className: element.className, border: css.border, route: location.hash };
      }).filter(item => !item.border.startsWith("0px") && !item.border.includes("rgba(0, 0, 0, 0)")));
      audit.push({ route, buttons });
      await capture(page, `${device}-scan-${route}`);
    }
    if (captureDir) fs.writeFileSync(path.join(captureDir, `${device}-border-scan.json`), JSON.stringify(audit, null, 2));
    assert.deepEqual(errors, []);
    await context.close();
  }
  if (captureDir) fs.writeFileSync(path.join(captureDir, "browser-checks.json"), JSON.stringify(results, null, 2));
  console.log("button-borders-smoke: desktop/mobile Dark/Light/System, focus, hover, menu, touch, routes, polling and Stop passed");
};
