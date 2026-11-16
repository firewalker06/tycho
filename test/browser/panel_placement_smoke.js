const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");

module.exports = async ({ browser, baseUrl, agentKey, captureDir, metadataFixture }) => {
  const api = await browser.newContext();
  const added = await api.request.post(`${baseUrl}/agents/${agentKey}/messages`, { data: {
    prompt: "Synthetic panel file", start: false,
    attachments: [{ filename: "panel.md", title: "Panel evidence", content_type: "text/markdown", content_base64: Buffer.from("# Panel evidence\n\n" + "Content scrolls inside the panel.\n\n".repeat(100)).toString("base64") }],
  } });
  assert(added.ok(), await added.text());
  const agent = (await (await api.request.get(`${baseUrl}/agents/${agentKey}`)).json()).agent;
  const file = agent.attachments.find(a => a.title === "Panel evidence");
  const stored = JSON.parse(fs.readFileSync(path.join(metadataFixture.logsDir, "managed_agents.json"))).find(a => a.key === agentKey);
  fs.appendFileSync(stored.log_path.replace(/\.raw\.log$/, ".memory.jsonl"), JSON.stringify({ type: "run_summary", content: "Panel layout review. Keep the source beside the attachment.", status: "success", created_at: new Date().toISOString(),
    metadata: { summary_id: "panel-layout", run_number: 1, attachments: [file] } }) + "\n");
  const focus = (await (await api.request.get(`${baseUrl}/agents/${agentKey}/focus`)).json()).focus;
  const updated = await api.request.put(`${baseUrl}/agents/${agentKey}/focus`, { data: { revision: focus.revision, sections: [{ title: "Panel work", items: [{ title: "Keep this source", attachments: [
    { type: "file", title: "Panel evidence", path: file.path },
    { type: "link", title: "Ordinary external link", url: "https://example.com/panel" },
  ] }] }, { title: "Next actions", items: [{ title: "Review the result" }] }, { title: "Notes", items: [{ title: "Keep the context" }] }] } });
  assert(updated.ok(), await updated.text());
  const facts = [];
  for (const width of [1800, 1440, 1024, 390, 320]) for (const theme of ["dark", "light"]) {
    const context = await browser.newContext({ viewport: { width, height: 900 }, isMobile: width < 900, hasTouch: width < 900 });
    const page = await context.newPage();
    const errors = [];
    page.on("pageerror", e => errors.push(e.message));
    await page.goto(`${baseUrl}/ui#settings`, { waitUntil: "networkidle" });
    await page.locator("[data-appearance-preference]").selectOption(theme);
    await page.goto(`${baseUrl}/ui#agent/${agentKey}`, { waitUntil: "networkidle" });
    await page.locator("[data-agent-focus]").waitFor({ state: width < 900 ? "attached" : "visible" });
    await page.waitForFunction(() => document.querySelector("[data-agent-workspace]")?.clientWidth > 0);
    const initial = await page.locator("[data-agent-workspace]").evaluate(e => ({ width: e.clientWidth, focus: e.querySelector(".agent-detail-pane").clientWidth }));
    if (width >= 1440) {
      await page.locator('.agent-focus-attachments a[data-preview-summary-attachment]').click();
      await page.locator('.summary-attachment-preview-scroll[aria-busy="false"]').waitFor({ state: "visible" });
      assert.deepEqual(await page.locator('[data-side-kind]').evaluateAll(es => es.map(e => e.dataset.sideKind)), ["focus", "attachment"]);
    }
    await page.goto(`${baseUrl}/ui#agent/${agentKey}/summary`, { waitUntil: "networkidle" });
    await page.locator("[data-side-workspace]").waitFor();
    await page.locator("#prompt-input").fill("Preserve this draft");
    const setPanels = async open => {
      await page.evaluate(({ key, open }) => {
        state.summaryAttachmentPreview = null;
        state.agentSidePanels.get(key).open = open;
        state.agentSidePanels.get(key).mobileConversation = false;
        render();
      }, { key: agentKey, open });
      await page.evaluate(() => new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve))));
    };
    const geometry = () => page.evaluate(() => {
      const rect = e => { const r = e.getBoundingClientRect(); return { x: r.x, right: r.right, top: r.top, bottom: r.bottom, width: r.width }; };
      return { width: innerWidth, height: innerHeight, page: document.documentElement.scrollHeight, overflow: document.documentElement.scrollWidth > innerWidth,
        header: rect(document.querySelector(".app-header")), workspace: rect(document.querySelector("[data-agent-workspace]")),
        panes: [...document.querySelectorAll(".agent-conversation-pane,[data-side-kind]")].filter(e => e.getClientRects().length && getComputedStyle(e).display !== "none").map(e => ({ kind: e.dataset.sideKind || "conversation", ...rect(e) })) };
    });
    await setPanels(["focus"]);
    const headings = page.locator("[data-focus-section]");
    assert.equal(await headings.count(), 3);
    const bulk = page.locator("[data-focus-bulk]");
    const expanded = () => headings.evaluateAll(es => es.map(e => e.getAttribute("aria-expanded") === "true"));
    const assertDisclosure = async (expected, visible = true) => {
      assert.deepEqual(await expanded(), expected);
      assert.equal(await bulk.innerText(), expected.some(Boolean) ? "Collapse all" : "Expand all");
      assert.deepEqual(await headings.evaluateAll((es, visible) => es.map(e => {
        const items = document.getElementById(e.getAttribute("aria-controls"));
        return e.querySelector(".agent-focus-chevron svg") && items && items.hidden === (e.getAttribute("aria-expanded") === "false") && (!visible || e.getBoundingClientRect().height > 0);
      }), visible), [true, true, true]);
    };
    await assertDisclosure([true, true, true]);
    await headings.nth(0).click();
    await assertDisclosure([false, true, true]);
    await headings.nth(0).focus();
    await page.evaluate(() => refresh({ force: true }));
    await assertDisclosure([false, true, true]);
    assert.equal(await headings.nth(0).evaluate(e => e === document.activeElement), true, "section focus survives polling");
    await headings.nth(0).press("Space");
    await assertDisclosure([true, true, true]);
    await headings.nth(0).press("Enter");
    await assertDisclosure([false, true, true]);
    if (captureDir && [1800, 390].includes(width)) {
      fs.mkdirSync(captureDir, { recursive: true });
      await page.screenshot({ path: path.join(captureDir, `focus-mixed-${width}-${theme}.png`) });
    }
    await bulk.click();
    await assertDisclosure([false, false, false]);
    await page.evaluate(() => refresh({ force: true }));
    await assertDisclosure([false, false, false]);
    if (captureDir && [1800, 390].includes(width)) await page.screenshot({ path: path.join(captureDir, `focus-collapsed-${width}-${theme}.png`) });
    await bulk.press("Enter");
    await assertDisclosure([true, true, true]);
    await headings.nth(1).click();
    await bulk.click();
    await assertDisclosure([false, false, false]);
    await bulk.press("Space");
    await assertDisclosure([true, true, true]);
    await headings.nth(1).click();
    const widths = [];
    for (const open of [["focus"], ["summary"], ["focus", "summary"], ["summary", "focus"], ["focus", "pull-requests"], ["pull-requests", "focus"]]) {
      await setPanels(open);
      const g = await geometry();
      facts.push({ theme, open, ...g });
      if (captureDir && width === 1800 && theme === "dark" && open[0] === "focus") {
        fs.mkdirSync(captureDir, { recursive: true });
        await page.screenshot({ path: path.join(captureDir, `panels-${open.join("-")}-${width}-${theme}.png`) });
      }
      assert(!g.overflow && g.page <= g.height + 1, JSON.stringify(g));
      assert(g.workspace.top >= g.header.bottom - 1, JSON.stringify(g));
      if (width >= 1440) {
        assert.equal(g.panes.length, open.length + 1);
        const panels = g.panes;
        for (let i = 1; i < panels.length; i++) assert(panels[i].x >= panels[i - 1].right, JSON.stringify(g));
        if (open.length === 1) widths.push(panels.map(p => p.width));
        else assert(Math.max(...panels.map(p => p.width)) - Math.min(...panels.map(p => p.width)) < 2, JSON.stringify(g));
      }
    }
    if (width >= 1440) {
      const shared = await page.locator("[data-agent-workspace]").evaluate(e => e.clientWidth);
      assert(Math.abs(initial.width - shared) < 2, `initial Focus uses the same shell width as side panels: ${JSON.stringify({ initial, shared, width })}`);
      assert(Math.abs(initial.focus - widths[0][1]) < 2, "initial and shared Focus use identical columns");
    }
    if (width >= 1440) assert(widths[0].every((v, i) => Math.abs(v - widths[1][i]) < 2), "Focus and Summary have identical sizing");
    for (const source of ["focus", "summary"]) for (const open of [[source], [source, source === "focus" ? "summary" : "focus"], [source === "focus" ? "summary" : "focus", source], ["pull-requests", source], [source, "pull-requests"]]) {
      await setPanels(open);
      // On constrained screens the newest peer is visible; show the source as a user would with its tab.
      if (!(await page.locator(`[data-side-kind="${source}"]`).isVisible())) await setPanels([...open.filter(k => k !== source), source]);
      if (source === "focus") {
        const external = page.locator('.agent-focus-attachments a[target="_blank"]');
        assert.equal(await external.getAttribute("href"), "https://example.com/panel");
        await page.locator('.agent-focus-attachments a[data-preview-summary-attachment]').click();
      } else {
        await page.locator('[data-side-kind="summary"] .summary-attachment-row').click();
      }
      await page.locator('.summary-attachment-preview-scroll[aria-busy="false"]').waitFor({ state: "visible" });
      assert.deepEqual(await page.locator('[data-side-kind]').evaluateAll(es => es.map(e => e.dataset.sideKind)), [source, "attachment"]);
      assert.equal(await page.locator(".agent-conversation-pane").count(), 1);
      if (source === "focus") await assertDisclosure([true, false, true], width >= 1440);
      if (source === "focus" && open.length === 1 && width >= 1440) {
        await bulk.click();
        await assertDisclosure([false, false, false]);
        assert.equal(await page.locator(".summary-attachment-preview-pane").isVisible(), true, "collapsing the source must keep the attachment open");
        if (captureDir && width === 1800) await page.screenshot({ path: path.join(captureDir, `focus-attachment-collapsed-${width}-${theme}.png`) });
        await bulk.click();
        await assertDisclosure([true, true, true]);
        await headings.nth(1).click();
        await assertDisclosure([true, false, true]);
      }
      const g = await geometry();
      assert(!g.overflow && g.page <= g.height + 1, JSON.stringify(g));
      if (width >= 1440) assert.deepEqual(g.panes.map(p => p.kind), ["conversation", source, "attachment"]);
      assert.equal(await page.locator("#prompt-input").inputValue(), "Preserve this draft");
      assert.equal(await page.locator('[data-close-summary-attachment-preview]:visible').count(), 0);
      const previewId = await page.locator('.summary-attachment-preview-pane').getAttribute("data-state-key");
      await page.evaluate(() => refresh({ force: true }));
      assert.equal(await page.locator('.summary-attachment-preview-pane').getAttribute("data-state-key"), previewId);
      assert.deepEqual(await page.locator('[data-side-kind]').evaluateAll(es => es.map(e => e.dataset.sideKind)), [source, "attachment"]);
      if (captureDir && open.length === 1 && [1800, 390].includes(width)) {
        fs.mkdirSync(captureDir, { recursive: true });
        await page.screenshot({ path: path.join(captureDir, `panels-${source}-${width}-${theme}.png`) });
      }
    }
    assert.deepEqual(errors, []);
    await context.close();
  }
  if (captureDir) fs.writeFileSync(path.join(captureDir, "panel-geometry.json"), JSON.stringify(facts, null, 2));
  await api.close();
};
