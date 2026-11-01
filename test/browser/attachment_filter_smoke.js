const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");

async function assertFocusKeyIsolation(browser) {
  const source = fs.readFileSync(path.join(__dirname, "../../lib/hq/remote_ui/assets/app.js"), "utf8");
  const range = (start, end) => source.slice(source.indexOf(start), source.indexOf(end, source.indexOf(start)));
  const page = await browser.newPage();
  try {
    await page.setContent('<main id="view"></main>');
    await page.addScriptTag({ path: path.join(__dirname, "../../lib/hq/remote_ui/assets/app_helpers.js") });
    await page.addScriptTag({ content: `
      const REMOTE_HELPERS = window.TychoRemoteHelpers;
      const els = { view: document.querySelector("#view") };
      const attachmentTypeFilters = new Map();
      const escapeAttr = value => String(value).replaceAll("&", "&amp;").replaceAll('"', "&quot;");
      const escapeHtml = String;
      ${source.slice(source.indexOf("const ICONS ="), source.indexOf("\n};", source.indexOf("const ICONS =")) + 3)}
      ${range("function iconSvg(", "// Official upstream marks;")}
      const attachmentKind = item => item.type, attachmentFormat = item => item.format;
      const elementStateKey = (element, index) => REMOTE_HELPERS.elementStateKey(element, index);
      const restorePageScroll = () => {};
      const repositionOpenSummaryAttachmentMenus = () => {};
      const restoreSkillAutocompleteAfterRender = () => {};
      ${range("function attachmentFilterType(", "function renderAgentAttachments(")}
      ${range("function captureViewState(", "function syncPreservedOpenState(")}
    ` });
    const result = await page.evaluate(() => {
      const groups = [["agent:a", "flyout"], ["agent:a", "navigation"], ["agent:b", "flyout"], ["agent:b", "navigation"]];
      const rows = [{ type: "file", format: "image" }];
      const html = (entries, items) => entries.map(([key, surface]) => renderAttachmentTypeFilters({ key }, items, surface)).join("");
      const target = () => [...els.view.querySelectorAll('[data-attachment-type-filter="images"]')]
        .find(element => element.dataset.agentKey === "agent:b" && element.closest("[data-attachment-filter-surface]").dataset.attachmentFilterSurface === "navigation");
      els.view.innerHTML = html(groups, rows);
      const keys = [...els.view.querySelectorAll("[data-preserve-focus]")].map(element => element.dataset.stateKey);
      target().focus();
      const snapshot = captureViewState();
      els.view.innerHTML = html([...groups].reverse(), [...rows, ...rows]);
      restoreViewState(snapshot);
      const matched = document.activeElement === target();
      const countChanged = target().querySelector(".attachment-type-filter-count").textContent === "2";
      const removedResults = [];
      for (const entries of [groups.filter(([key]) => key !== "agent:b"), groups.filter(([, surface]) => surface !== "navigation")]) {
        els.view.innerHTML = html(groups, rows);
        target().focus();
        const saved = captureViewState();
        els.view.innerHTML = html(entries, rows);
        restoreViewState(saved);
        removedResults.push(document.activeElement === document.body);
      }
      return { unique: new Set(keys).size === keys.length, matched, countChanged, removedResults };
    });
    assert.deepEqual(result, { unique: true, matched: true, countChanged: true, removedResults: [true, true] });
  } finally { await page.close(); }
}

