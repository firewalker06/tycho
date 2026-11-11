const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");

module.exports = async ({ browser, baseUrl, captureDir }) => {
  for (const width of [1440, 390]) for (const theme of ["dark", "light"]) {
    const context = await browser.newContext({ viewport: { width, height: 900 }, isMobile: width < 500, hasTouch: width < 500 });
    const page = await context.newPage();
    const errors = [];
    page.on("pageerror", error => errors.push(error.message));
    await page.addInitScript(() => { document.hasFocus = () => true; });
    try {
      await page.goto(`${baseUrl}/ui#settings`, { waitUntil: "networkidle" });
      await page.locator("[data-appearance-preference]").selectOption(theme);
      await page.locator('[data-tab="schedules"]').click();
      await page.locator("#schedule-empty-title").waitFor();
      assert(await page.getByText("Create a schedule to add it to this list.", { exact: false }).isVisible());
      const capture = async name => {
        await page.waitForTimeout(300);
        await page.waitForFunction(() => {
          const nav = document.querySelector("#bottom-nav").getBoundingClientRect();
          return nav.left >= -1 && nav.right <= innerWidth + 1;
        });
        assert(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth), "no horizontal overflow");
        if (captureDir) {
          fs.mkdirSync(captureDir, { recursive: true });
          await page.screenshot({ path: path.join(captureDir, `schedule-${name}-${theme}-${width}.png`) });
        }
      };
      await capture("empty");
      const settings = page.locator(".sidebar-settings-link");
      if (width >= 1100) {
        const box = await settings.boundingBox();
        assert(box.y + box.height >= 876 && box.y + box.height <= 892, "Settings stays at the bottom");
        assert.equal(await settings.locator("circle").getAttribute("r"), "3", "Settings gear stays intact");
      } else assert.equal(await settings.isVisible(), false);
      await page.getByRole("button", { name: "Create schedule", exact: true }).focus();
      await page.keyboard.press("Enter");
      await page.locator("#schedule-form").waitFor();
      await capture("create");
      const key = `first-${width}-${theme}`;
      await page.locator("#schedule-key").fill(key);
      await page.locator("#schedule-name").fill("First schedule");
      await page.locator("#schedule-message").fill("Synthetic empty-state check.");
      await page.locator("#schedule-form button[type=submit]").click();
      await page.locator(".schedule-row").waitFor();
      assert.equal(await page.locator("#schedule-empty-title").count(), 0);
      await capture("list");
      // The full collection decides emptiness even when no rows match a view.
      await page.evaluate(() => {
        window.originalScheduleSectionRows = scheduleSectionRows;
        scheduleSectionRows = () => [];
        render();
      });
      assert(await page.getByText("No matching schedules", { exact: true }).isVisible());
      assert.equal(await page.locator("#schedule-empty-title").count(), 0);
      await page.evaluate(() => { scheduleSectionRows = originalScheduleSectionRows; render(); });
      await page.locator(".schedule-row .schedule-action-menu summary").click();
      await page.locator("[data-delete-schedule]").click();
      await page.locator("[data-confirmation-accept]").click();
      await page.locator("#schedule-empty-title").waitFor();
      await page.waitForFunction(() => !state.refreshInFlight && state.pendingFormKeys.size === 0);
      await page.reload({ waitUntil: "networkidle" });
      await page.locator("#schedule-empty-title").waitFor();
      await page.route(`${baseUrl}/schedules`, route => route.fulfill({ status: 503, contentType: "application/json", body: '{"error":"Synthetic connection failure"}' }));
      await page.evaluate(() => refresh({ force: true }));
      assert(await page.getByText("Schedules unavailable", { exact: true }).isVisible());
      assert.equal(await page.locator("#schedule-empty-title").count(), 0);
      await capture("error");
      await page.unroute(`${baseUrl}/schedules`);
      await page.evaluate(() => refresh({ force: true }));
      await page.locator("#schedule-empty-title").waitFor();
      let release;
      const held = new Promise(resolve => { release = resolve; });
      await page.route(`${baseUrl}/schedules`, async route => { await held; await route.continue(); });
      await page.evaluate(() => { state.schedulesLoaded = false; state.schedules = []; render(); void refresh({ force: true }); });
      assert(await page.locator(".card-title strong").filter({ hasText: "Loading schedules…" }).isVisible());
      assert.equal(await page.locator("#schedule-empty-title").count(), 0);
      release();
      await page.waitForFunction(() => !state.refreshInFlight);
      await page.locator("#schedule-empty-title").waitFor();
      await page.unroute(`${baseUrl}/schedules`);
      assert.deepEqual(errors, []);
      console.log(`schedule_empty_smoke: ok ${width} ${theme}`);
    } finally { await context.close(); }
  }
};
