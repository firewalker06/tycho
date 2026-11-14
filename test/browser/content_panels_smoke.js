const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");

module.exports = async function contentPanelsSmoke({ browser, baseUrl, agentKey, captureDir }) {
  const results = [];
  for (const theme of ["dark", "light"]) {
    const page = await browser.newPage({ viewport: { width: 1440, height: 900 } });
    const errors = [];
    page.on("pageerror", error => errors.push(error.message));
    await page.addInitScript(theme => localStorage.setItem("hq.remote.appearance", theme), theme);
    const url = `${baseUrl}/ui#agent/${agentKey}/summary/preview-prior`;
    await page.goto(url, { waitUntil: "networkidle" });
    // Use the application's theme API, and seed a long synthetic conversation.
    await page.evaluate(({ theme, agentKey }) => {
      window.TychoAppearance.setPreference(theme);
      const blocks = state.conversations[agentKey]?.blocks;
      if (blocks) blocks.push(...Array.from({ length: 30 }, (_, i) => ({ kind: "message", role: "user", content: `Synthetic panel check ${i}: Keep this conversation position.` })));
      render();
    }, { theme, agentKey });
    const open = page.locator(".agent-detail-pane [data-preview-summary-attachment]").first();
    const toggle = key => page.locator(`[data-toggle-content-panel="${key}"]`);
    const panel = key => page.locator({ conversation: ".agent-conversation-pane", summary: ".agent-detail-pane", preview: ".summary-attachment-preview-pane" }[key]);
    const measure = () => page.evaluate(() => {
      const root = document.querySelector(".agent-workspace");
      return { width: innerWidth, usable: root.clientWidth, visible: root.dataset.visiblePanels?.split(" "), overflow: document.documentElement.scrollWidth > innerWidth,
        panels: [...root.querySelectorAll(":scope > .agent-conversation-pane, :scope > .agent-detail-pane, :scope > .summary-attachment-preview-pane")].filter(el => el.getClientRects().length).map(el => { const r = el.getBoundingClientRect(); return { x: r.x, right: r.right, width: r.width, bottom: r.bottom }; }) };
    });
    const check = async count => {
      const layout = await measure();
      assert.equal(layout.visible.length, count, JSON.stringify(layout));
      assert(!layout.overflow, JSON.stringify(layout));
      assert.equal(layout.panels.length, count, JSON.stringify(layout));
      for (let i = 0; i < count; i++) {
        assert(layout.panels[i].width >= (count === 1 ? 340 : layout.visible[i] === "conversation" ? 380 : 440), JSON.stringify(layout));
        assert(layout.panels[i].right <= layout.width + 1, JSON.stringify(layout));
        assert(layout.panels[i].bottom <= 901, JSON.stringify(layout));
        if (i) assert(layout.panels[i - 1].right <= layout.panels[i].x, JSON.stringify(layout));
      }
      results.push({ theme, ...layout });
    };
    const capture = async name => { if (captureDir) await page.screenshot({ path: path.join(captureDir, `content-panels-${name}-${theme}.png`) }); };
    const composer = page.locator("#composer textarea");
    await composer.fill("Keep this unsent panel draft.");
    await open.click();
    await page.waitForFunction(() => document.querySelector(".summary-attachment-preview-scroll")?.getAttribute("aria-busy") === "false");
    await check(2);
    assert(await panel("preview").isVisible());
    assert(await panel("summary").isVisible());
    assert.equal(await page.evaluate(() => parseRoute().summaryId), "preview-prior");
    await capture("constrained");
    await toggle("conversation").focus();
    await page.keyboard.press("Enter");
    await check(2);
    assert(await panel("conversation").isVisible());
    assert(!(await panel("summary").isVisible()));
    assert.equal(await composer.inputValue(), "Keep this unsent panel draft.");
    await page.evaluate(() => {
      document.querySelector(".agent-conversation-scroll").scrollTop = 140;
      document.querySelector(".summary-attachment-preview-scroll").scrollTop = 380;
    });
    const saved = await page.evaluate(() => [document.querySelector(".agent-conversation-scroll").scrollTop, document.querySelector(".summary-attachment-preview-scroll").scrollTop]);
    assert(saved[0] > 0 && saved[1] > 0, `Fixture must scroll: ${saved}`);
    const selection = await page.evaluate(() => state.summaryAttachmentPreview.id);
    await toggle("summary").click();
    await check(2);
    assert(!(await panel("preview").isVisible()));
    await page.evaluate(async () => { await refresh({ force: true, preserveFocusedWorkspace: true }); render(); });
    await check(2);
    await toggle("preview").click();
    await check(2);
    assert.equal(await page.evaluate(() => document.querySelector(".summary-attachment-preview-scroll").scrollTop), saved[1]);
    await toggle("conversation").click();
    assert.equal(await composer.inputValue(), "Keep this unsent panel draft.");
    assert.equal(await page.evaluate(() => document.querySelector(".agent-conversation-scroll").scrollTop), saved[0]);
    await capture("constrained-conversation");
    await page.setViewportSize({ width: 2200, height: 900 });
    await page.waitForFunction(() => document.querySelector(".agent-workspace")?.dataset.visiblePanels?.split(" ").length === 3);
    await check(3);
    await capture("wide");
    for (const key of ["conversation", "summary", "preview"]) {
      await toggle(key).click();
      await check(2);
      assert(!(await panel(key).isVisible()));
      await page.evaluate(() => render());
      assert(!(await panel(key).isVisible()));
      await toggle(key).click();
      await check(3);
    }
    for (const width of [900, 1024, 1100, 1280, 1464, 1463, 1760]) {
      await page.setViewportSize({ width, height: 900 });
      await page.evaluate(() => syncContentPanelLayout());
      const fit = await measure();
      await check(fit.visible.length);
      assert(fit.visible.length <= (fit.usable < 1284 ? 2 : 3));
    }
    await page.setViewportSize({ width: 1180, height: 900 });
    await page.waitForFunction(() => document.querySelector(".agent-workspace")?.dataset.visiblePanels?.split(" ").length === 2);
    await check(2);
    await page.locator("[data-restore-content-panels]").click();
    await check(2);
    // Measure fit after extra navigation space, independent of viewport width.
    await page.evaluate(() => { document.querySelector(".agent-workspace").style.width = "760px"; });
    await page.waitForFunction(() => document.querySelector(".agent-workspace")?.dataset.visiblePanels?.split(" ").length === 1);
    await check(1);
    await toggle("conversation").click();
    await check(1);
    assert(await panel("conversation").isVisible());
    await page.evaluate(() => { document.querySelector(".agent-workspace").style.removeProperty("width"); });
    await page.setViewportSize({ width: 390, height: 844 });
    assert(!(await page.locator(".content-panel-controls").isVisible()));
    assert(await panel("summary").isVisible());
    assert(!(await panel("preview").isVisible()));
    assert(!(await page.evaluate(() => document.documentElement.scrollWidth > innerWidth)));
    await capture("mobile-summary");
    await page.setViewportSize({ width: 2200, height: 900 });
    await page.waitForFunction(() => document.querySelector(".agent-workspace")?.dataset.visiblePanels?.split(" ").length === 3);
    await check(3);
    assert.equal(await page.evaluate(() => state.summaryAttachmentPreview.id), selection);
    assert.equal(await page.evaluate(() => parseRoute().summaryId), "preview-prior");
    assert.equal(await composer.inputValue(), "Keep this unsent panel draft.");
    await page.locator("[data-close-summary-attachment-preview]").click();
    assert.equal(await panel("preview").count(), 0);
    assert(await panel("conversation").isVisible());
    assert(await panel("summary").isVisible());
    // Direct mobile preview action retains the existing attachment route.
    await page.setViewportSize({ width: 390, height: 844 });
    await open.click();
    await page.waitForURL(/\/attachment\//);
    assert.equal(await panel("preview").count(), 0);
    await capture("mobile-attachment");
    assert.deepEqual(errors, []);
    await page.close();
  }
  if (captureDir) fs.writeFileSync(path.join(captureDir, "content-panels-results.json"), JSON.stringify(results, null, 2));
  console.log(`content-panels-smoke: ok (${results.length} layouts; Dark/Light, keyboard, polling, drafts, scroll, selection, mobile)`);
};
