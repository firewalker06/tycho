const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");

module.exports = async ({ browser, baseUrl, agentKey, captureDir }) => {
  const results = [];
  for (const theme of ["dark", "light"]) {
    const context = await browser.newContext({ viewport: { width: 390, height: 844 }, hasTouch: true, reducedMotion: "reduce" });
    const page = await context.newPage();
    const errors = [];
    page.on("pageerror", error => errors.push(error.message));
    const frames = () => page.evaluate(() => new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve))));
    await page.goto(`${baseUrl}/ui#now`, { waitUntil: "networkidle" });
    await page.evaluate(theme => window.TychoAppearance.setPreference(theme), theme);
    const nav = page.getByRole("navigation", { name: "Primary navigation" });
    const capture = async name => {
      if (!captureDir) return;
      fs.mkdirSync(captureDir, { recursive: true });
      await page.screenshot({ path: path.join(captureDir, `mobile-nav-${theme}-${name}.png`), mask: [page.getByText("PRIVATE_PROMPT_SENTINEL", { exact: true })] });
    };
    for (const [width, height] of [[320, 740], [390, 844], [844, 390], [1024, 768], [1440, 900]]) {
      await page.setViewportSize({ width, height }); await frames();
      for (const [tab, name] of [["now", "Now"], ["agents", "Agents"], ["schedules", "Schedules"]]) {
        const button = nav.getByRole("button", { name, exact: true });
        if (width < 1100) await button.tap(); else await button.click();
        await page.waitForFunction(tab => parseRoute().type === "tab" && parseRoute().tab === tab, tab);
        await frames();
        const geometry = await nav.evaluate(el => ({
          rect: el.getBoundingClientRect().toJSON(), padding: parseFloat(getComputedStyle(el).paddingBottom),
          buttons: [...el.querySelectorAll("button")].map(button => ({
            name: button.getAttribute("aria-label"), selected: button.getAttribute("aria-current"), active: button.classList.contains("active"),
            rect: button.getBoundingClientRect().toJSON(), icon: button.querySelector("svg").getBoundingClientRect().toJSON(),
            label: button.querySelector(".nav-label").getBoundingClientRect().toJSON(), clip: getComputedStyle(button.querySelector(".nav-label")).clipPath,
            background: getComputedStyle(button).backgroundColor, color: getComputedStyle(button).color,
          })),
          contentPadding: parseFloat(getComputedStyle(document.querySelector("#view")).paddingBottom),
        }));
        assert.equal(geometry.buttons.length, 3);
        assert.equal(geometry.buttons.filter(b => b.selected === "page" && b.active).length, 1);
        assert.equal(geometry.buttons.find(b => b.selected === "page").name, name);
        const selected = geometry.buttons.find(b => b.selected === "page"), other = geometry.buttons.find(b => b.selected !== "page");
        assert.notEqual(selected.background, other.background);
        assert.notEqual(selected.color, other.color);
        assert(geometry.rect.x >= -1 && geometry.rect.right <= width + 1);
        for (const b of geometry.buttons) {
          assert(b.rect.width >= 44 && b.rect.height >= 44, JSON.stringify(b));
          assert(b.icon.x >= b.rect.x && b.icon.right <= b.rect.right && b.icon.y >= b.rect.y && b.icon.bottom <= b.rect.bottom);
          if (width < 1100) {
            assert.equal(b.icon.width, 28); assert.equal(b.icon.height, 28);
            assert(b.label.width <= 1 && b.label.height <= 1 && b.clip === "inset(50%)", JSON.stringify(b));
          } else {
            assert(b.label.width > 10 && b.clip === "none", JSON.stringify(b));
            assert.equal(b.icon.width, 16);
          }
        }
        if (width < 1100) {
          assert(Math.abs(geometry.rect.bottom - height) < 2, JSON.stringify(geometry));
          assert(geometry.padding >= 8, "bottom safe-area padding must remain");
          assert(geometry.contentPadding >= geometry.rect.height, JSON.stringify(geometry));
          await page.evaluate(() => { window.scrollTo(0, document.documentElement.scrollHeight); setNavHidden(false); }); await frames();
          const clearance = await page.evaluate(() => {
            const nav = document.querySelector("#bottom-nav").getBoundingClientRect();
            const last = document.querySelector("#view").lastElementChild?.getBoundingClientRect();
            return { scrollable: document.documentElement.scrollHeight > innerHeight + 2, lastBottom: last?.bottom, navTop: nav.top };
          });
          if (clearance.scrollable) assert(clearance.lastBottom <= clearance.navTop + 2, JSON.stringify(clearance));
          await page.evaluate(() => window.scrollTo(0, 0)); await frames();
        }
        await capture(`${width}-${height}-${tab}`);
        await page.evaluate(() => refresh({ force: true })); await frames();
        assert.equal(await button.getAttribute("aria-current"), "page", "polling changed the selected destination");
        assert(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth));
        results.push({ theme, width, height, tab, geometry });
      }
      // Native keyboard navigation retains visible focus and activation.
      await page.keyboard.press("Tab");
      await nav.getByRole("button", { name: "Now", exact: true }).focus();
      await page.keyboard.press("Tab");
      const agents = nav.getByRole("button", { name: "Agents", exact: true });
      const focus = await agents.evaluate(el => ({ focused: document.activeElement === el, visible: el.matches(":focus-visible"), outline: getComputedStyle(el).outlineStyle, width: getComputedStyle(el).outlineWidth }));
      assert(focus.focused && focus.visible && focus.outline === "solid" && parseFloat(focus.width) >= 2, JSON.stringify(focus));
      await capture(`${width}-${height}-keyboard`);
      await page.keyboard.press("Enter"); await frames();
      assert.equal(await agents.getAttribute("aria-current"), "page");

      // Conversation routes retain their existing hidden mobile nav and clear dock.
      await page.goto(`${baseUrl}/ui#agent/${agentKey}`, { waitUntil: "networkidle" });
      await page.locator("#prompt-input").waitFor(); await frames();
      const clearance = await page.evaluate(() => {
        const nav = document.querySelector("#bottom-nav"), n = nav.getBoundingClientRect();
        const dock = document.querySelector("[data-agent-dock]").getBoundingClientRect();
        const visible = getComputedStyle(nav).display !== "none" && n.width > 0 && n.height > 0;
        return { visible, nav: n.toJSON(), dock: dock.toJSON(), overflow: document.documentElement.scrollWidth > innerWidth };
      });
      assert(!clearance.overflow && clearance.dock.bottom <= height + 1 && clearance.dock.right <= width + 1);
      if (width < 1100) assert(!clearance.visible, JSON.stringify(clearance));
      else assert(clearance.nav.right <= clearance.dock.x + 1, JSON.stringify(clearance));
      results.push({ theme, width, height, state: "composer clearance", clearance });
      await page.goto(`${baseUrl}/ui#now`, { waitUntil: "networkidle" });
    }
    assert.deepEqual(errors, []);
    await context.close();
  }
  if (captureDir) fs.writeFileSync(path.join(captureDir, "mobile-navigation-results.json"), JSON.stringify(results, null, 2));
  console.log("mobile_navigation_smoke: ok (Now/Agents/Schedules, 320/390/844 landscape/1024/1440, Dark/Light, 28px icons, accessible names, labels, selected states, touch/keyboard, polling, content/composer clearance)");
};
