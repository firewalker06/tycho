const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");

module.exports = async ({ browser, baseUrl, agentKey, captureDir }) => {
  const results = [];
  for (const [width, height] of [[390, 844], [320, 740], [844, 390], [932, 430]]) {
    const context = await browser.newContext({ viewport: { width, height }, isMobile: true, hasTouch: true });
    // This models the VisualViewport contract. Headless engines do not show a real OS keyboard or browser toolbar.
    await context.addInitScript(() => {
      const viewport = window.visualViewport;
      let model = null;
      Object.defineProperties(viewport, {
        height: { configurable: true, get: () => model?.height ?? innerHeight },
        offsetTop: { configurable: true, get: () => model?.top ?? 0 },
      });
      window.setTestVisualViewport = next => { model = next; viewport.dispatchEvent(new Event("resize")); viewport.dispatchEvent(new Event("scroll")); };
    });
    const page = await context.newPage();
    const errors = [];
    page.on("pageerror", e => errors.push(e.message));
    const created = await context.request.post(`${baseUrl}/agents`, { data: { project_key: "web", template_key: "custom", name: "Mobile prompt fixture", prompt: "QUEUE_SMOKE_HOLD", start: false } });
    assert(created.ok(), await created.text());
    const key = (await created.json()).agent.key;
    try {
      await page.goto(`${baseUrl}/ui#agent/${key}/summary`, { waitUntil: "networkidle" });
      await page.locator("[data-side-workspace]").waitFor();
      const draft = Array.from({ length: 70 }, (_, i) => `Draft line ${i + 1}: Keep the full prompt and make every form action reachable.`).join("\n\n");
      await page.locator("#prompt-input").fill(draft);
      await page.locator("#prompt-input").focus();
      const check = async stage => {
        await page.evaluate(() => new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(() => requestAnimationFrame(resolve)))));
        const g = await page.evaluate(() => {
          const box = e => e?.getBoundingClientRect().toJSON() || null;
          const input = document.querySelector("#prompt-input"), dock = document.querySelector("[data-agent-dock]");
          const row = document.querySelector("#composer .send-row");
          return { viewport: { top: visualViewport.offsetTop, bottom: visualViewport.offsetTop + visualViewport.height, height: visualViewport.height },
            windowHeight: innerHeight, header: box(document.querySelector(".app-header")), dock: box(dock), input: box(input), row: box(row),
            submit: box(document.querySelector('#composer button[type="submit"]')), dockScroll: dock.scrollTop, dockClient: dock.clientHeight, dockContent: dock.scrollHeight,
            inputClient: input.clientHeight, inputContent: input.scrollHeight, pageScroll: scrollY, pageWidth: document.documentElement.scrollWidth, width: innerWidth,
            buttons: [...row.querySelectorAll("button,summary")].filter(e => e.getClientRects().length).map(box) };
        });
        results.push({ stage, width, height, ...g });
          assert(g.submit.top >= g.viewport.top - 1 && g.submit.bottom <= g.viewport.bottom + 1, `Submit outside visible viewport: ${JSON.stringify(g)}`);
          assert(g.buttons.every(b => b.top >= g.viewport.top - 1 && b.bottom <= g.viewport.bottom + 1), `Prompt tools outside visible viewport: ${JSON.stringify(g)}`);
          assert(g.row.top >= g.dock.top - 1 && g.row.bottom <= g.dock.bottom + 1, `Actions clipped by dock: ${JSON.stringify(g)}`);
          assert(g.pageWidth <= g.width + 1 && g.inputContent > g.inputClient, "long draft scrolls inside bounded textarea without horizontal overflow");
          assert.equal(await page.locator("#prompt-input").inputValue(), draft);
        if (captureDir) {
          fs.mkdirSync(captureDir, { recursive: true });
          await page.screenshot({ path: path.join(captureDir, `mobile-prompt-${stage}-${width}-${browser.browserType().name()}.png`), clip: { x: 0, y: g.viewport.top, width: g.width, height: Math.min(g.viewport.height, g.windowHeight - g.viewport.top) } });
        }
        return g;
      };
      await check("long-draft");
      const model = width < 900 && height > 500 ? { top: height - 320, height: 260 } : { top: 0, height: 230 };
      await page.evaluate(model => setTestVisualViewport(model), model);
      await check("keyboard-model");
      await page.evaluate(() => refresh({ force: true }));
      await check("polling");
      await page.evaluate(() => { document.documentElement.style.setProperty("--safe-area-top", "12px"); document.documentElement.style.setProperty("--safe-area-bottom", "20px"); });
      await check("safe-insets");
      // Editor controls can share one row for a short editor and remain reachable through dock scrolling.
      const editorControls = page.locator("#composer .composer-editor-shell button");
      const editorCount = await editorControls.count();
      for (let i = 0; i < editorCount; i++) {
        if (!(await editorControls.nth(i).isVisible())) continue;
        await editorControls.nth(i).scrollIntoViewIfNeeded();
        const dock = page.locator("[data-agent-dock]");
        const maxScroll = await dock.evaluate(e => e.scrollHeight - e.clientHeight);
        let control;
        for (let scroll = 0; scroll <= maxScroll + 12; scroll += 12) {
          await dock.evaluate((e, value) => { e.scrollTop = value; }, Math.min(scroll, maxScroll));
          control = await editorControls.nth(i).evaluate(e => {
          const r = e.getBoundingClientRect(), hit = document.elementFromPoint(r.x + r.width / 2, r.y + r.height / 2);
          return { rect: r.toJSON(), top: visualViewport.offsetTop, bottom: visualViewport.offsetTop + visualViewport.height, hit: hit?.outerHTML?.slice(0, 200), ownHit: e.contains(hit), label: e.getAttribute("aria-label") };
          });
          if (control.ownHit && control.rect.top >= control.top - 1 && control.rect.bottom <= control.bottom + 1) break;
        }
        assert(control.rect.top >= control.top - 1 && control.rect.bottom <= control.bottom + 1 && control.ownHit, JSON.stringify({ width, control }));
      }
      await check("editor-controls");
      await page.locator('#composer button[type="submit"]').focus();
      assert(await page.locator('#composer button[type="submit"]').evaluate(e => e === document.activeElement), "Submit accepts keyboard focus");
      const started = await context.request.post(`${baseUrl}/agents/${key}/start`, { data: {} });
      assert(started.ok(), await started.text());
      await page.evaluate(() => refresh({ force: true }));
      const live = (await (await context.request.get(`${baseUrl}/agents/${key}`)).json()).agent;
      assert(live.running && live.pid > 0, "running fixture uses a real isolated held harness");
      const stop = page.locator('[data-agent-floating-actions] [data-agent-action="stop"]');
      await stop.waitFor({ state: "visible" });
      await check("running-keyboard-model");
      const beforeStop = await stop.boundingBox();
      await page.locator(".side-conversation-controls").evaluate(e => { e.scrollLeft = e.scrollWidth; });
      const afterStop = await stop.boundingBox();
      assert(Math.abs(beforeStop.x - afterStop.x) < 1, "Stop stays fixed while tabs scroll");
      await stop.click();
      await stop.waitFor({ state: "hidden" });
      assert.equal((await (await context.request.get(`${baseUrl}/agents/${key}`)).json()).agent.running, false);
      await check("stopped-keyboard-model");
      await page.evaluate(() => setTestVisualViewport(null));
      await page.setViewportSize({ width, height: Math.max(300, height - 90) });
      await check("browser-chrome-resize");
      await page.setViewportSize({ width, height });
      await page.evaluate(() => { document.documentElement.style.removeProperty("--safe-area-top"); document.documentElement.style.removeProperty("--safe-area-bottom"); setTestVisualViewport(null); });
      await check("restored");
      await page.setViewportSize({ width: height, height: width });
      await check("orientation-change");
      assert.deepEqual(errors, []);
    } finally { await context.request.post(`${baseUrl}/agents/${key}/stop`, { data: {} }); await context.close(); }
  }
  console.log(JSON.stringify({ engine: browser.browserType().name(), cases: results.length, limits: "Viewport sizes, synthetic visualViewport events and CSS safe insets; no native OS keyboard or toolbar." }));
  if (captureDir) fs.writeFileSync(path.join(captureDir, "mobile-prompt-geometry.json"), JSON.stringify({ engine: browser.browserType().name(), limits: "Real browser layout with synthetic visualViewport events and safe-area CSS variables; no native OS keyboard or toolbar.", results }, null, 2));
};
