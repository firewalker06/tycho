const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");

module.exports = async ({ browser, baseUrl, agentKey, captureDir }) => {
  const results = [];
  const baselineCssPath = process.env.TYCHO_REMOTE_UI_SUMMARY_ATTACHMENT_LAYOUT_BASELINE_CSS;
  const collectOnly = process.env.TYCHO_REMOTE_UI_SUMMARY_ATTACHMENT_LAYOUT_COLLECT_ONLY === "1";
  for (const width of [1180, 548, 1440, 390]) for (const theme of ["dark", "light"]) {
    const isTablet = width === 1180 || width === 548;
    const context = await browser.newContext({ viewport: { width, height: width === 1180 ? 820 : width === 548 ? 286 : 900 },
      deviceScaleFactor: isTablet ? 2 : 1, isMobile: width < 640 || width === 1180, hasTouch: isTablet || width === 390 });
    const page = await context.newPage();
    const pageErrors = [];
    let delayedFontUrl = "";
    let fontResponseReleased = false;
    let delayedAgentDetailUrl = "";
    let holdAgentRefresh = false;
    let baselineCssServed = false;
    page.on("pageerror", error => pageErrors.push(error.message));
    if (baselineCssPath) await page.route("**/ui.css*", route => {
      baselineCssServed = true;
      return route.fulfill({
        status: 200,
        contentType: "text/css; charset=utf-8",
        body: fs.readFileSync(baselineCssPath, "utf8"),
      });
    });
    await page.route("**/fonts/**/*.woff2", async route => {
      if (!delayedFontUrl) {
        delayedFontUrl = route.request().url();
        await new Promise(resolve => setTimeout(resolve, 1500));
      }
      fontResponseReleased = true;
      await route.continue();
    });
    await page.route(`**/agents/${agentKey}`, async route => {
      if (!holdAgentRefresh) {
        const response = await route.fetch();
        const payload = await response.json();
        payload.agent.attachments.forEach(attachment => {
          attachment.path = attachment.path.replace("/personal/secondbrain", "/p/secondbrain");
        });
        return route.fulfill({ response, body: JSON.stringify(payload) });
      }
      delayedAgentDetailUrl = route.request().url();
      await new Promise(resolve => setTimeout(resolve, 900));
      const response = await route.fetch();
      const payload = await response.json();
      const agent = payload.agent;
      assert(agent, "the delayed agent detail response did not include the fixture agent");
      const longTitles = ["Nov 24 daily journal", "Nov 24 memory synthesis", "Nov 24 Activity record"];
      assert(Array.isArray(agent.attachments), "the delayed agent detail response has no attachments");
      agent.attachments.forEach((attachment, index) => {
        attachment.title = longTitles[index];
      });
      return route.fulfill({ response, body: JSON.stringify(payload) });
    });
    await page.goto(`${baseUrl}/ui#agent/${agentKey}/summary/layout-2`, { waitUntil: "domcontentloaded" });
    if (baselineCssPath) assert(baselineCssServed, "the baseline stylesheet was not served");
    await page.evaluate(themeName => window.TychoAppearance.setPreference(themeName), theme);
    const summary = page.locator("[data-agent-summary-page]");
    const rows = summary.locator(".summary-attachment-item");
    await rows.first().waitFor();
    assert.equal(await rows.count(), 3);
    assert((await rows.first().textContent()).includes("Nov 24 daily journal"));
    assert((await rows.nth(1).textContent()).includes("Nov 24 memory synthesis"));
    assert((await rows.nth(2).textContent()).includes("Nov 24 Activity record"));
    assert(delayedFontUrl, "the test did not hold the UI font response");
    assert(!fontResponseReleased, "the delayed font loaded before the fallback layout was measured");
    assert.equal(await summary.locator(".summary-attachment-item .summary-attachment-row").count(), 3);
    assert.equal(await summary.locator(".summary-attachment-item .summary-attachment-preview").count(), 3);
    assert.equal(await summary.locator(".summary-attachment-item [data-download-attachment]").count(), 3);

    const measure = () => page.evaluate(() => {
      const items = [...document.querySelectorAll("[data-agent-summary-page] .summary-attachment-item")];
      return items.map(item => {
        const box = item.getBoundingClientRect();
        const row = item.querySelector(".summary-attachment-row").getBoundingClientRect();
        const copy = item.querySelector(".attachment-copy").getBoundingClientRect();
        const title = item.querySelector(".attachment-copy strong").getBoundingClientRect();
        const titleElement = item.querySelector(".attachment-copy strong");
        const titleStyle = getComputedStyle(titleElement);
        const text = item.querySelector(".attachment-copy span").getBoundingClientRect();
        const actionRects = [...item.querySelectorAll(".ui-icon-button")].map(button => button.getBoundingClientRect());
        return { viewport: { width: innerWidth, height: innerHeight, deviceScaleFactor: devicePixelRatio },
          font: { status: document.fonts.status, family: getComputedStyle(titleElement).fontFamily,
            size: titleStyle.fontSize, lineHeight: titleStyle.lineHeight },
          item: { top: box.top, right: box.right, bottom: box.bottom, width: box.width },
          row: { top: row.top, right: row.right, bottom: row.bottom, width: row.width },
          copy: { left: copy.left, right: copy.right, bottom: copy.bottom }, title: { top: title.top, bottom: title.bottom, height: title.height, text: titleElement.textContent,
            color: titleStyle.color, visibility: titleStyle.visibility, opacity: titleStyle.opacity, width: title.width,
            clientWidth: titleElement.clientWidth, scrollWidth: titleElement.scrollWidth }, text: { top: text.top, bottom: text.bottom },
          actions: actionRects.map(rect => ({ left: rect.left, right: rect.right, top: rect.top, bottom: rect.bottom })) };
      });
    });
    const assertRowsFit = async label => {
      const boxes = await measure();
      const failures = [];
      for (let index = 0; index < boxes.length; index++) {
        const row = boxes[index];
        if (!(row.row.top <= row.text.top + 1 && row.row.bottom >= row.text.bottom - 1)) failures.push(`text escaped row ${index}`);
        if (!(row.title.height > 0 && row.row.top <= row.title.top + 1 && row.row.bottom >= row.title.bottom - 1)) failures.push(`title escaped row ${index}`);
        if (row.copy.right > row.row.right + 1) failures.push(`text overlaps actions in row ${index}`);
        if (index + 1 < boxes.length && row.item.bottom > boxes[index + 1].item.top + 1) failures.push(`attachment rows overlap at ${index}`);
        for (const action of row.actions) {
          if (!(action.top >= row.item.top - 1 && action.bottom <= row.item.bottom + 1 && action.right - action.left >= 44 && action.bottom - action.top >= 44)) {
            failures.push(`action outside row ${index} or below 44 CSS px`);
          }
        }
      }
      if (failures.length && !collectOnly) assert.fail(`${label}: ${failures.join(", ")}: ${JSON.stringify(boxes)}`);
      return boxes;
    };

    if (captureDir) {
      fs.mkdirSync(captureDir, { recursive: true });
      await page.screenshot({ path: path.join(captureDir, `summary-attachment-font-fallback-${theme}-${width}.png`) });
    }
    const beforeFont = await assertRowsFit("before delayed font load");
    if (captureDir) {
      fs.mkdirSync(captureDir, { recursive: true });
      await page.screenshot({ path: path.join(captureDir, `summary-attachment-font-fallback-${theme}-${width}.png`) });
    }
    await page.evaluate(() => document.fonts.ready);
    assert(fontResponseReleased, "the held font response did not complete");
    const afterFont = await assertRowsFit("after delayed font load");
    if (captureDir) await page.screenshot({ path: path.join(captureDir, `summary-attachment-font-loaded-${theme}-${width}.png`) });
    holdAgentRefresh = true;
    const refreshPromise = page.evaluate(() => refresh({ force: true, forceConversation: true }));
    await page.waitForTimeout(150);
    assert((await rows.first().textContent()).includes("Nov 24 daily journal"), "attachment content changed before the held agent response");
    const whilePending = await assertRowsFit("while refresh response is delayed");
    await refreshPromise;
    assert(delayedAgentDetailUrl, "refresh did not pass through the deliberately delayed agent detail response");
    assert.equal(await summary.count(), 1, `summary disappeared after delayed refresh at ${page.url()}; body=${(await page.locator("body").innerText()).slice(0, 600)}; errors=${pageErrors.join(" | ")}`);
    const refreshedRows = await rows.count();
    if (refreshedRows !== 3) {
      const projection = await page.evaluate(key => ({ route: parseRoute(), catalog: state.agents.find(agent => agent.key === key)?.attachments,
        detail: state.agentDetails[key]?.attachments, summary: state.conversations[key]?.blocks.filter(block => block.kind === "run_summary").map(block => block.metadata?.attachments) }), agentKey);
      throw new Error(`Delayed refresh changed attachment row count: ${refreshedRows}; projection=${JSON.stringify(projection)}; body=${(await summary.innerText()).slice(-500)}`);
    }
    assert((await rows.first().textContent()).includes("Nov 24 daily journal"), "refresh did not apply the first attachment title");
    assert((await rows.nth(1).textContent()).includes("Nov 24 memory synthesis"), "refresh did not apply the second attachment title");
    assert((await rows.nth(2).textContent()).includes("Nov 24 Activity record"), "refresh did not apply the third attachment title");
    const afterRefresh = await assertRowsFit("after delayed refresh");
    const viewModes = {};

    for (const mode of ["wide", "full", "balanced"]) {
      await page.evaluate(({ key, modeName }) => setAgentDetailViewMode(`${key}:summary`, modeName), { key: agentKey, modeName: mode });
      await page.evaluate(() => new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve))));
      if (captureDir && width === 1180 && theme === "dark" && mode === "full") {
        fs.mkdirSync(captureDir, { recursive: true });
        const label = baselineCssPath ? "baseline" : "proposed";
        await summary.screenshot({ path: path.join(captureDir, `summary-attachment-${label}-${theme}-webkit26-ipad.png`) });
      }
      viewModes[mode] = await assertRowsFit(`after ${mode} view`);
      if (captureDir && mode === "full" && [548, 1440].includes(width)) {
        await page.screenshot({ path: path.join(captureDir, `summary-attachment-full-${theme}-${width}.png`) });
      }
    }
    if (width === 1440) {
      await page.setViewportSize({ width: 548, height: 900 });
      await assertRowsFit("after resize to iPad panel width");
      await page.setViewportSize({ width: 1440, height: 900 });
      await assertRowsFit("after resize back to desktop width");
    }
    if (captureDir && [1440, 548, 390].includes(width)) {
      fs.mkdirSync(captureDir, { recursive: true });
      if (width === 390) await page.setViewportSize({ width, height: 1200 });
      await assertRowsFit("after screenshot viewport resize");
      await page.evaluate(themeName => window.TychoAppearance.setPreference(themeName), theme);
      await page.screenshot({ path: path.join(captureDir, `summary-attachment-layout-${theme}-${width}.png`) });
      await summary.screenshot({ path: path.join(captureDir, `summary-attachment-rows-${theme}-${width}.png`) });
    }
    assert.deepEqual(pageErrors, []);
    results.push({ width, theme, delayedFontUrl, delayedAgentDetailUrl, beforeFont, afterFont, whilePending, afterRefresh, viewModes });
    await context.close();
  }
  if (captureDir) fs.writeFileSync(path.join(captureDir, "summary-attachment-layout-results.json"), JSON.stringify(results, null, 2));
  console.log(`summary_attachment_layout_smoke: ${browser.browserType().name()} ${browser.version()} ${JSON.stringify(results.map(result => ({ width: result.width, theme: result.theme, fontDelayed: Boolean(result.delayedFontUrl), rowWidths: result.afterRefresh.map(row => Math.round(row.row.width)), rowHeights: result.afterRefresh.map(row => Math.round(row.item.bottom - row.item.top)) })))}`);
};
