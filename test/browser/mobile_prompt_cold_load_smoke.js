const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");

module.exports = async ({ browser, baseUrl, agentKey, captureDir }) => {
  const results = [];
  for (const suffix of ["", "/summary"]) {
    for (const fileCount of [0, 1, 5]) {
      const context = await browser.newContext({ viewport: { width: 375, height: 812 }, isMobile: true, hasTouch: true });
      await context.addInitScript(() => {
        let height = 672, top = 0;
        Object.defineProperties(visualViewport, {
          height: { configurable: true, get: () => height },
          offsetTop: { configurable: true, get: () => top },
        });
        window.setColdViewport = (nextHeight, nextTop = 0) => {
          height = nextHeight;
          top = nextTop;
          document.body.style.transform = top ? `translateY(-${top}px)` : "";
        };
        window.coldMounts = [];
        window.coldTimeline = [];
        window.coldFirstVisible = null;
        const record = event => {
          const root = document.querySelector("[data-agent-workspace]");
          if (!root || coldTimeline.length >= 240) return;
          const box = selector => document.querySelector(selector)?.getBoundingClientRect().toJSON();
          const boot = document.getElementById("tycho-boot-shell");
          coldTimeline.push({ event, at: performance.now(), viewport: visualViewport.height, header: box(".app-header"), clearance: document.getElementById("view").style.getPropertyValue("--detail-header-height"), root: box("[data-agent-workspace]"), dock: box("[data-agent-dock]"), row: box("#composer .send-row"), bootHidden: boot.hidden, bootOpacity: getComputedStyle(boot).opacity });
        };
        let frame = 0;
        const recordFrame = () => { record(`frame:${++frame}`); if (frame < 120) requestAnimationFrame(recordFrame); };
        requestAnimationFrame(recordFrame);
        new MutationObserver(() => {
          const input = document.querySelector("#prompt-input");
          if (!input) return;
          record("mutation");
          const boot = document.getElementById("tycho-boot-shell");
          if (!coldFirstVisible && (boot.hidden || boot.classList.contains("is-leaving"))) {
            const box = selector => document.querySelector(selector).getBoundingClientRect().toJSON();
            const row = document.querySelector("#composer .send-row");
            coldFirstVisible = { at: performance.now(), viewport: visualViewport.height, header: box(".app-header"), root: box("[data-agent-workspace]"), dock: box("[data-agent-dock]"), row: box("#composer .send-row"), bootPointerEvents: getComputedStyle(boot).pointerEvents,
              controls: [...row.querySelectorAll("button,summary")].filter(element => element.getClientRects().length).map(element => {
                const rect = element.getBoundingClientRect();
                return { rect: rect.toJSON(), hit: element.contains(document.elementFromPoint(rect.x + rect.width / 2, rect.y + rect.height / 2)) };
              }) };
            record("first-visible");
          }
          if (window.coldMounts.length) return;
          const box = selector => document.querySelector(selector)?.getBoundingClientRect().toJSON();
          window.coldMounts.push({ viewport: visualViewport.height, root: box("[data-agent-workspace]"), dock: box("[data-agent-dock]"), composer: box("#composer"), row: box("#composer .send-row") });
        }).observe(document, { childList: true, subtree: true, attributes: true, attributeFilter: ["class", "hidden"] });
      });
      const page = await context.newPage();
      const errors = [];
      page.on("pageerror", error => errors.push(error.message));
      const frames = () => page.evaluate(() => new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve))));
      const check = async stage => {
        await frames();
        await page.locator("[data-agent-dock]").evaluate(dock => { dock.scrollTop = dock.scrollHeight; });
        const geometry = await page.evaluate(() => {
          const box = element => element?.getBoundingClientRect().toJSON();
          const dock = document.querySelector("[data-agent-dock]"), row = document.querySelector("#composer .send-row");
          return {
            viewport: { height: visualViewport.height, top: visualViewport.offsetTop, layoutHeight: innerHeight },
            root: box(document.querySelector("[data-agent-workspace]")), dock: box(dock), composer: box(document.querySelector("#composer")), input: box(document.querySelector("#prompt-input")), row: box(row),
            dockStyle: dock.style.cssText, dockScroll: dock.scrollTop, dockContent: dock.scrollHeight, dockClient: dock.clientHeight,
            safe: parseFloat(getComputedStyle(document.documentElement).getPropertyValue("--safe-area-bottom")) || 0,
            controls: [...row.querySelectorAll("button,summary")].filter(element => element.getClientRects().length).map(element => {
              const rect = element.getBoundingClientRect();
              return { label: element.getAttribute("aria-label"), rect: rect.toJSON(), hit: element.contains(document.elementFromPoint(rect.x + rect.width / 2, rect.y + rect.height / 2)) };
            }),
          };
        });
        results.push({ suffix, fileCount, stage, geometry });
        if (captureDir) {
          fs.mkdirSync(captureDir, { recursive: true });
          await page.screenshot({ path: path.join(captureDir, `cold-composer-${suffix ? "summary" : "conversation"}-${fileCount}-${stage}-${browser.browserType().name()}.png`), clip: { x: 0, y: 0, width: 375, height: geometry.viewport.height } });
          fs.writeFileSync(path.join(captureDir, "cold-composer-geometry.json"), JSON.stringify({ engine: browser.browserType().name(), results }, null, 2));
          fs.writeFileSync(path.join(captureDir, `cold-timeline-${suffix ? "summary" : "conversation"}-${fileCount}.json`), JSON.stringify(await page.evaluate(() => ({ mounts: coldMounts, timeline: coldTimeline })), null, 2));
        }
        assert(geometry.root.bottom <= geometry.viewport.height + 1, `Stale workspace after ${stage}: ${JSON.stringify(geometry)}`);
        assert(geometry.dock.bottom <= geometry.viewport.height + 1, `Stale dock after ${stage}: ${JSON.stringify(geometry)}`);
        assert(geometry.controls.every(control => control.hit && control.rect.top >= 0 && control.rect.bottom <= geometry.viewport.height - geometry.safe + 1), `Clipped cold composer after ${stage}: ${JSON.stringify(geometry)}`);
      };
      try {
        if (!suffix && fileCount === 0) {
          const child = await context.request.post(`${baseUrl}/agents`, { data: { project_key: "web", template_key: "custom", name: "Cold composer linked fixture", prompt: "Synthetic only", parent_agent_key: agentKey, start: false } });
          assert(child.ok(), await child.text());
        }
        // Direct deep link, fresh storage, no fill/focus/resize that could repair initial layout.
        await page.goto(`${baseUrl}/ui#agent/${agentKey}${suffix}`, { waitUntil: "load" });
        await page.locator("#prompt-input").waitFor();
        // The opaque loading shell is allowed to intercept input. Capture its first
        // reveal in a mutation callback, before any frame wait can repair the geometry.
        await page.waitForFunction(() => coldFirstVisible !== null);
        const visible = await page.evaluate(() => coldFirstVisible);
        results.push({ suffix, fileCount, stage: "first-visible", geometry: visible });
        if (captureDir) {
          fs.mkdirSync(captureDir, { recursive: true });
          fs.writeFileSync(path.join(captureDir, "cold-composer-geometry.json"), JSON.stringify({ engine: browser.browserType().name(), results }, null, 2));
          fs.writeFileSync(path.join(captureDir, `cold-first-visible-${suffix ? "summary" : "conversation"}-${fileCount}.json`), JSON.stringify(visible, null, 2));
        }
        assert(visible.root.bottom <= visible.viewport + 1 && visible.dock.bottom <= visible.viewport + 1 && visible.controls.every(control => control.hit && control.rect.top >= 0 && control.rect.bottom <= visible.viewport + 1),
          `Clipped first-visible composer: ${JSON.stringify(visible)}`);
        await check("mount");
        await page.waitForFunction(() => state.initialRouteLoaded && !state.refreshInFlight && document.getElementById("tycho-boot-shell").hidden);
        await page.evaluate(() => { window.coldInput = document.querySelector("#prompt-input"); });
        // A late route response can render between the frame wait and the first-visible check.
        // Assert the returned layout now, without a frame that could repair stale header clearance.
        const rendered = await page.evaluate(() => {
          render({ preserveLiveEditor: true, preservePollContent: true });
          const box = selector => document.querySelector(selector).getBoundingClientRect().toJSON();
          return { viewport: visualViewport.height, header: box(".app-header"), root: box("[data-agent-workspace]"), dock: box("[data-agent-dock]"), row: box("#composer .send-row") };
        });
        results.push({ suffix, fileCount, stage: "render-return", geometry: rendered });
        if (captureDir) fs.writeFileSync(path.join(captureDir, "cold-composer-geometry.json"), JSON.stringify({ engine: browser.browserType().name(), results }, null, 2));
        assert(rendered.root.bottom <= rendered.viewport + 1 && rendered.dock.bottom <= rendered.viewport + 1 && rendered.row.bottom <= rendered.viewport + 1,
          `Header changed after workspace sizing: ${JSON.stringify(rendered)}`);
        // Model a chrome transition whose geometry settles after the synchronous event handler.
        await page.evaluate(() => { visualViewport.dispatchEvent(new Event("resize")); setColdViewport(628); });
        await check("settled");
        assert(await page.evaluate(() => coldInput === document.querySelector("#prompt-input")), "viewport settling retains the textarea node");

        // Restore pending sections through the real live-editor reconciliation path.
        await page.evaluate(({ key, count }) => {
          const input = document.querySelector("#prompt-input");
          input.value = "Synthetic restored cold draft";
          input.setSelectionRange(10, 10);
          state.pendingPromptAttachments[key] = Array.from({ length: count }, (_, index) => normalizePromptAttachmentFile(new File(["Synthetic only"], `cold-${index}.txt`, { type: "text/plain" })));
          state.pendingAttachmentDisclosureChoices.set(key, true);
          promptSubmissionOutbox();
          syncPromptSubmissions();
        }, { key: agentKey, count: fileCount });
        await check("restored");
        assert.equal(await page.locator("[data-pending-attachment]").count(), fileCount);
        if (fileCount) assert(await page.locator("[data-pending-attachments]").evaluate(element => element.open));
        await page.evaluate(() => document.documentElement.style.setProperty("--safe-area-bottom", "34px"));
        await check("safe-area");

        // A header-only resize already has its own layout invalidation.
        await page.locator(".app-header").evaluate(header => { header.style.paddingBottom = `${parseFloat(getComputedStyle(header).paddingBottom) + 12}px`; });
        await check("header");
        for (const [height, top, event] of [[340, 88, "scroll"], [628, 0, "resize"]]) {
          await page.evaluate(({ height, top, event }) => { visualViewport.dispatchEvent(new Event(event)); setColdViewport(height, top); }, { height, top, event });
          await check(`viewport-${height}`);
        }
        assert(await page.evaluate(() => coldInput === document.querySelector("#prompt-input")), "restoration and viewport changes retain the textarea");
        assert.equal(await page.locator("#prompt-input").inputValue(), "Synthetic restored cold draft");
        assert.equal(await page.locator("#prompt-input").evaluate(input => input.selectionStart), 10);
        if (captureDir) fs.writeFileSync(path.join(captureDir, `cold-mount-${suffix ? "summary" : "conversation"}-${fileCount}.json`), JSON.stringify(await page.evaluate(() => coldMounts), null, 2));
        assert.deepEqual(errors, []);
      } finally {
        await context.close();
      }
    }
  }
  console.log(JSON.stringify({ engine: browser.browserType().name(), coldComposerChecks: results.length, limits: "Synthetic viewport settling and safe insets; no native Safari chrome or OS keyboard." }));
};
