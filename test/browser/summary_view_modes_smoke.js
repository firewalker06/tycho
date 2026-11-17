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
  for (const width of [1920, 1440, 1439, 900, 899, 390]) for (const theme of ["dark", "light"]) {
    const context = await browser.newContext({ viewport: { width, height: 900 }, isMobile: width < 900, hasTouch: width < 900 });
    const page = await context.newPage();
    const errors = [];
    page.on("pageerror", error => errors.push(error.message));
    const url = `${baseUrl}/ui#agent/${agentKey}/summary`;
    await page.goto(url, { waitUntil: "networkidle" });
    await page.evaluate(theme => window.TychoAppearance.setPreference(theme), theme);
    const draft = "Retain this Summary layout draft.\n".repeat(30);
    const show = kind => page.locator(`.side-conversation-controls [data-side-conversation="${kind}"]:visible`);
    const reset = async open => {
      await page.evaluate(({ key, open }) => {
        state.summaryAttachmentPreview = null;
        state.agentDetailViewMode[`${key}:summary`] = "balanced";
        state.prDiffFullViewMode[key] = false;
        const panel = state.agentSidePanels.get(key);
        panel.open = open; panel.mobileConversation = false;
        render();
      }, { key: agentKey, open });
      await page.locator("#prompt-input").fill(draft);
      await page.evaluate(() => new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve))));
    };
    let currentScenario = "";
    const choose = async mode => {
      try {
        if (width >= 900 && mode !== "wide") {
          await page.locator("[data-focused-view-menu] > summary").click();
          await page.locator(`[data-view-mode="${mode}"]`).click();
        } else {
          // Wide is a saved legacy mode; mobile has no layout menu. Exercise the same state transition.
          await page.evaluate(({ key, mode }) => setAgentDetailViewMode(`${key}:summary`, mode), { key: agentKey, mode });
        }
      } catch (error) { throw new Error(`${width}/${theme}/${currentScenario}/${mode}: ${error.message}`); }
    };
    const visibleSummary = async (stage, mode) => {
      // Inspect immediately after the action, with no retoggle, polling or resize to repair it.
      const g = await page.evaluate(() => {
        const pane = document.querySelector('[data-side-kind="summary"]');
        const text = [...(pane?.querySelectorAll("p") || [])].find(p => p.textContent.includes("Fixed panel slots"));
        const root = document.querySelector("[data-agent-workspace]");
        const p = pane?.getBoundingClientRect(), t = text?.getBoundingClientRect(), r = root.getBoundingClientRect();
        const hit = t && document.elementFromPoint(t.x + t.width / 2, t.y + t.height / 2);
        const style = getComputedStyle(root), slots = Number(root.dataset.panelSlots);
        return { pane: p?.toJSON(), text: t?.toJSON(), hit: Boolean(text?.contains(hit)), root: r.toJSON(), slots,
          contentWidth: root.clientWidth - parseFloat(style.paddingLeft) - parseFloat(style.paddingRight),
          open: [...state.agentSidePanels.get(parseRoute().key).open], preview: Boolean(state.summaryAttachmentPreview),
          overflow: document.documentElement.scrollWidth > innerWidth + 1,
          conversation: Boolean(document.querySelector("[data-agent-conversation-pane]")?.getClientRects().length), mode: agentDetailViewMode(`${parseRoute().key}:summary`) };
      });
      assert(g.text?.height > 0 && g.text.top >= g.root.top - 1 && g.text.bottom <= 900 && g.hit,
        `Summary content disappeared: ${JSON.stringify({ width, theme, stage, mode, g })}`);
      assert.equal(g.open.at(-1), "summary", "the layout action requests Summary as the newest peer");
      assert(!g.open.includes("attachment") && !g.preview, "a dismissed preview cannot leave an empty selected peer");
      assert(Math.abs(g.pane.width - (g.contentWidth - 12 * (g.slots - 1)) / g.slots) < 1.1 && !g.overflow, "layout modes preserve fixed fractional widths");
      assert.equal(g.conversation, width >= 900 && mode !== "full");
      assert.equal(await page.locator("#prompt-input").inputValue(), draft);
      return g;
    };
    const scenarios = [
      { name: "Summary alone", open: ["summary"] },
      { name: "Focus before Summary", open: ["focus", "summary"] },
      { name: "Focus after Summary", open: ["summary", "focus"] },
      { name: "PRs before Summary", open: ["pull-requests", "summary"] },
      { name: "PRs after Summary", open: ["summary", "pull-requests"] },
      { name: "Summary file", source: "summary", open: ["summary"] },
      { name: "Focus file replaces Summary", source: "focus", open: ["summary"] },
    ];
    for (const scenario of scenarios) for (const mode of ["balanced", "wide", "full"]) {
      currentScenario = scenario.name;
      await reset(scenario.open);
      if (scenario.source) {
        if (scenario.source === "focus") await show("focus").click();
        const source = scenario.source === "focus" ? '.agent-focus-attachments a[data-preview-summary-attachment]' : '[data-side-kind="summary"] button[data-preview-summary-attachment]';
        await page.locator(source).click();
        await page.locator('.summary-attachment-preview-scroll[aria-busy="false"]').waitFor({ state: "visible" });
        assert.deepEqual(await page.locator('[data-side-kind]').evaluateAll(es => es.map(e => e.dataset.sideKind)), [scenario.source, "attachment"]);
      }
      await choose(mode);
      const g = await visibleSummary(scenario.name, mode);
      results.push({ width, theme, scenario: scenario.name, ...g });
      await page.evaluate(() => refresh({ force: true }));
      await visibleSummary(`${scenario.name} after polling`, mode);
      if (captureDir && mode === "full" && scenario.source === "focus" && [1920, 390].includes(width)) {
        fs.mkdirSync(captureDir, { recursive: true });
        await page.screenshot({ path: path.join(captureDir, `summary-full-${width}-${theme}.png`) });
      }
    }
    // Change modes repeatedly without rebuilding the requested peers.
    await reset(["focus", "summary"]);
    for (const mode of ["wide", "full", "balanced", "full", "wide", "balanced"]) {
      await choose(mode); await visibleSummary("mode round trip", mode);
    }
    await choose("full");
    await page.goto(`${baseUrl}/ui#settings`, { waitUntil: "networkidle" });
    await page.waitForFunction(() => !document.querySelector("[data-agent-workspace]") && state.renderedRouteKey === routeStateKey(parseRoute()));
    await page.goto(url, { waitUntil: "networkidle" });
    await page.waitForFunction(() => document.querySelector('[data-side-kind="summary"]') && state.renderedRouteKey === routeStateKey(parseRoute()));
    await visibleSummary("navigation back", "full");
    assert.deepEqual(errors, []);
    await context.close();
  }
  if (captureDir) fs.writeFileSync(path.join(captureDir, "summary-view-modes.json"), JSON.stringify(results, null, 2));
  await api.close();
  console.log(JSON.stringify({ engine: browser.browserType().name(), transitions: results.length, immediateContent: true, polling: true, navigation: true }));
};
