const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");

module.exports = async ({ browser, baseUrl, agentKey, captureDir }) => {
  const results = [];
  for (const width of [1440, 390]) for (const mode of ["dark", "light"]) {
    const context = await browser.newContext({ viewport: { width, height: 1000 }, reducedMotion: "reduce", serviceWorkers: "block", isMobile: width < 500, hasTouch: width < 500 });
    const page = await context.newPage();
    const errors = [];
    page.on("pageerror", error => errors.push(error.message));
    await page.addInitScript(() => { document.hasFocus = () => true; });
    const route = `${baseUrl}/ui#agent/${encodeURIComponent(agentKey)}`;
    const capture = async name => {
      if (!captureDir) return;
      fs.mkdirSync(captureDir, { recursive: true });
      await page.screenshot({ path: path.join(captureDir, `${width}-${mode}-${name}.png`) });
    };
    const layout = async () => {
      assert(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth), "no horizontal page overflow");
      for (const node of await page.locator(".app-header button:visible, .schedule-row button:visible, #prompt-input:visible").all()) {
        const box = await node.boundingBox();
        assert(box && box.x >= 0 && box.x + box.width <= width + 1, "controls fit the viewport");
      }
    };
    try {
      await page.goto(route);
      await page.locator("#prompt-input").waitFor();
      await page.waitForFunction(() => TychoBackdropImages.getState().loaded && !TychoBackdropImages.getState().busy);
      for (const backdrop of ["none", "procedural", "photo", "uploaded"]) {
        await page.evaluate(async ({ mode, backdrop }) => {
          TychoAppearance.setPreference(mode);
          const plain = mode === "dark" ? "dracula" : "nord";
          const theme = backdrop === "photo" ? (mode === "dark" ? "builtin:depok-city" : "builtin:senggigi-beach")
            : backdrop === "procedural" ? (mode === "dark" ? "builtin:aurora" : "builtin:garden") : plain;
          TychoAppearance.setTheme(mode, theme);
          if (backdrop === "uploaded") {
            const url = TychoAppearance.getThemeState().examples.find(t => t.id === "builtin:senggigi-beach").photo;
            const blob = await (await fetch(url)).blob();
            await TychoBackdropImages.choose(new File([blob], "Synthetic beach fixture.webp", { type: "image/webp" }));
          }
        }, { mode, backdrop });
        if (["photo", "uploaded"].includes(backdrop)) {
          await page.waitForFunction(kind => document.documentElement.dataset.imageBackdrop === (kind === "photo" ? "theme" : "ready") && !TychoBackdropImages.getState().busy, backdrop);
        }
        await page.goto(route);
        await page.locator("#prompt-input").waitFor();
        await page.locator(".message-group > summary").first().waitFor();
        const labels = await page.locator(".message-group-label").allTextContents();
        assert(labels.some(label => /Tool activity/i.test(label)), "Tool Activity is present");
        assert(labels.some(label => /Agent activity/i.test(label)), "Agent Activity is present");
        const facts = await page.evaluate(() => {
          const style = selector => { const s = getComputedStyle(document.querySelector(selector)); return { background: s.backgroundColor, filter: s.backdropFilter, border: s.borderTopWidth, color: s.color }; };
          return { nav: style("#bottom-nav"), settings: style(".sidebar-settings-link"), bars: [...document.querySelectorAll(".message-group > summary")].map(n => getComputedStyle(n).backgroundColor), selected: style("#bottom-nav .active"), message: style(".message.assistant"), composer: style("#prompt-input") };
        });
        assert(facts.bars.every(color => color === "rgba(0, 0, 0, 0)"), "activity bars have no backing");
        if (width >= 1100) {
          assert.equal(facts.nav.background, "rgba(0, 0, 0, 0)");
          assert.equal(facts.nav.filter, "none");
          assert.equal(facts.settings.background, "rgba(0, 0, 0, 0)");
        } else if (await page.locator("#bottom-nav").isVisible()) {
          assert.notEqual(facts.nav.background, "rgba(0, 0, 0, 0)", "mobile dock keeps its readable surface");
        }
        assert.notEqual(facts.selected.background, "rgba(0, 0, 0, 0)", "selected nav indicator remains");
        assert.notEqual(facts.message.background, "rgba(0, 0, 0, 0)", "message card remains");
        assert.notEqual(facts.composer.background, "rgba(0, 0, 0, 0)", "composer remains");
        const activity = page.locator(".message-group").first();
        await activity.locator("summary").click();
        assert(await activity.evaluate(node => node.open), "activity opens");
        await page.locator("#prompt-input").fill("Keep this unsent draft.");
        await page.evaluate(() => refresh({ force: true }));
        assert.equal(await page.locator("#prompt-input").inputValue(), "Keep this unsent draft.");
        assert(await activity.evaluate(node => node.open), "refresh preserves activity state");
        await activity.locator("summary").click();
        await layout();
        await capture(`${backdrop}-conversation`);
        if (width >= 1100) {
          await page.locator(".sidebar-settings-link").click();
          await page.locator("[data-appearance-preference]").waitFor();
          await page.goto(route);
          await page.locator("#prompt-input").waitFor();
        }
        await page.goto(`${baseUrl}/ui#schedules`);
        await page.locator(".schedule-row").first().waitFor();
        assert.equal(await page.locator(".schedule-summary-row").count(), 0, "duplicate heading and status are absent");
        assert.equal(await page.locator(".detail-card.schedule-card").count(), 0, "outer panel is absent");
        const panel = await page.locator(".schedule-card").evaluate(node => { const s = getComputedStyle(node); return { background: s.backgroundColor, border: s.borderTopWidth, shadow: s.boxShadow }; });
        assert.deepEqual(panel, { background: "rgba(0, 0, 0, 0)", border: "0px", shadow: "none" });
        assert(await page.locator(".app-header [data-new-schedule]").isVisible());
        await page.locator("#header-more-button").click();
        assert(await page.locator("#header-more-panel").isVisible());
        await page.keyboard.press("Escape");
        const row = page.locator(".schedule-row").first();
        const toggle = row.locator('[data-schedule-action="pause"], [data-schedule-action="resume"]').first();
        const action = await toggle.getAttribute("data-schedule-action");
        await toggle.click();
        await row.locator(`[data-schedule-action="${action === "pause" ? "resume" : "pause"}"]`).waitFor();
        await page.evaluate(() => refresh({ force: true }));
        assert(await row.locator(".schedule-session-button").isVisible());
        assert(await row.locator(".schedule-archive-button").isVisible());
        await row.locator(".schedule-action-menu > summary").click();
        assert(await row.locator(".schedule-action-popover").isVisible());
        await row.locator(".schedule-action-menu > summary").click();
        await layout();
        await capture(`${backdrop}-schedules`);
        results.push({ width, mode, backdrop, facts, panel });
      }
      assert.deepEqual(errors, []);
    } finally { await context.close(); }
  }
  if (captureDir) fs.writeFileSync(path.join(captureDir, "surface-checks.json"), JSON.stringify(results, null, 2));
  console.log(`Surface cleanup: ${results.length} desktop/mobile, palette, and backdrop cases passed.`);
};
