const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");

module.exports = async ({ browser, baseUrl, agentKey, captureDir }) => {
  const results = [];
  for (const width of [1440, 577, 390]) for (const theme of ["dark", "light"]) {
    const context = await browser.newContext({ viewport: { width, height: width === 577 ? 286 : 900 }, deviceScaleFactor: width === 577 ? 2 : 1, isMobile: width < 640, hasTouch: width < 640 });
    const page = await context.newPage();
    const pageErrors = [];
    let delayedFontUrl = "";
    let fontResponseReleased = false;
    let delayedAgentDetailUrl = "";
    let holdAgentRefresh = false;
    page.on("pageerror", error => pageErrors.push(error.message));
    await page.route("**/fonts/**/*.woff2", async route => {
      if (!delayedFontUrl) {
        delayedFontUrl = route.request().url();
        await new Promise(resolve => setTimeout(resolve, 1500));
      }
      fontResponseReleased = true;
      await route.continue();
    });
    await page.route(`**/agents/${agentKey}`, async route => {
      if (!holdAgentRefresh) return route.continue();
      delayedAgentDetailUrl = route.request().url();
      await new Promise(resolve => setTimeout(resolve, 900));
      const response = await route.fetch();
      const payload = await response.json();
      const agent = payload.agent;
      assert(agent, "the delayed agent detail response did not include the fixture agent");
      const longTitles = [
        "Quarterly access review — final presentation with approved speaker notes.pptx",
        "Quarterly access review — supporting report with complete findings.pdf",
      ];
      assert(Array.isArray(agent.attachments), "the delayed agent detail response has no attachments");
      agent.attachments.forEach((attachment, index) => {
        attachment.title = longTitles[index];
      });
      return route.fulfill({ response, body: JSON.stringify(payload) });
    });
    await page.goto(`${baseUrl}/ui#agent/${agentKey}/summary/layout-2`, { waitUntil: "domcontentloaded" });
    await page.evaluate(themeName => window.TychoAppearance.setPreference(themeName), theme);
    const summary = page.locator("[data-agent-summary-page]");
    const rows = summary.locator(".summary-attachment-item");
    await rows.first().waitFor();
    assert.equal(await rows.count(), 2);
    assert((await rows.first().textContent()).includes("presentation.pptx"));
    assert((await rows.nth(1).textContent()).includes("report.pdf"));
    assert(delayedFontUrl, "the test did not hold the UI font response");
    assert(!fontResponseReleased, "the delayed font loaded before the fallback layout was measured");
    assert.equal(await summary.locator(".summary-attachment-item .summary-attachment-row").count(), 2);
    assert.equal(await summary.locator(".summary-attachment-item .summary-attachment-preview").count(), 2);
    assert.equal(await summary.locator(".summary-attachment-item [data-download-attachment]").count(), 2);

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
        return { item: { top: box.top, bottom: box.bottom }, row: { top: row.top, right: row.right, bottom: row.bottom },
          copy: { left: copy.left, right: copy.right, bottom: copy.bottom }, title: { top: title.top, bottom: title.bottom, height: title.height, text: titleElement.textContent,
            color: titleStyle.color, visibility: titleStyle.visibility, opacity: titleStyle.opacity, width: title.width,
            clientWidth: titleElement.clientWidth, scrollWidth: titleElement.scrollWidth }, text: { top: text.top, bottom: text.bottom },
          actions: actionRects.map(rect => ({ left: rect.left, right: rect.right, top: rect.top, bottom: rect.bottom })) };
      });
    });
    const assertRowsFit = async label => {
      const boxes = await measure();
      for (let index = 0; index < boxes.length; index++) {
        const row = boxes[index];
        assert(row.row.top <= row.text.top + 1 && row.row.bottom >= row.text.bottom - 1,
          `${label}: text escaped row ${index}: ${JSON.stringify(boxes)}`);
        assert(row.title.height > 0 && row.row.top <= row.title.top + 1 && row.row.bottom >= row.title.bottom - 1,
          `${label}: title escaped or disappeared from row ${index}: ${JSON.stringify(boxes)}`);
        assert(row.copy.right <= row.row.right + 1, `${label}: text overlaps action controls: ${JSON.stringify(boxes)}`);
        if (index + 1 < boxes.length) assert(row.item.bottom <= boxes[index + 1].item.top + 1,
          `${label}: attachment rows overlap: ${JSON.stringify(boxes)}`);
        for (const action of row.actions) assert(action.top >= row.item.top - 1 && action.bottom <= row.item.bottom + 1 && action.right - action.left >= 44 && action.bottom - action.top >= 44,
          `${label}: action is outside its row or lost its touch target: ${JSON.stringify(boxes)}`);
      }
      return boxes;
    };

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
    assert((await rows.first().textContent()).includes("presentation.pptx"), "attachment content changed before the held agent response");
    const whilePending = await assertRowsFit("while refresh response is delayed");
    await refreshPromise;
    assert(delayedAgentDetailUrl, "refresh did not pass through the deliberately delayed agent detail response");
    assert.equal(await summary.count(), 1, `summary disappeared after delayed refresh at ${page.url()}; body=${(await page.locator("body").innerText()).slice(0, 600)}; errors=${pageErrors.join(" | ")}`);
    const refreshedRows = await rows.count();
    if (refreshedRows !== 2) {
      const projection = await page.evaluate(key => ({ route: parseRoute(), catalog: state.agents.find(agent => agent.key === key)?.attachments,
        detail: state.agentDetails[key]?.attachments, summary: state.conversations[key]?.blocks.filter(block => block.kind === "run_summary").map(block => block.metadata?.attachments) }), agentKey);
      throw new Error(`Delayed refresh changed attachment row count: ${refreshedRows}; projection=${JSON.stringify(projection)}; body=${(await summary.innerText()).slice(-500)}`);
    }
    assert((await rows.first().textContent()).includes("approved speaker notes.pptx"), "refresh did not apply the updated long attachment title");
    assert((await rows.nth(1).textContent()).includes("complete findings.pdf"), "refresh did not apply the updated long attachment title");
    const afterRefresh = await assertRowsFit("after delayed refresh");

    for (const mode of ["wide", "full", "balanced"]) {
      await page.evaluate(({ key, modeName }) => setAgentDetailViewMode(`${key}:summary`, modeName), { key: agentKey, modeName: mode });
      await page.evaluate(() => new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve))));
      await assertRowsFit(`after ${mode} view`);
      if (captureDir && mode === "full" && [577, 1440].includes(width)) {
        await page.screenshot({ path: path.join(captureDir, `summary-attachment-full-${theme}-${width}.png`) });
      }
    }
    if (captureDir && [1440, 577, 390].includes(width)) {
      fs.mkdirSync(captureDir, { recursive: true });
      if (width === 390) await page.setViewportSize({ width, height: 1200 });
      await assertRowsFit("after screenshot viewport resize");
      await page.evaluate(themeName => window.TychoAppearance.setPreference(themeName), theme);
      await page.screenshot({ path: path.join(captureDir, `summary-attachment-layout-${theme}-${width}.png`) });
    }
    assert.deepEqual(pageErrors, []);
    results.push({ width, theme, delayedFontUrl, delayedAgentDetailUrl, beforeFont, afterFont, whilePending, afterRefresh });
    await context.close();
  }
  if (captureDir) fs.writeFileSync(path.join(captureDir, "summary-attachment-layout-results.json"), JSON.stringify(results, null, 2));
  console.log(`summary_attachment_layout_smoke: ok ${JSON.stringify(results.map(result => ({ width: result.width, theme: result.theme, fontDelayed: Boolean(result.delayedFontUrl), rowHeights: result.afterRefresh.map(row => Math.round(row.item.bottom - row.item.top)) })))}`);
};
