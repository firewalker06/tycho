const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");

module.exports = async ({ browser, baseUrl, captureDir }) => {
  await require("./schedules_page_smoke")({ browser, baseUrl, captureDir });
  const results = [];
  for (const theme of ["dark", "light"]) {
    const context = await browser.newContext({ viewport: { width: 390, height: 844 }, hasTouch: true, reducedMotion: "reduce" });
    const page = await context.newPage();
    const errors = [];
    page.on("pageerror", error => errors.push(error.message));
    const frames = () => page.evaluate(() => new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve))));
    await page.goto(`${baseUrl}/ui#schedules`, { waitUntil: "networkidle" });
    await page.evaluate(theme => window.TychoAppearance.setPreference(theme), theme);
    const create = page.locator(".app-header").getByRole("button", { name: "New schedule", exact: true });
    const menu = page.locator("#header-more-button");
    const capture = async name => {
      if (!captureDir) return;
      fs.mkdirSync(captureDir, { recursive: true });
      await page.screenshot({ path: path.join(captureDir, `schedule-header-${theme}-${name}.png`) });
    };
    const geometry = () => page.evaluate(() => {
      const rect = selector => document.querySelector(selector).getBoundingClientRect().toJSON();
      const label = document.querySelector(".schedule-create-label");
      return { header: rect(".app-header"), row: rect(".header-row"), identity: rect(".header-row > .identity"), title: rect("#screen-title"), subtitle: rect("#screen-subtitle"), create: rect(".schedule-create-button"), more: rect("#header-more-button"), label: label.getBoundingClientRect().toJSON(), labelClip: getComputedStyle(label).clipPath, titleWhiteSpace: getComputedStyle(document.querySelector("#screen-title")).whiteSpace, subtitleWhiteSpace: getComputedStyle(document.querySelector("#screen-subtitle")).whiteSpace, icon: rect(".schedule-create-button .ui-icon"), overflow: document.documentElement.scrollWidth > innerWidth };
    });
    for (const [width, height] of [[320, 740], [390, 844], [844, 390], [1440, 900]]) {
      await page.setViewportSize({ width, height }); await frames();
      for (const long of [false, true]) {
        await page.evaluate(long => {
          document.querySelector("#screen-title").textContent = long ? "Schedules with a very long title that must not move the actions" : "Schedules";
          document.querySelector("#screen-subtitle").textContent = long ? "Connected to a long server name / refreshed just now with a long connection status" : "Connected / refreshed just now";
        }, long);
        await frames();
        const g = await geometry();
        assert(!g.overflow, JSON.stringify(g));
        assert(g.create.width >= 44 && g.create.height >= 44 && g.more.width >= 44 && g.more.height >= 44);
        assert(g.create.right <= g.more.x && g.more.right <= width - 7, JSON.stringify(g));
        assert(Math.abs(g.create.y + g.create.height / 2 - g.more.y - g.more.height / 2) < 2, "plus and menu must share a row: " + JSON.stringify(g));
        assert(g.title.right <= g.create.x && g.subtitle.right <= g.create.x, JSON.stringify(g));
        if (width < 1100) {
          assert.equal(g.create.width, g.create.height, "mobile plus is square");
          assert.equal(g.icon.width, 24);
          assert(g.label.width <= 1 && g.labelClip === "inset(50%)");
          assert.equal(g.titleWhiteSpace, "nowrap"); assert.equal(g.subtitleWhiteSpace, "nowrap");
          assert(g.row.height < 90, JSON.stringify(g));
        } else {
          assert(g.label.width > 30 && g.labelClip === "none", "desktop label remains");
        }
        results.push({ theme, width, height, long, geometry: g });
        await capture(`${width}-${height}-${long ? "long" : "normal"}`);
      }
      await create.focus();
      await page.evaluate(() => refresh({ force: true })); await frames();
      assert(await create.evaluate(el => document.activeElement === el), "polling lost create focus");
      await page.keyboard.press("Tab");
      assert(await menu.evaluate(el => document.activeElement === el), "context menu follows plus in keyboard order");
      await page.keyboard.press("Enter");
      await page.locator("#header-more-panel [data-open-settings]").waitFor({ state: "visible" });
      const bounds = await page.locator("#header-more-panel").boundingBox();
      assert(bounds.x >= -1 && bounds.x + bounds.width <= width + 1 && bounds.y + bounds.height <= height + 1, JSON.stringify(bounds));
      await capture(`${width}-${height}-menu`);
      await page.keyboard.press("Escape");
      await page.waitForFunction(() => document.activeElement === document.querySelector("#header-more-button"));
      assert.equal(await menu.getAttribute("aria-expanded"), "false");
      await page.keyboard.press("Shift+Tab");
      assert(await create.evaluate(el => document.activeElement === el));
      const focus = await create.evaluate(el => ({ visible: el.matches(":focus-visible"), style: getComputedStyle(el).outlineStyle, width: getComputedStyle(el).outlineWidth }));
      assert(focus.visible && focus.style === "solid" && parseFloat(focus.width) >= 2);
      await page.keyboard.press("Enter");
      await page.locator("#schedule-form").waitFor({ state: "visible" });
      await capture(`${width}-${height}-create`);
      await page.locator("[data-cancel-schedule-form]").click();
      await create.waitFor({ state: "visible" });
      if (width < 1100) await create.tap(); else await create.click();
      await page.locator("#schedule-form").waitFor({ state: "visible" });
      await page.locator("[data-cancel-schedule-form]").click();
      await create.waitFor({ state: "visible" }); await frames();
      const after = await geometry();
      assert(Math.abs(after.create.y + after.create.height / 2 - after.more.y - after.more.height / 2) < 2, "return from creation kept the inline row");
    }
    assert.deepEqual(errors, []);
    await context.close();
  }
  if (captureDir) fs.writeFileSync(path.join(captureDir, "schedule-header-results.json"), JSON.stringify(results, null, 2));
  console.log("schedule_header_smoke: ok (320/390/844 landscape/1440, Dark/Light, inline square plus, accessible name, long title/status, keyboard/touch create opening, context menu, polling, desktop label)");
};
