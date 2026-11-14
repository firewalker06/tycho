const assert = require("node:assert/strict");
const path = require("node:path");

function contrast(first, second) {
  const luminance = rgb => rgb.map(value => value / 255)
    .map(value => value <= 0.04045 ? value / 12.92 : ((value + 0.055) / 1.055) ** 2.4)
    .reduce((sum, value, index) => sum + value * [0.2126, 0.7152, 0.0722][index], 0);
  const a = luminance(first);
  const b = luminance(second);
  return (Math.max(a, b) + 0.05) / (Math.min(a, b) + 0.05);
}

module.exports = async ({ browser, baseUrl, agentKey, captureDir }) => {
  for (const width of [1440, 1180, 1100, 1099, 390]) for (const theme of ["dark", "light"]) {
    const desktop = width >= 1100;
    const context = await browser.newContext({ viewport: { width, height: 900 }, hasTouch: width <= 1180 });
    const page = await context.newPage();
    const errors = [];
    page.on("pageerror", error => errors.push(error.message));
    await page.addInitScript(() => { document.hasFocus = () => true; });
    await page.goto(`${baseUrl}/ui#agent/${agentKey}`, { waitUntil: "networkidle" });
    await page.locator("#prompt-input").waitFor();
    await page.evaluate(theme => window.TychoAppearance.setPreference(theme), theme);
    const preferences = await page.evaluate(() => JSON.stringify(localStorage));
    const nav = page.locator("#bottom-nav");
    const railWidth = async expected => {
      await page.waitForFunction(expected => Math.round(document.querySelector("#bottom-nav").getBoundingClientRect().width) === expected, expected);
      assert.equal(Math.round((await nav.boundingBox()).width), expected);
      assert.equal(await nav.evaluate(node => getComputedStyle(node).borderTopWidth), "0px");
    };
    if (desktop) await railWidth(144);
    // Use the UI's canonical destinations rather than duplicating their URL format.
    const summary = await page.locator("[data-open-agent-summary]").first().getAttribute("data-open-agent-summary");
    assert(summary !== null);
    await page.locator("[data-open-agent-summary]").first().click();
    await page.locator(".agent-workspace.has-detail").waitFor();
    const summaryUrl = page.url();
    if (desktop) {
      for (const mode of ["wide", "full", "balanced"]) {
        await page.locator("#header-view-menu [data-focused-view-menu] > summary").click();
        await page.locator(`#header-view-menu [data-view-mode="${mode}"]`).click();
        await page.evaluate(() => refresh({ force: true }));
        assert.equal(await page.locator("#header-view-menu [data-focused-view-menu]").getAttribute("data-active-view-mode"), mode, "manual layout survives refresh");
        await railWidth(56);
      }
    }
    const assertSplit = async () => {
      assert(await page.locator("#view").evaluate(node => node.classList.contains("agent-split-active")));
      if (desktop) {
        await railWidth(56);
        for (const label of ["Now", "Agents", "Schedules"]) {
          const button = nav.getByRole("button", { name: label, exact: true });
          assert(await button.isVisible());
          assert.equal(await button.getAttribute("title"), label);
          assert.equal(await button.locator("span").last().evaluate(node => node.getBoundingClientRect().width), 1);
          await button.focus();
          assert(await button.evaluate(node => node === document.activeElement));
          assert(parseFloat(await button.evaluate(node => getComputedStyle(node).outlineWidth)) >= 2);
        }
        assert.equal(await nav.locator('[aria-current="page"]').getAttribute("data-tab"), "agents");
        const selection = await nav.locator("button.active").evaluate(node => {
          const style = getComputedStyle(node);
          const probe = document.createElement("span");
          probe.style.cssText = "background: var(--accent-soft); color: var(--accent)";
          node.append(probe);
          const expected = getComputedStyle(probe);
          const rgb = color => {
            const canvas = document.createElement("canvas");
            canvas.width = canvas.height = 1;
            const context = canvas.getContext("2d");
            context.fillStyle = color;
            context.fillRect(0, 0, 1, 1);
            return [...context.getImageData(0, 0, 1, 1).data].slice(0, 3);
          };
          const root = getComputedStyle(document.documentElement);
          const result = { shadow: style.boxShadow, border: style.borderLeftWidth,
            otherBorder: style.borderRightWidth, borderColor: style.borderLeftColor, otherBorderColor: style.borderRightColor,
            background: style.backgroundColor, color: style.color,
            backgroundRgb: rgb(style.backgroundColor), colorRgb: rgb(style.color),
            canvasRgb: rgb(root.getPropertyValue("--ds-background-canvas")),
            focusRgb: rgb(root.getPropertyValue("--ds-focus-ring")),
            expectedBackground: expected.backgroundColor, expectedColor: expected.color };
          probe.remove();
          return result;
        });
        assert.equal(selection.shadow, "none", "selected icon has no bold left shadow");
        assert.equal(selection.border, selection.otherBorder, "selected icon has no thicker left border");
        assert.equal(selection.borderColor, selection.otherBorderColor, "selected icon has no separate left border color");
        assert.equal(selection.background, selection.expectedBackground, "selected background is preserved");
        assert.equal(selection.color, selection.expectedColor, "selected color is preserved");
        if (theme === "light") {
          assert(contrast(selection.backgroundRgb, selection.canvasRgb) >= 1.15, "Light selected fill is visibly distinct from canvas");
          assert(contrast(selection.colorRgb, selection.backgroundRgb) >= 4.5, "selected foreground stays readable");
          assert(contrast(selection.focusRgb, selection.backgroundRgb) >= 3, "focus ring contrasts with selected fill");
        }
        const settings = page.getByRole("link", { name: "Settings", exact: true });
        assert(await settings.isVisible());
        assert.equal(await settings.getAttribute("title"), "Settings");
        const box = await settings.boundingBox();
        assert(box.width >= 44 && box.x + box.width < 100);
      } else {
        assert.equal(await nav.isVisible(), false, "mobile split navigation stays unchanged");
        assert.equal(await page.locator(".sidebar-settings-link").isVisible(), false);
      }
    };
    await assertSplit();
    await page.evaluate(() => refresh({ force: true }));
    await page.evaluate(() => render({ preservePollContent: true }));
    await assertSplit();
    for (const type of ["agentAttachment", "agentPullRequests", "agentSummary"]) {
      await page.evaluate(({ type, key }) => navigate({ type, key }), { type, key: agentKey });
      await page.locator(".agent-workspace.has-detail").waitFor();
      await assertSplit();
    }
    await page.evaluate(key => navigate({ type: "projectDiff", key: "web", scope: "working", backTo: { type: "agent", key } }), agentKey);
    await page.locator("#view.agent-split-diff").waitFor();
    await assertSplit();
    await page.goto(summaryUrl, { waitUntil: "networkidle" });
    await page.locator(".agent-workspace.has-detail").waitFor();
    await page.reload({ waitUntil: "networkidle" });
    await page.locator(".agent-workspace.has-detail").waitFor();
    await assertSplit();
    if (desktop && theme === "light") {
      const selected = nav.getByRole("button", { name: "Agents", exact: true });
      const other = nav.getByRole("button", { name: "Now", exact: true });
      const fill = await selected.evaluate(node => getComputedStyle(node).backgroundColor);
      await selected.hover();
      assert.equal(await selected.evaluate(node => getComputedStyle(node).backgroundColor), fill, "selected hover keeps its fill");
      if (captureDir) await page.screenshot({ path: path.join(captureDir, `sidebar-${width}-light-selected-hover.png`) });
      await other.hover();
      assert.notEqual(await other.evaluate(node => getComputedStyle(node).backgroundColor), fill, "unselected hover stays distinct from selection");
      if (captureDir) await page.screenshot({ path: path.join(captureDir, `sidebar-${width}-light-unselected-hover.png`) });
      await page.keyboard.press("Tab");
      await selected.focus();
      const focus = await selected.evaluate(node => ({ visible: node.matches(":focus-visible"),
        width: getComputedStyle(node).outlineWidth, style: getComputedStyle(node).outlineStyle,
        background: getComputedStyle(node).backgroundColor, current: node.getAttribute("aria-current") }));
      assert(focus.visible && parseFloat(focus.width) >= 2 && focus.style === "solid");
      assert.equal(focus.background, fill, "keyboard focus keeps selected fill");
      assert.equal(focus.current, "page");
      if (captureDir) await page.screenshot({ path: path.join(captureDir, `sidebar-${width}-light-selected-focus.png`) });
      await page.mouse.move(0, 0);
      console.log(`Light selection hover/focus: ${width}px passed`);
    }
    if (captureDir && [1440, 1180, 390].includes(width)) {
      await page.locator("#prompt-input").focus();
      await page.screenshot({ path: path.join(captureDir, `sidebar-${width}-${theme}.png`) });
    }
    if (desktop) {
      await nav.getByRole("button", { name: "Now", exact: true }).click();
      await page.waitForURL("**/ui#now");
      await railWidth(144);
      await nav.getByRole("button", { name: "Schedules", exact: true }).click();
      await page.waitForURL("**/ui#schedules");
      await railWidth(144);
      await page.getByRole("link", { name: "Settings", exact: true }).click();
      await page.waitForURL("**/ui#settings");
      await page.locator('.sidebar-settings-link[aria-current="page"]').waitFor();
      await page.goto(summaryUrl, { waitUntil: "networkidle" });
      await page.locator(".agent-workspace.has-detail").waitFor();
      await assertSplit();
      await page.setViewportSize({ width: 1099, height: 900 });
      assert.equal(await nav.isVisible(), false);
      await page.setViewportSize({ width, height: 900 });
      await assertSplit();
    }
    await page.goto(`${baseUrl}/ui#agent/${agentKey}`, { waitUntil: "networkidle" });
    await page.locator("#prompt-input").waitFor();
    if (desktop) await railWidth(144);
    assert.equal(await page.evaluate(() => JSON.stringify(localStorage)), preferences, "split transitions do not write preferences");
    assert.deepEqual(errors, []);
    await context.close();
    console.log(`sidebar rail: ${width}px ${theme} passed`);
  }
};
