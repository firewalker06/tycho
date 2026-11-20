const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");

module.exports = async ({ browser, baseUrl, agentKey, captureDir }) => {
  const results = [];
  for (const [width, height] of [[390, 844], [320, 740], [844, 390], [932, 430], [1440, 900]]) {
    const mobile = width < 900;
    const context = await browser.newContext({ viewport: { width, height }, isMobile: mobile, hasTouch: mobile });
    // Model the visual viewport and iOS's keyboard pan. Headless engines do not show a real OS keyboard or browser toolbar.
    await context.addInitScript(() => {
      const viewport = window.visualViewport;
      let model = null;
      Object.defineProperties(viewport, {
        height: { configurable: true, get: () => model?.height ?? innerHeight },
        offsetTop: { configurable: true, get: () => model?.top ?? 0 },
      });
      window.setTestVisualViewport = next => {
        model = next;
        // iOS can pan the rendered page inside a non-scrolling layout viewport when the keyboard opens.
        document.body.style.transform = next?.top ? `translateY(-${next.top}px)` : "";
        viewport.dispatchEvent(new Event("resize"));
        viewport.dispatchEvent(new Event("scroll"));
      };
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
      const caret = Math.floor(draft.length / 2);
      await page.locator("#prompt-input").evaluate((input, position) => input.setSelectionRange(position, position), caret);
      const check = async stage => {
        await page.evaluate(() => new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(() => requestAnimationFrame(resolve)))));
        const g = await page.evaluate(() => {
          const box = e => e?.getBoundingClientRect().toJSON() || null;
          const input = document.querySelector("#prompt-input"), dock = document.querySelector("[data-agent-dock]");
          const row = document.querySelector("#composer .send-row");
          return { viewport: { top: 0, bottom: visualViewport.height, offsetTop: visualViewport.offsetTop, height: visualViewport.height },
            windowHeight: innerHeight, header: box(document.querySelector(".app-header")), dock: box(dock), input: box(input), row: box(row),
            dockBackground: getComputedStyle(dock).backgroundColor, dockPaddingBottom: parseFloat(getComputedStyle(dock).paddingBottom),
            safeAreaBottom: parseFloat(getComputedStyle(document.documentElement).getPropertyValue("--safe-area-bottom")) || 0,
            submit: box(document.querySelector('#composer button[type="submit"]')), dockScroll: dock.scrollTop, dockClient: dock.clientHeight, dockContent: dock.scrollHeight,
            inputClient: input.clientHeight, inputContent: input.scrollHeight, pageScroll: scrollY, pageWidth: document.documentElement.scrollWidth, width: innerWidth,
            buttons: [...row.querySelectorAll("button,summary")].filter(e => e.getClientRects().length).map(box) };
        });
        results.push({ stage, width, height, ...g });
        if (captureDir) {
          fs.mkdirSync(captureDir, { recursive: true });
          await page.screenshot({ path: path.join(captureDir, `mobile-prompt-${stage}-${width}-${browser.browserType().name()}.png`), clip: { x: 0, y: g.viewport.top, width: g.width, height: Math.min(g.viewport.height, g.windowHeight - g.viewport.top) } });
        }
        assert(g.submit.top >= g.viewport.top - 1 && g.submit.bottom <= g.viewport.bottom + 1, `Submit outside visible viewport: ${JSON.stringify(g)}`);
        assert(g.buttons.every(b => b.top >= g.viewport.top - 1 && b.bottom <= g.viewport.bottom + 1), `Prompt tools outside visible viewport: ${JSON.stringify(g)}`);
        assert(g.row.top >= g.dock.top - 1 && g.row.bottom <= g.dock.bottom + 1, `Actions clipped by dock: ${JSON.stringify(g)}`);
        assert(Math.abs(g.dock.bottom - g.viewport.bottom) <= 1, `Dock must reach the visible viewport bottom: ${JSON.stringify(g)}`);
        assert(g.dockPaddingBottom >= g.safeAreaBottom + 5, `Dock controls must keep their safe-area inset: ${JSON.stringify(g)}`);
        assert(!g.dockBackground.includes("/"), `Dock background must be opaque through the safe area: ${JSON.stringify(g)}`);
        assert(g.pageWidth <= g.width + 1 && g.inputContent > g.inputClient, "long draft scrolls inside bounded textarea without horizontal overflow");
        assert.equal(await page.locator("#prompt-input").inputValue(), draft);
        if (await page.locator("#prompt-input").evaluate(e => e === document.activeElement)) {
          assert.equal(await page.locator("#prompt-input").evaluate(e => e.selectionStart), caret, "keyboard viewport changes preserve the focused caret");
        }
        return g;
      };
      if (width === 390 && height === 844) {
        const attachmentInput = page.locator("[data-prompt-attachment-input]").first();
        await attachmentInput.setInputFiles([
          { name: "first.txt", mimeType: "text/plain", buffer: Buffer.from("first file") },
          { name: "second.txt", mimeType: "text/plain", buffer: Buffer.from("second file") },
        ]);
        const disclosure = page.locator("[data-pending-attachments]");
        await disclosure.waitFor({ state: "visible" });
        await page.setViewportSize({ width: 390, height: 390 });
        await page.evaluate(() => new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve))));
        assert.equal(await disclosure.evaluate(e => e.open), false, "short viewport collapses pending attachment list");
        assert.equal(await disclosure.locator("[data-pending-attachment]").count(), 2, "collapse retains both files");
        assert.match(await disclosure.innerText(), /2\/5/, "collapsed disclosure shows the retained file count");
        await disclosure.locator("summary").click();
        assert.equal(await disclosure.evaluate(e => e.open), true, "user can open the list at short height");
        await page.evaluate(() => syncAgentDockLayout());
        await page.evaluate(() => refresh({ force: true }));
        assert.equal(await disclosure.evaluate(e => e.open), true, "layout sync and polling preserve explicit open choice");
        assert.equal(await disclosure.locator("[data-pending-attachment]").count(), 2, "polling preserves selected files");
        assert.equal(await page.locator("#prompt-input").inputValue(), draft, "polling preserves prompt draft");
        await disclosure.locator("summary").focus();
        await page.keyboard.press("Enter");
        assert.equal(await disclosure.evaluate(e => e.open), false, "keyboard activation closes the list");
        await page.evaluate(() => syncAgentDockLayout());
        await page.evaluate(() => refresh({ force: true }));
        assert.equal(await disclosure.evaluate(e => e.open), false, "layout sync and polling preserve explicit closed choice");
        await disclosure.locator("summary").focus();
        await page.keyboard.press("Enter");
        assert.equal(await disclosure.evaluate(e => e.open), true, "keyboard activation opens the list");
        const removeButtons = disclosure.locator("[data-remove-prompt-attachment]");
        assert.equal(await removeButtons.count(), 2, "open list exposes file controls");
        await removeButtons.first().click();
        assert.equal(await disclosure.locator("[data-pending-attachment]").count(), 1, "file control removes the selected file");
        assert.match(await disclosure.innerText(), /1\/5/, "count updates after file removal");
        assert.equal(await disclosure.evaluate(e => e.open), true, "file control leaves the list open");
        await disclosure.locator("[data-remove-prompt-attachment]").click();
        assert.equal(await page.locator("[data-pending-attachments]").count(), 0, "remaining test attachment is removed");
        assert.equal(await page.locator("#prompt-input").inputValue(), draft, "file controls preserve prompt draft");
        await page.setViewportSize({ width, height });
      }
      await check("long-draft");
      const model = width < 900 && height > 500 ? { top: Math.round(height * 0.14), height: Math.round(height * 0.55) }
        : { top: 0, height: width >= 1100 ? Math.round(height * 0.8) : 230 };
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
          return { rect: r.toJSON(), top: 0, bottom: visualViewport.height, offsetTop: visualViewport.offsetTop, hit: hit?.outerHTML?.slice(0, 200), ownHit: e.contains(hit), label: e.getAttribute("aria-label") };
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
      const expand = page.locator("#composer .composer-full-screen-button");
      const expandedKind = (await expand.getAttribute("aria-label")).includes("full-screen") ? "composer-full-screen" : "composer-full-height";
      await expand.click();
      await page.locator(`#composer.${expandedKind}`).waitFor();
      const expandedGeometry = await page.locator('#composer button[type="submit"]').evaluate(e => {
        const rect = e.getBoundingClientRect();
        return { top: rect.top, bottom: rect.bottom, viewportHeight: visualViewport.height };
      });
      assert(expandedGeometry.top >= -1 && expandedGeometry.bottom <= expandedGeometry.viewportHeight + 1,
        `Expanded composer action outside visible viewport: ${JSON.stringify({ width, expandedKind, expandedGeometry })}`);
      const closeExpanded = expandedKind === "composer-full-screen"
        ? page.locator('#composer button[aria-label="Close full-screen editor"]')
        : page.locator('#composer button[aria-label="Collapse editor"]');
      await closeExpanded.click();
      await page.locator("#composer:not(.composer-full-screen):not(.composer-full-height)").waitFor();
      assert.equal(await page.locator("#prompt-input").inputValue(), draft, "expanded editor keeps the prompt draft");
      if (await page.locator("#prompt-input").evaluate(e => e === document.activeElement)) {
        assert.equal(await page.locator("#prompt-input").evaluate(e => e.selectionStart), caret, "expanded editor keeps the prompt caret");
      }
      await page.setViewportSize({ width: height, height: width });
      await check("orientation-change");
      assert.deepEqual(errors, []);
    } finally { await context.request.post(`${baseUrl}/agents/${key}/stop`, { data: {} }); await context.close(); }
  }
  console.log(JSON.stringify({ engine: browser.browserType().name(), cases: results.length, limits: "Viewport sizes, synthetic visualViewport events and CSS safe insets; no native OS keyboard or toolbar." }));
  if (captureDir) fs.writeFileSync(path.join(captureDir, "mobile-prompt-geometry.json"), JSON.stringify({ engine: browser.browserType().name(), limits: "Real browser layout with synthetic visualViewport events and safe-area CSS variables; no native OS keyboard or toolbar.", results }, null, 2));
};
