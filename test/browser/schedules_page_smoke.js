const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");

module.exports = async ({ browser, baseUrl, captureDir }) => {
  for (const width of [1440, 390]) for (const theme of ["dark", "light", "system"]) {
    const context = await browser.newContext({ viewport: { width, height: 900 }, isMobile: width < 500, hasTouch: width < 500 });
    const page = await context.newPage();
    const errors = [];
    page.on("pageerror", error => errors.push(error.message));
    await page.addInitScript(() => { document.hasFocus = () => true; });
    try {
      await page.goto(`${baseUrl}/ui#settings`, { waitUntil: "networkidle" });
      await page.locator("[data-appearance-preference]").selectOption(theme);
      await page.goto(`${baseUrl}/ui#schedules`, { waitUntil: "networkidle" });
      await page.locator(".schedule-row").first().waitFor();
      assert.deepEqual(await page.locator("#bottom-nav button").allTextContents().then(items => items.map(x => x.trim())), ["Now", "Agents", "Schedules"]);
      assert.equal(await page.locator('#bottom-nav [aria-current="page"]').getAttribute("data-tab"), "schedules");
      assert.equal(await page.locator(".schedule-card details.schedule-details").count(), 0);
      assert.equal(await page.locator(".schedule-card summary.schedule-summary-row").count(), 0);
      assert(await page.locator("[data-new-schedule]").isVisible());
      const link = page.locator(".sidebar-settings-link");
      assert.equal(await link.isVisible(), width >= 1100);
      assert.equal(await page.locator("#bottom-nav .sidebar-settings-link").count(), 0);
      if (width >= 1100) {
        const nav = await page.locator("#bottom-nav").boundingBox();
        const settings = await link.boundingBox();
        assert(settings.y >= nav.y + nav.height, "Settings link is below the navigation panel");
        await link.click();
      } else {
        await page.locator("#header-more-button").click();
        await page.locator("#header-more-panel [data-open-settings]").click();
      }
      await page.waitForURL("**/ui#settings");
      await page.locator('[data-tab="schedules"]').click();
      await page.waitForURL("**/ui#schedules");
      await page.reload({ waitUntil: "networkidle" });
      await page.locator(".schedule-row").first().waitFor();
      await page.evaluate(() => refresh({ force: true }));
      assert(await page.locator(".schedule-row").first().isVisible());
      const pause = page.locator('.schedule-row [data-schedule-key="smoke"][data-schedule-action="pause"]');
      if (await pause.count()) {
        await pause.click();
        await page.locator('.schedule-row [data-schedule-key="smoke"][data-schedule-action="resume"]').waitFor();
      }
      await page.locator('.schedule-row [data-schedule-key="smoke"][data-schedule-action="resume"]').click();
      await page.locator('.schedule-row [data-schedule-key="smoke"][data-schedule-action="pause"]').waitFor();
      const menu = page.locator('.schedule-action-menu[data-overlay-key="schedule:smoke"]');
      await menu.locator("summary").click();
      for (const selector of ['[data-schedule-action="run"]', '[data-schedule-action="refresh-session"]', '[data-delete-schedule]']) assert(await menu.locator(selector).isVisible());
      await menu.locator('[data-edit-schedule="smoke"]').click();
      await page.locator("#schedule-form").waitFor();
      await page.locator("[data-cancel-schedule-form]").click();
      await page.waitForURL("**/ui#schedules");
      await page.locator("[data-new-schedule]").click();
      await page.locator("#schedule-form").waitFor();
      await page.locator("#back-button").click();
      await page.waitForURL("**/ui#schedules");
      await page.waitForFunction(() => {
        const header = document.querySelector(".app-header").getBoundingClientRect();
        return header.left >= -1 && header.right <= innerWidth + 1;
      });
      assert(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth), "no horizontal overflow");
      if (captureDir) {
        fs.mkdirSync(captureDir, { recursive: true });
        await page.screenshot({ path: path.join(captureDir, `schedules-page-${theme}-${width}.png`) });
      }
      await page.locator('[data-tab="now"]').click();
      await page.waitForURL("**/ui#now");
      await page.waitForFunction(() => document.body.dataset.routeTab === "now" && !document.querySelector(".schedule-card"));
      assert.equal(await page.locator(".schedule-card").count(), 0, "Now has no schedule list");
      assert.deepEqual(errors, []);
    } finally { await context.close(); }
  }
  console.log("schedules_page_smoke: ok (direct access, desktop/mobile Dark/Light/System navigation, Settings, polling, pause/resume, forms, actions, layout)");
};
