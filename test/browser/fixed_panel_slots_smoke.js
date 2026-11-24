const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");

module.exports = async ({ browser, baseUrl, agentKey, captureDir, metadataFixture }) => {
  const api = await browser.newContext();
  const upload = await api.request.post(`${baseUrl}/agents/${agentKey}/messages`, { data: { prompt: "Fixed slot fixture", start: false,
    attachments: [{ filename: "slot-report.md", title: "Slot report", content_type: "text/markdown", content_base64: Buffer.from("# Slot report\n\nKeep this file in the third slot.").toString("base64") }] } });
  assert(upload.ok(), await upload.text());
  const agent = (await (await api.request.get(`${baseUrl}/agents/${agentKey}`)).json()).agent;
  const file = agent.attachments.find(a => a.title === "Slot report");
  const focus = (await (await api.request.get(`${baseUrl}/agents/${agentKey}/focus`)).json()).focus;
  const saved = await api.request.put(`${baseUrl}/agents/${agentKey}/focus`, { data: { revision: focus.revision, sections: [
    { title: "Review", items: [{ title: "Keep source context", attachments: [{ type: "file", title: "Slot report", path: file.path }, { type: "link", title: "External reference", url: "https://example.test/reference" }] }] },
    { title: "Later", items: [{ title: "Retain this collapsed section" }] },
  ] } });
  assert(saved.ok(), await saved.text());
  const stored = JSON.parse(fs.readFileSync(path.join(metadataFixture.logsDir, "managed_agents.json"))).find(a => a.key === agentKey);
  fs.appendFileSync(stored.log_path.replace(/\.raw\.log$/, ".memory.jsonl"), JSON.stringify({ type: "run_summary", content: "Fixed panel slots and mobile prompt controls.", status: "success", created_at: new Date().toISOString(), metadata: { summary_id: "fixed-slots", run_number: 1, attachments: [file] } }) + "\n");
  const results = [];
  const capacity = width => width >= 1440 ? 3 : width >= 900 ? 2 : 1;
  for (const width of [899, 900, 901, 1099, 1100, 1101, 1439, 1440, 1441, 1920, 3200]) for (const theme of ["dark", "light"]) {
    const context = await browser.newContext({ viewport: { width, height: 900 }, isMobile: width < 900, hasTouch: width < 900 });
    const page = await context.newPage();
    const errors = [];
    page.on("pageerror", e => errors.push(e.message));
    await page.goto(`${baseUrl}/ui#agent/${agentKey}`, { waitUntil: "networkidle" });
    await page.locator("[data-agent-workspace]").waitFor();
    await page.evaluate(() => new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve))));
    assert.equal(await page.locator('[data-side-kind="focus"]').count(), width >= 900 ? 1 : 0, "cold Focus defaults use the desktop/small-screen policy");
    await page.goto(`${baseUrl}/ui#agent/${agentKey}/summary`, { waitUntil: "networkidle" });
    await page.evaluate(theme => window.TychoAppearance.setPreference(theme), theme);
    await page.locator("[data-side-workspace]").waitFor();
    await page.locator("#prompt-input").fill("Retain the fixed-slot draft");
    await page.evaluate(() => document.fonts.ready);
    const setPanels = async (open, rail) => {
      await page.evaluate(({ key, open, rail }) => {
        state.summaryAttachmentPreview = null;
        const panel = state.agentSidePanels.get(key);
        panel.open = open; panel.mobileConversation = !open.length;
        render();
        // Exercise the existing 56px / 144px / absent navigation tracks without changing the viewport.
        const shell = document.querySelector(".app-shell"), header = document.querySelector(".app-header");
        const nav = document.querySelector("#bottom-nav"), content = document.querySelector("#view");
        const effective = innerWidth >= 1100 ? rail : "none";
        shell.style.gridTemplateColumns = effective === "none" ? "minmax(0, 1fr)" : `${effective === "expanded" ? 144 : 56}px minmax(0, 1fr)`;
        header.style.gridColumn = content.style.gridColumn = effective === "none" ? "1" : "2";
        nav.style.display = effective === "none" ? "none" : "";
        document.querySelector(".sidebar-settings-link").style.display = effective === "none" ? "none" : "";
        syncAgentDockLayout();
      }, { key: agentKey, open, rail });
      await page.evaluate(() => new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve))));
    };
    const measure = async open => {
      const g = await (await page.waitForFunction(() => {
        const root = document.querySelector("[data-agent-workspace]");
        const expectedSlots = innerWidth >= 1440 ? 3 : innerWidth >= 900 ? 2 : 1;
        if (!root?.clientWidth || Number(root.dataset.panelSlots) !== expectedSlots) return false;
        const style = getComputedStyle(root), r = root.getBoundingClientRect();
        const box = e => { const b = e.getBoundingClientRect(); return { kind: e.dataset.sideKind || "conversation", x: b.x, right: b.right, width: b.width, bottom: b.bottom }; };
        const panes = [...root.querySelectorAll(".agent-conversation-pane,[data-side-kind]")].filter(e => e.getClientRects().length && getComputedStyle(e).display !== "none").map(box);
        return { viewport: innerWidth, root: { x: r.x, width: r.width, right: r.right }, contentWidth: root.clientWidth - parseFloat(style.paddingLeft) - parseFloat(style.paddingRight), gap: parseFloat(style.columnGap), slots: Number(root.dataset.panelSlots), columns: style.gridTemplateColumns.split(/\s+/).length,
          panes, overflow: document.documentElement.scrollWidth > innerWidth, pageHeight: document.documentElement.scrollHeight, height: innerHeight,
          navWidth: document.querySelector("#bottom-nav").getBoundingClientRect().width, dock: box(root.querySelector("[data-agent-dock]")) };
      })).jsonValue();
      const n = capacity(g.viewport), expected = (g.contentWidth - (n - 1) * 12) / n;
      const kinds = n === 1 ? [open.at(-1) || "conversation"] : ["conversation", ...open.slice(-(n - 1))];
      assert.equal(g.slots, n); assert.equal(g.columns, n, "no implicit grid tracks");
      assert.equal(g.gap, 12);
      assert.deepEqual(g.panes.map(p => p.kind), kinds, JSON.stringify({ open, g }));
      g.panes.forEach((p, i) => {
        assert(Math.abs(p.width - expected) < 1.1, JSON.stringify({ expected, p, g }));
        assert(Math.abs(p.x - (g.root.x + i * (expected + 12))) < 1.1, "occupied slots stay left aligned");
      });
      assert(Math.abs(g.dock.width - expected) < 1.1 && Math.abs(g.dock.x - g.root.x) < 1.1, `composer stays in the Conversation slot: ${JSON.stringify({ expected, g })}`);
      assert(g.height - g.dock.bottom >= (width >= 900 ? 11 : 0), `medium and wide panels keep a bottom gap without changing narrow layouts: ${JSON.stringify(g)}`);
      const last = g.panes.at(-1);
      assert(Math.abs((g.root.right - last.right) - (n - kinds.length) * (expected + 12)) < 1.1, "unused slots remain space on the right");
      assert(!g.overflow && g.pageHeight <= g.height + 1, JSON.stringify(g));
      assert.equal(await page.locator("#prompt-input").inputValue(), "Retain the fixed-slot draft");
      return g;
    };
    for (const rail of width >= 1100 ? ["compact", "expanded", "none"] : ["none"]) {
      let previous;
      let readingTop;
      for (const open of [[], ["focus"], ["focus", "summary"], ["summary", "focus"], ["focus", "pull-requests"]]) {
        await setPanels(open, rail);
        const g = await measure(open);
        if (width >= 900 && rail === "compact") {
          const reading = await page.locator('[data-agent-conversation-scroll]').evaluate((e, first) => {
            if (first) e.scrollTop = e.scrollHeight;
            return { top: e.scrollTop, height: e.clientHeight, total: e.scrollHeight, width: e.clientWidth, dock: document.querySelector("[data-agent-dock]").getBoundingClientRect().height };
          }, readingTop === undefined);
          if (readingTop !== undefined) assert(Math.abs(reading.top - readingTop.top) <= 12, `fixed slots preserve reading: ${JSON.stringify({ width, rail, open, reading, readingTop })}`);
          readingTop = reading;
        }
        results.push({ theme, rail, open, ...g });
        if (previous) assert(Math.abs(previous.panes[0].width - g.panes[0].width) < 1.1, `panel width does not change with open count: ${JSON.stringify({ rail, open, previous, g })}`);
        previous = g;
        if (captureDir && theme === "dark" && rail === "compact" && width === 1920 && open.join(" ") === "focus") {
          fs.mkdirSync(captureDir, { recursive: true });
          await page.screenshot({ path: path.join(captureDir, "fixed-slots-large-two-panels.png") });
        }
        if (captureDir && theme === "dark" && rail === "compact" && width === 1920 && !open.length) await page.screenshot({ path: path.join(captureDir, "fixed-slots-large-one-panel.png") });
        if (captureDir && theme === "dark" && rail === "none" && width === 901 && !open.length) {
          fs.mkdirSync(captureDir, { recursive: true });
          await page.screenshot({ path: path.join(captureDir, "fixed-slots-medium-one-panel.png") });
        }
      }
    }
    await setPanels(["focus", "summary"], "compact");
    if (capacity(width) === 2) {
      assert.equal(await page.locator('[data-side-kind="focus"]').isVisible(), false, "medium keeps newest Summary; it does not squeeze a third panel");
      assert.equal(await page.locator('[data-side-kind="summary"]').isVisible(), true);
    }
    await setPanels(["summary", "focus"], "compact");
    await page.locator('[data-focus-section]').nth(1).click();
    await page.locator('.agent-focus-attachments button[data-preview-summary-attachment]').click();
    await page.locator('.summary-attachment-preview-scroll[aria-busy="false"]').waitFor({ state: "visible" });
    assert.deepEqual(await page.locator('[data-side-kind]').evaluateAll(es => es.map(e => e.dataset.sideKind)), ["focus", "attachment"]);
    assert.equal(await page.locator('[data-focus-section]').nth(1).getAttribute("aria-expanded"), "false");
    await measure(["focus", "attachment"]);
    await page.evaluate(() => refresh({ force: true }));
    await measure(["focus", "attachment"]);
    assert.equal(await page.locator('[data-focus-section]').nth(1).getAttribute("aria-expanded"), "false");
    if (captureDir && width === 1920 && theme === "dark") await page.screenshot({ path: path.join(captureDir, "fixed-slots-large-three-panels.png") });
    await setPanels(["focus", "summary"], "compact");
    await page.locator('[data-side-kind="summary"] button[data-preview-summary-attachment]').click();
    await page.locator('.summary-attachment-preview-scroll[aria-busy="false"]').waitFor({ state: "visible" });
    assert.deepEqual(await page.locator('[data-side-kind]').evaluateAll(es => es.map(e => e.dataset.sideKind)), ["summary", "attachment"]);
    await measure(["summary", "attachment"]);
    if (width >= 900) {
      await setPanels(["summary"], "compact");
      await page.evaluate(key => setAgentDetailViewMode(`${key}:summary`, "full"), agentKey);
      const full = await page.evaluate(() => {
        const root = document.querySelector("[data-agent-workspace]"), pane = root.querySelector('[data-side-kind="summary"]');
        return { root: root.getBoundingClientRect().toJSON(), pane: pane.getBoundingClientRect().toJSON(), slots: Number(root.dataset.panelSlots) };
      });
      assert(Math.abs(full.pane.width - (full.root.width - 12 * (full.slots - 1)) / full.slots) < 1.1 && Math.abs(full.pane.x - full.root.x) < 1.1, "detail-only retains the fixed slot width and left alignment");
      assert.equal(await page.locator(".agent-conversation-pane").isVisible(), false);
      assert.equal(await page.locator('[data-view-mode="wide"]').count(), 0, "fixed slots do not offer a conflicting widen action");
      await page.evaluate(key => setAgentDetailViewMode(`${key}:summary`, "balanced"), agentKey);
    }
    if (width === 1440 && theme === "dark") {
      await setPanels(["summary", "focus"], "compact");
      await page.evaluate(() => {
        document.querySelector(".app-shell").style.removeProperty("grid-template-columns");
        document.querySelector(".app-header").style.removeProperty("grid-column");
        document.querySelector("#view").style.removeProperty("grid-column");
        document.querySelector("#bottom-nav").style.removeProperty("display");
        document.querySelector(".sidebar-settings-link").style.removeProperty("display");
      });
      await page.setViewportSize({ width: 1439, height: 900 }); await measure(["summary", "focus"]);
      await page.setViewportSize({ width: 899, height: 900 }); await measure(["summary", "focus"]);
      await page.locator('.side-conversation-controls [data-side-conversation="conversation"]').click();
      await measure([]);
      await page.setViewportSize({ width: 1440, height: 900 }); await measure(["summary", "focus"]);
      await page.setViewportSize({ width: 899, height: 900 }); await measure([]);
      assert.deepEqual(await page.evaluate(key => state.agentSidePanels.get(key).open, agentKey), ["summary", "focus"], "resize preserves requested panels and the small-screen Conversation choice");
    }
    assert.deepEqual(errors, []);
    await context.close();
  }
  const cold = await api.request.post(`${baseUrl}/agents`, { data: { project_key: "web", template_key: "custom", name: "Conversation only fixture", prompt: "No Focus", start: false } });
  assert(cold.ok(), await cold.text());
  const coldKey = (await cold.json()).agent.key;
  const coldPage = await api.newPage();
  await coldPage.setViewportSize({ width: 1440, height: 900 });
  await coldPage.goto(`${baseUrl}/ui#agent/${coldKey}`, { waitUntil: "networkidle" });
  await coldPage.waitForFunction(() => document.querySelector('[data-agent-workspace]')?.dataset.panelSlots === "3");
  const coldGeometry = await coldPage.evaluate(() => {
    const root = document.querySelector('[data-agent-workspace]');
    return { width: root.clientWidth, pane: root.querySelector('.agent-conversation-pane').getBoundingClientRect().width, dock: root.querySelector('[data-agent-dock]').getBoundingClientRect().width };
  });
  assert(Math.abs(coldGeometry.pane - (coldGeometry.width - 24) / 3) < 1.1 && Math.abs(coldGeometry.dock - coldGeometry.pane) < 1.1, "a cold Conversation with no Focus also occupies one third");
  // Shared-shell navigation must release workspace sizing and retain usable controls.
  const pageWidths = [];
  for (const width of [390, 900, 1440, 1920]) {
    await coldPage.setViewportSize({ width, height: 900 });
    for (const route of ["agents", "projects", "schedules", "attachments", "settings"]) {
      await coldPage.goto(`${baseUrl}/ui#${route}`, { waitUntil: "networkidle" });
      await coldPage.waitForFunction(() => !document.querySelector("[data-agent-workspace]") && document.querySelector("#view")?.textContent.trim());
      const g = await coldPage.evaluate(() => {
        const content = document.querySelector("#view"), r = content.getBoundingClientRect();
        const controls = [...content.querySelectorAll("button,input,select,textarea")].filter(e => e.getClientRects().length && getComputedStyle(e).visibility !== "hidden");
        return { width: innerWidth, content: r.toJSON(), overflow: document.documentElement.scrollWidth > innerWidth + 1,
          clipped: controls.filter(e => { const b = e.getBoundingClientRect(); return b.left < -1 || b.right > innerWidth + 1; }).map(e => e.getAttribute("aria-label") || e.textContent.trim().slice(0, 80)) };
      });
      assert(!g.overflow && g.content.width > 0, `shared page bounds: ${JSON.stringify({ route, g })}`);
      const clippedControls = coldPage.locator("#view button,#view input,#view select,#view textarea");
      for (let i = 0; i < await clippedControls.count(); i++) {
        const control = clippedControls.nth(i);
        if (!(await control.isVisible())) continue;
        const bounds = await control.boundingBox();
        if (!bounds || (bounds.x >= -1 && bounds.x + bounds.width <= width + 1)) continue;
        // Settings navigation intentionally scrolls horizontally. Prove each offscreen tab is reachable.
        await control.scrollIntoViewIfNeeded();
        const reachable = await control.evaluate(e => {
          const r = e.getBoundingClientRect();
          return r.left >= -1 && r.right <= innerWidth + 1 && e.contains(document.elementFromPoint(r.x + r.width / 2, r.y + r.height / 2));
        });
        assert(reachable, `shared page control cannot be reached: ${route} ${await control.textContent()}`);
      }
      pageWidths.push({ route, ...g });
    }
  }
  await api.close();
  if (captureDir) fs.writeFileSync(path.join(captureDir, "shared-page-geometry.json"), JSON.stringify(pageWidths, null, 2));
  if (captureDir) fs.writeFileSync(path.join(captureDir, "fixed-slots-geometry.json"), JSON.stringify(results, null, 2));
  console.log(JSON.stringify({ engine: browser.browserType().name(), arrangements: results.length, breakpoints: [900, 1440], gap: 12 }));
};
