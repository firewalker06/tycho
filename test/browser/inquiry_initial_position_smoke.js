const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");

module.exports = async ({ browser, baseUrl, captureDir }) => {
  const key = "web-inquiry-recovery-0";
  const api = await browser.newContext();
  const focusUrl = `${baseUrl}/agents/${key}/focus`;
  const focus = (await (await api.request.get(focusUrl)).json()).focus;
  const saved = await api.request.put(focusUrl, { data: { revision: focus.revision, sections: [
    { title: "Synthetic review", items: Array.from({ length: 20 }, (_, index) => ({ title: `Synthetic Focus item ${index + 1}` })) },
  ] } });
  assert(saved.ok(), await saved.text());
  await api.close();
  const results = [];
  const frames = page => page.evaluate(() => new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve))));
  const measure = page => page.evaluate(() => {
    const box = selector => {
      const e = document.querySelector(selector);
      const r = e.getBoundingClientRect();
      return { top: r.top, bottom: r.bottom, height: r.height, scrollTop: e.scrollTop,
        scrollHeight: e.scrollHeight, clientHeight: e.clientHeight, rows: getComputedStyle(e).gridTemplateRows };
    };
    return { viewport: { width: innerWidth, height: innerHeight }, route: location.hash,
      form: box("#inquiry-form"), content: box(".inquiry-form-content"), banner: box(".inquiry-banner"),
      fields: box(".inquiry-fields"), first: box("#inquiry-form [data-inquiry-control]"),
      dock: box("[data-agent-dock]"), conversation: box(".agent-conversation-pane"),
      toggles: Object.fromEntries(["focus", "summary"].map(kind => [kind,
        document.querySelector(`[data-side-conversation="${kind}"]`).getAttribute("aria-pressed")])),
      visiblePeers: [...document.querySelectorAll("[data-side-kind]")].filter(e => e.getClientRects().length).map(e => e.dataset.sideKind),
      summaryId: state.agentSidePanels.get("web-inquiry-recovery-0").summaryId,
      staleNotice: document.querySelector(".summary-refresh-copy")?.textContent,
      windowScroll: scrollY, documentOverflow: document.documentElement.scrollWidth > innerWidth,
    };
  });
  const record = async (page, label) => {
    // Read before screenshots, scrolling or another refresh can repair a stale WebKit grid size.
    const geometry = await measure(page);
    results.push({ label, ...geometry });
    if (captureDir) fs.writeFileSync(path.join(captureDir, "inquiry-initial-position.json"), JSON.stringify(results, null, 2));
    return geometry;
  };
  const assertPosition = (geometry, label) => {
    const gap = geometry.fields.top - geometry.banner.bottom;
    assert(gap >= 0 && gap <= 12, `${label}: fields must follow the banner immediately: ${JSON.stringify(geometry)}`);
    assert(geometry.conversation.height > 0, `${label}: Conversation keeps visible height`);
    assert(!geometry.documentOverflow, `${label}: no horizontal document overflow`);
    assert.deepEqual(geometry.toggles, { focus: "true", summary: "true" });
    assert.deepEqual(geometry.visiblePeers, [label.includes("focus-then-summary") ? "summary" : "focus"]);
    assert.equal(geometry.summaryId, "initial-position-summary-8");
    if (label.endsWith("-normal")) {
      assert(geometry.staleNotice.includes("20 new messages"), `${label}: historical Summary stays stale`);
      assert(geometry.first.top < geometry.viewport.height, `${label}: first answer control is initially visible`);
    }
  };

  for (const height of [788, 820]) for (const open of [["focus", "summary"], ["summary", "focus"]]) {
    const label = `${height}-${open.join("-then-")}`;
    const context = await browser.newContext({ viewport: { width: 1180, height }, deviceScaleFactor: 2,
      hasTouch: true, isMobile: browser.browserType().name() === "webkit" });
    const page = await context.newPage();
    const errors = [];
    page.on("pageerror", error => errors.push(error.message));
    await page.goto(`${baseUrl}/ui#agent/${key}/summary/initial-position-summary-8`, { waitUntil: "networkidle" });
    await page.locator("#inquiry-form").waitFor({ state: "attached" });
    const toggle = kind => page.locator(`.side-conversation-controls [data-side-conversation="${kind}"]`);
    for (const kind of ["focus", "summary"]) if (await toggle(kind).getAttribute("aria-pressed") === "true") {
      await toggle(kind).click();
      await frames(page);
    }
    for (const kind of open) { await toggle(kind).click(); await frames(page); }
    await page.setViewportSize({ width: 899, height });
    await frames(page);
    await page.locator("#back-button").click();
    await frames(page);
    await page.setViewportSize({ width: 1180, height });
    await frames(page);
    // Model a reader who has kept Summary #8 while metadata reports twenty newer messages.
    await page.evaluate(key => {
      const conversation = state.conversations[key];
      const blocks = conversation.blocks;
      const index = blocks.findIndex(block => block.kind === "run_summary" && block.metadata?.run_number === 8);
      if (index < 0) throw new Error("Synthetic historical summary is missing");
      conversation.blocks = blocks.slice(0, index + 1);
      state.pendingConversationUpdates[key] = { unseenCount: 20, blockCount: conversation.total + 20, revision: "synthetic-newer" };
      render({ preserveLiveEditor: true });
    }, key);
    await frames(page);
    const normal = await record(page, `${label}-normal`);
    await page.locator("[data-toggle-inquiry-full-screen]").click();
    await frames(page);
    const expanded = await record(page, `${label}-expanded`);
    assertPosition(expanded, `${label}-expanded`);
    assertPosition(normal, `${label}-normal`);
    if (captureDir) await page.screenshot({ path: path.join(captureDir, `inquiry-initial-${label}.png`) });
    await page.locator("[data-agent-dock]").evaluate(e => { e.scrollTop += 200; });
    await frames(page);
    const scrolled = await measure(page);
    assert(scrolled.dock.scrollTop > 0 && scrolled.form.top < expanded.form.top, `${label}: the long form scrolls in its dock`);
    await page.locator("[data-agent-dock]").evaluate(e => { e.scrollTop = 0; });
    await page.evaluate(() => refresh({ force: true }));
    await frames(page);
    assertPosition(await record(page, `${label}-polled`), `${label}-polled`);
    assert.deepEqual(errors, [], `${label}: no browser errors`);
    await context.close();
  }
  console.log(JSON.stringify({ engine: browser.browserType().name(), version: browser.version(), cases: results.length }));
};