module.exports = async ({ browser, baseUrl, agentKey, captureDir }) => {
  await assertFocusKeyIsolation(browser);
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
    async function assertIconFilters(root) {
      const result = await root.evaluate(async element => {
        await Promise.allSettled(element.getAnimations({ subtree: true }).map(animation => animation.finished));
        const controls = [...element.querySelectorAll("[data-attachment-type-filter]")];
        const shapes = { all: "paperclip", images: "image", files: "fileText", links: "link" };
        const buttons = controls.map(button => {
          const type = button.dataset.attachmentTypeFilter;
          const expectedIcon = new DOMParser().parseFromString(iconSvg(shapes[type]), "text/html").querySelector("svg");
          const badge = button.querySelector(".attachment-type-filter-count");
          const rect = button.getBoundingClientRect();
          const style = getComputedStyle(button);
          return {
            type, icon: button.querySelector("svg")?.outerHTML === expectedIcon.outerHTML,
            badge: badge?.classList.contains("ui-badge"),
            visibleText: button.textContent.trim() === badge?.textContent.trim(),
            name: button.getAttribute("aria-label"), title: button.title,
            count: badge?.textContent.trim(), border: style.borderTopWidth,
            hitArea: rect.width >= 38 && rect.height >= 38,
            selectedBadge: badge?.dataset.intent === (button.getAttribute("aria-pressed") === "true" ? "active" : "neutral"),
          };
        });
        const selected = controls.find(button => button.getAttribute("aria-pressed") === "true");
        const disabled = controls.find(button => button !== selected);
        const enabledColor = getComputedStyle(disabled).color;
        disabled.disabled = true;
        const pressed = disabled.getAttribute("aria-pressed");
        disabled.click();
        const blocked = disabled.getAttribute("aria-pressed") === pressed && selected.getAttribute("aria-pressed") === "true";
        getComputedStyle(disabled).color;
        await Promise.allSettled(disabled.getAnimations().map(animation => animation.finished));
        const disabledStyle = getComputedStyle(disabled);
        const disabledVisible = (Number(disabledStyle.opacity) < 1 || disabledStyle.color !== enabledColor) && disabledStyle.cursor === "not-allowed" && disabledStyle.borderTopWidth === "0px";
        const disabledObserved = { opacity: disabledStyle.opacity, cursor: disabledStyle.cursor, border: disabledStyle.borderTopWidth };
        disabled.disabled = false;
        getComputedStyle(disabled).color;
        await Promise.allSettled(disabled.getAnimations().map(animation => animation.finished));
        const distinctSelected = getComputedStyle(selected).backgroundColor !== getComputedStyle(disabled).backgroundColor;
        return { buttons, blocked, disabledVisible, disabledObserved, distinctSelected };
      });
      assert(result.blocked && result.disabledVisible && result.distinctSelected, `native disabled and selected feedback remain clear: ${JSON.stringify(result)}`);
      assert.equal(result.buttons.length, 4);
      for (const item of result.buttons) {
        assert(item.icon && item.badge && item.visibleText && item.hitArea && item.selectedBadge, `${item.type} uses known icon, badge-only text, selected style and hit area`);
        assert.equal(item.border, "0px", "filter button is borderless");
        assert.equal(item.name, item.title, "tooltip preserves the full accessible name");
        assert(item.name.includes(`(${item.count})`));
      }
      await button(root, "images").locator(".attachment-type-filter-count").click();
      assert.equal(await button(root, "images").getAttribute("aria-pressed"), "true", "badge click activates its filter");
      await button(root, "all").click();
    }
    async function assertChangedDataFocus(root, surface) {
      const filter = button(root, "images");
      await filter.focus();
      await page.keyboard.press("Enter");
      for (const mode of ["keyboard", "pointer", "programmatic"]) {
        if (mode === "pointer") await filter.click();
        if (mode === "programmatic") await filter.evaluate(element => { element.blur(); element.focus({ preventScroll: true }); });
        const result = await page.evaluate(({ key, surface }) => {
          const selector = `[data-attachment-filter-surface="${surface}"] [data-attachment-type-filter="images"]`;
          const original = document.querySelector(selector);
          const focusVisible = original.matches(":focus-visible");
          const agent = findAgent(key);
          const originalRows = agent.attachments;
          agent.attachments = [...originalRows, { id: "focus-update", type: "file", format: "image", path: "/synthetic/focus-update.png", title: "Focus update" }];
          render();
          const replacement = document.querySelector(selector);
          const result = {
            replaced: replacement !== original && !original.isConnected,
            focused: document.activeElement === replacement,
            sameFocusVisible: replacement.matches(":focus-visible") === focusVisible,
            pressed: replacement.getAttribute("aria-pressed"),
            count: replacement.querySelector(".attachment-type-filter-count").textContent.trim(),
          };
          agent.attachments = originalRows;
          render();
          result.focusedAfterRemoval = document.activeElement === document.querySelector(selector);
          return result;
        }, { key: agentKey, surface });
        assert.deepEqual(result, { replaced: true, focused: true, sameFocusVisible: true, pressed: "true", count: "2", focusedAfterRemoval: true }, `${surface} ${mode} changed metadata keeps replacement focus`);
      }
      await filter.focus();
      await page.keyboard.press("Enter");
      await capture(`changed-data-${surface}-focus`);
    }
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
      await assertIconFilters(flyout);
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
      await assertChangedDataFocus(flyout, "flyout");
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
      await assertIconFilters(drawer);
      assert.equal(await drawer.locator("[aria-current='page']").count(), 1);
      await assertChangedDataFocus(drawer, "navigation");
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
    results.push({ device, themes: ["dark", "light", "system"], checks: "borderless type icons, count badges, accessible names/tooltips, disabled and selected feedback, hit areas, badge activation, changed-data replacement focus, keyboard/pointer/programmatic focus semantics, agent/surface focus key isolation, counts, keyboard, touch, focus, polling, selection, reset, updates, duplicates, unknown, empty, borders, overflow" });
    await context.close();
  }
  if (captureDir) fs.writeFileSync(path.join(captureDir, "browser-results.json"), JSON.stringify(results, null, 2));
  console.log(`attachment-filter-smoke: ${JSON.stringify(results)}`);
};
