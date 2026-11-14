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
      const create = page.locator(".app-header [data-new-schedule]");
      const trigger = page.locator("#header-more-button");
      const listMenu = page.locator("#header-more-panel");
      const waitForMenuFocus = () => page.waitForFunction(() =>
        document.activeElement === document.querySelector('#header-more-panel [role="menuitem"]:not(:disabled)'));
      const openMenu = async () => {
        if (await trigger.getAttribute("aria-expanded") !== "true") {
          await trigger.click();
          await waitForMenuFocus();
        }
      };
      const closeMenu = async () => {
        await page.keyboard.press("Escape");
        await page.waitForFunction(() => document.activeElement === document.querySelector("#header-more-button"));
        assert.equal(await trigger.getAttribute("aria-expanded"), "false");
      };
      assert(await create.isVisible(), "New schedule is in the page header");
      assert.equal(await page.locator(".schedule-card [data-new-schedule], .schedule-daemon-menu").count(), 0,
        "there is no duplicate create button or separate list menu");
      assert.equal(await page.locator('.app-header [aria-haspopup="menu"]:visible').count(), 1,
        "one header trigger serves both page and list actions");
      await create.focus();
      await page.evaluate(() => refresh({ force: true }));
      assert(await create.evaluate(node => node === document.activeElement), "refresh keeps header button focus");
      await trigger.focus();
      await page.keyboard.press("Enter");
      await waitForMenuFocus();
      await listMenu.locator("[data-archive-all-schedule-sessions]").focus();
      await page.evaluate(() => refresh({ force: true }));
      assert.equal(await trigger.getAttribute("aria-expanded"), "true", "refresh keeps the combined menu open");
      assert(await listMenu.locator("[data-archive-all-schedule-sessions]").evaluate(node => node === document.activeElement),
        "refresh keeps focus on the same menu action");
      await closeMenu();
      await openMenu();
      await page.locator("#screen-title").click();
      assert.equal(await trigger.getAttribute("aria-expanded"), "false", "outside click closes the combined menu");
      const assertHeaderBounds = async () => {
        await page.waitForTimeout(250);
        for (const selector of ["#screen-title", ".app-header [data-new-schedule]", "#header-more-button"]) {
          const box = await page.locator(selector).boundingBox();
          assert(box && box.x >= 0 && box.x + box.width <= page.viewportSize().width,
            `${selector} stays inside the viewport`);
        }
        if (await trigger.getAttribute("aria-expanded") === "true") {
          const box = await listMenu.boundingBox();
          assert(box.x >= 0 && box.x + box.width <= page.viewportSize().width && box.y + box.height <= page.viewportSize().height,
            "the combined menu stays inside the viewport");
        }
        const title = await page.locator("#screen-title").boundingBox();
        const button = await create.boundingBox();
        assert(title.y + title.height <= button.y || title.x + title.width <= button.x,
          "the title and create button do not overlap");
      };
      const original = await page.evaluate(() => ({ daemon: state.scheduleDaemon, setup: state.setup }));
      // Synthetic readiness variants preserve page permissions and list status rules.
      for (const status of ["running", "stale", "untracked", "stopped"]) {
        await page.evaluate(status => {
          clearTimeout(state.timer);
          state.scheduleDaemon = { status };
          state.setup = { ...state.setup, server: { ...state.setup.server, restartable: false, update: { available: true } } };
          render();
        }, status);
        await trigger.focus();
        await page.keyboard.press("Enter");
        await waitForMenuFocus();
        const selectors = [
          ...(status === "stopped" ? ['[data-scheduler-action="start"]'] : ['[data-scheduler-action="restart"]', '[data-scheduler-action="stop"]']),
          "[data-archive-all-schedule-sessions]", "[data-open-settings]", "[data-update-tycho]", "[data-restart-server]",
        ];
        assert.equal(await listMenu.locator('[role="menuitem"]').count(), selectors.length, "all combined actions appear exactly once");
        let previousY = -1;
        for (const selector of selectors) {
          const item = listMenu.locator(selector);
          assert(await item.isVisible(), `${selector} remains available in the combined menu`);
          const box = await item.boundingBox();
          assert(box.y > previousY, "schedule actions precede page actions in an understandable order");
          previousY = box.y;
        }
        assert(await listMenu.locator("[data-restart-server]").isDisabled(), "server restart permission stays disabled");
        assert(await listMenu.locator("[data-archive-all-schedule-sessions]").evaluate(node => node.nextElementSibling?.getAttribute("role") === "separator"),
          "a separator divides list and page actions");
        assert.equal(await listMenu.locator("[data-delete-schedule], [data-edit-schedule]").count(), 0, "row actions stay independent");
        await page.keyboard.press("End");
        assert(await listMenu.locator("[data-update-tycho]").evaluate(node => node === document.activeElement),
          "keyboard navigation skips disabled actions");
        await assertHeaderBounds();
        if (captureDir && ["running", "stopped"].includes(status)) {
          fs.mkdirSync(captureDir, { recursive: true });
          await page.screenshot({ path: path.join(captureDir, `schedule-header-${status}-${theme}-${width}.png`) });
        }
        await closeMenu();
      }
      await openMenu();
      await listMenu.locator("[data-open-settings]").focus();
      await page.evaluate(() => { state.scheduleDaemon = { status: "running" }; render(); });
      assert(await listMenu.locator("[data-open-settings]").evaluate(node => node === document.activeElement),
        "a daemon state change keeps focus on an existing page action");
      await listMenu.locator("[data-update-tycho]").focus();
      await page.evaluate(() => { state.setup.server.update.available = false; render(); });
      assert.equal(await listMenu.locator("[data-update-tycho]").count(), 0);
      assert(await listMenu.locator('[data-scheduler-action="restart"]').evaluate(node => node === document.activeElement),
        "a removed focused action falls back to the first enabled menu item");
      await page.evaluate(() => { state.setup.server.update.available = true; render(); });
      await closeMenu();
      if (width === 390) {
        for (const viewport of [{ width: 320, height: 900 }, { width: 390, height: 360 }]) {
          await page.setViewportSize(viewport);
          await openMenu();
          await assertHeaderBounds();
          await page.keyboard.press("End");
          assert(await listMenu.locator("[data-update-tycho]").evaluate(node => node === document.activeElement));
          await closeMenu();
        }
        await page.setViewportSize({ width, height: 900 });
      }
      if (width === 1440 && theme === "dark") {
        const requests = [];
        const stubAction = async route => {
          requests.push(new URL(route.request().url()).pathname);
          await route.fulfill({ status: 403, contentType: "application/json", body: '{"error":"Synthetic action denial"}' });
        };
        const urls = ["**/schedules/daemon/*", "**/schedules/archive-sessions", "**/server/restart", "**/update"];
        for (const url of urls) await page.route(url, stubAction);
        const actions = [
          ["start", '[data-scheduler-action="start"]', "/schedules/daemon/start", null],
          ["restart", '[data-scheduler-action="restart"]', "/schedules/daemon/restart", "Restart daemon"],
          ["stop", '[data-scheduler-action="stop"]', "/schedules/daemon/stop", "Stop daemon"],
          ["archive", "[data-archive-all-schedule-sessions]", "/schedules/archive-sessions", "Archive all sessions"],
          ["server", "[data-restart-server]", "/server/restart", "Restart server"],
          ["update", "[data-update-tycho]", "/update", "Update Tycho"],
        ];
        for (const [action, selector, endpoint, confirmation] of actions) {
          await page.evaluate(action => {
            clearTimeout(state.timer);
            state.scheduleDaemon = { status: action === "start" ? "stopped" : "running" };
            state.setup.server.restartable = true;
            render();
          }, action);
          await openMenu();
          if (confirmation) {
            const before = requests.length;
            await listMenu.locator(selector).click();
            assert.equal(await page.locator("[data-confirmation-accept]").textContent(), confirmation);
            await page.locator("[data-confirmation-cancel]").click();
            assert.equal(requests.length, before, "cancelled confirmation does not send a mutation");
            await openMenu();
          }
          const denied = page.waitForResponse(response => response.status() === 403 && new URL(response.url()).pathname === endpoint);
          await listMenu.locator(selector).click();
          if (confirmation) await page.locator("[data-confirmation-accept]").click();
          await denied;
          await page.waitForFunction(() => document.querySelector("#screen-subtitle").textContent.includes("Synthetic action denial"));
          assert.equal(requests.at(-1), endpoint, `${action} retains its endpoint and confirmation semantics`);
          assert.equal(await trigger.getAttribute("aria-expanded"), "false", "an action closes the combined menu");
        }
        for (const url of urls) await page.unroute(url, stubAction);
      }
      await page.evaluate(original => {
        state.scheduleDaemon = original.daemon;
        state.setup = original.setup;
        render();
      }, original);
      await openMenu();
      assert.equal(await listMenu.locator("[data-update-tycho]").count(), original.setup.server.update?.available ? 1 : 0,
        "unavailable updates keep their original visibility rule");
      await closeMenu();
      const link = page.locator(".sidebar-settings-link");
      assert.equal(await link.isVisible(), width >= 1100);
      assert.equal(await page.locator("#bottom-nav .sidebar-settings-link").count(), 0);
      if (width >= 1100) {
        const nav = await page.locator("#bottom-nav").boundingBox();
        const settings = await link.boundingBox();
        assert(settings.y >= nav.y + nav.height, "Settings link is below the navigation panel");
        const assertBottomLink = async () => {
          const box = await link.boundingBox();
          const viewport = page.viewportSize();
          assert(box.x >= 0 && box.x + box.width <= viewport.width, "Settings stays inside the sidebar");
          assert(viewport.height - box.y - box.height >= 8 && viewport.height - box.y - box.height <= 24,
            "Settings stays near the bottom edge of the viewport");
        };
        await assertBottomLink();
        assert.equal(await link.locator("circle").getAttribute("r"), "3");
        const gearPath = await page.evaluate(() => {
          const host = document.createElement("div");
          host.innerHTML = iconSvg("settings");
          return host.querySelector("path").getAttribute("d");
        });
        assert.equal(await link.locator("path").getAttribute("d"), gearPath, "reuse the existing Settings gear");
        await page.evaluate(() => {
          const spacer = document.createElement("div");
          spacer.id = "settings-scroll-fixture";
          spacer.style.height = "1800px";
          document.querySelector("#view").append(spacer);
          window.scrollTo(0, 500);
        });
        await page.waitForFunction(() => window.scrollY >= 400);
        await assertBottomLink();
        await page.evaluate(() => refresh({ force: true }));
        await assertBottomLink();
        await page.evaluate(() => { document.querySelector("#settings-scroll-fixture")?.remove(); window.scrollTo(0, 0); });
        for (const height of [600, 240, 900]) {
          await page.setViewportSize({ width, height });
          await assertBottomLink();
        }
        await page.setViewportSize({ width: 1099, height: 900 });
        assert.equal(await link.isVisible(), false, "hide the desktop Settings link below the sidebar breakpoint");
        await page.setViewportSize({ width, height: 900 });
        await assertBottomLink();
        await page.locator('[data-tab="schedules"]').focus();
        await page.keyboard.press("Tab");
        assert(await link.evaluate(node => document.activeElement === node), "Settings is next in keyboard order after navigation");
        await page.keyboard.press("Enter");
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
      await page.locator("[data-new-schedule]").focus();
      await page.keyboard.press("Enter");
      await page.locator("#schedule-form").waitFor();
      await page.locator("#back-button").click();
      await page.waitForURL("**/ui#schedules");
      // Let the existing detail-header transition finish before capture.
      await page.waitForTimeout(250);
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
  console.log("schedules_page_smoke: ok (direct access, desktop/mobile Dark/Light/System navigation, bottom Settings gear, scroll/resize/keyboard, polling, pause/resume, forms, actions, layout)");
};
