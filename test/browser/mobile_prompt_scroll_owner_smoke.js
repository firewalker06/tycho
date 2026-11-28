const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");

module.exports = async ({ browser, baseUrl, agentKey: seededAgentKey, captureDir }) => {
  const results = [];
  const persist = () => {
    if (!captureDir) return;
    fs.mkdirSync(captureDir, { recursive: true });
    fs.writeFileSync(path.join(captureDir, "composer-scroll-owner.json"), JSON.stringify({ engine: browser.browserType().name(), version: browser.version(), model: "375x664 layout; large vh=704; visual pan and keyboard modeled", results }, null, 2));
  };
  for (const suffix of ["", "/summary"]) {
    for (let trial = 0; trial < 3; trial++) {
      const context = await browser.newContext({ viewport: { width: 375, height: 664 }, deviceScaleFactor: 3, colorScheme: "dark", isMobile: true, hasTouch: true });
      let agentKey = seededAgentKey;
      if (trial === 2) {
        const response = await context.request.post(`${baseUrl}/agents`, { data: { project_key: "web", template_key: "custom", name: "Short scroll fixture", prompt: "Synthetic only", start: false } });
        assert(response.ok(), await response.text());
        agentKey = (await response.json()).agent.key;
      }
      // Headless engines have no Safari toolbar. Model only its large-vh/dvh
      // difference in both existing body declarations, not workspace geometry.
      await context.route(/\/ui(?:\?.*)?$/, async route => {
        const response = await route.fetch(), text = await response.text();
        const body = text.replace("body { margin: 0; min-height: 100vh;", "body { margin: 0; min-height: calc(100dvh + 40px);");
        assert.notEqual(body, text, "model the inline loading body's viewport minimum");
        await route.fulfill({ response, body });
      });
      await context.route(/\/ui\.css(?:\?.*)?$/, async route => {
        const response = await route.fetch(), text = await response.text();
        const before = "body {\n  margin: 0;\n  min-width: 0;\n  min-height: 100vh;";
        assert(text.includes(before), "model the main body's viewport minimum");
        await route.fulfill({ response, body: text.replace(before, before.replace("100vh", "calc(100dvh + 40px)")) });
      });
      await context.addInitScript(() => {
        let height = null, top = 0;
        Object.defineProperties(visualViewport, {
          height: { configurable: true, get: () => height ?? innerHeight },
          offsetTop: { configurable: true, get: () => top },
        });
        window.setOwnerViewport = (nextHeight, nextTop = 0) => {
          height = nextHeight; top = nextTop;
          document.body.style.transform = top ? `translateY(-${top}px)` : "";
          visualViewport.dispatchEvent(new Event("resize"));
          visualViewport.dispatchEvent(new Event("scroll"));
        };
        window.ownerGeometry = () => {
          const box = selector => document.querySelector(selector)?.getBoundingClientRect().toJSON();
          const scroll = element => element ? { top: element.scrollTop, client: element.clientHeight, height: element.scrollHeight } : null;
          const row = document.querySelector("#composer .send-row");
          return {
            document: scroll(document.scrollingElement), window: scrollY, viewport: { height: visualViewport.height, top: visualViewport.offsetTop },
            stream: scroll(document.querySelector("[data-agent-conversation-scroll]")), dock: scroll(document.querySelector("[data-agent-dock]")),
            header: box(".app-header"), root: box("[data-agent-workspace]"), send: box("#composer button[type='submit']"),
            controls: row ? [...row.querySelectorAll("button,summary")].filter(element => element.getClientRects().length).map(element => {
              const rect = element.getBoundingClientRect();
              const hits = [0.1, 0.5, 0.9].flatMap(x => [0.1, 0.5, 0.9].map(y => element.contains(document.elementFromPoint(rect.x + rect.width * x, rect.y + rect.height * y))));
              return { bottom: rect.bottom, top: rect.top, hits: hits.filter(Boolean).length,
                occluders: [0.1, 0.5, 0.9].flatMap(x => [0.1, 0.5, 0.9].map(y => {
                  const hit = document.elementFromPoint(rect.x + rect.width * x, rect.y + rect.height * y);
                  return hit && !element.contains(hit) ? { tag: hit.tagName, id: hit.id, className: hit.className } : null;
                })).filter(Boolean) };
            }) : [],
          };
        };
        window.ownerFirstVisible = null;
        new MutationObserver(() => {
          const boot = document.getElementById("tycho-boot-shell");
          if (!ownerFirstVisible && document.querySelector("#prompt-input") && (boot.hidden || boot.classList.contains("is-leaving"))) ownerFirstVisible = ownerGeometry();
        }).observe(document, { childList: true, subtree: true, attributes: true, attributeFilter: ["class", "hidden"] });
        // Simulate a restored document offset while the loading shell is present.
        document.addEventListener("DOMContentLoaded", () => { scrollTo(0, 40); }, { once: true });
      });
      const page = await context.newPage(), errors = [];
      page.on("pageerror", error => errors.push(error.message));
      const frames = () => page.evaluate(() => new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve))));
      const check = async (stage, supplied = null, controls = true) => {
        const geometry = supplied || await page.evaluate(() => ownerGeometry());
        results.push({ suffix, trial, stage, geometry }); persist();
        assert.equal(geometry.document.height, geometry.document.client, `Root scroll range at ${stage}: ${JSON.stringify(geometry)}`);
        assert.equal(geometry.document.top, 0, `Document moved at ${stage}`);
        assert.equal(geometry.window, 0, `Window moved at ${stage}`);
        assert(geometry.root.bottom <= geometry.viewport.height + 1 && geometry.send.bottom <= geometry.viewport.height + 1, `Clipped composer at ${stage}: ${JSON.stringify(geometry)}`);
        if (controls) assert(geometry.controls.length && geometry.controls.every(control => control.hits === 9 && control.top >= -1 && control.bottom <= geometry.viewport.height + 1), `Footer hit targets at ${stage}: ${JSON.stringify(geometry)}`);
        return geometry;
      };
      try {
        await page.goto(`${baseUrl}/ui#agent/${agentKey}${suffix}`);
        await page.waitForFunction(() => ownerFirstVisible !== null);
        await check("first-visible", await page.evaluate(() => ownerFirstVisible));
        await page.waitForFunction(() => state.initialRouteLoaded && !state.refreshInFlight && document.getElementById("tycho-boot-shell").hidden);
        await page.evaluate(() => document.fonts.ready); await frames();
        await page.evaluate(() => { window.ownerInput = document.querySelector("#prompt-input"); });
        await check("settled");
        // This exactly reproduced Send=691 at height664 on the unfixed source.
        await page.evaluate(() => { scrollTo(0, 40); syncAgentDockLayout(); });
        await check("document-40");
        await page.evaluate(() => scrollTo(0, 7));
        await check("document-7-immediate");
        await frames(); await check("document-7-settled");
        if (suffix) {
          await page.evaluate(key => toggleSideConversation(key, "conversation"), agentKey); await frames();
        }
        await page.evaluate(() => { window.ownerInput = document.querySelector("#prompt-input"); });
        const stream = page.locator("[data-agent-conversation-scroll]");
        await stream.evaluate(element => { element.scrollTop = 300; }); await frames();
        const before = await stream.evaluate(element => element.scrollTop);
        const rect = await stream.boundingBox();
        const nativeTouch = browser.browserType().name() === "chromium";
        const swipe = async () => {
          if (nativeTouch) {
            const session = await context.newCDPSession(page);
            const x = rect.x + rect.width / 2, y = rect.y + rect.height * 0.75, distance = Math.min(180, rect.height / 2);
            await session.send("Input.dispatchTouchEvent", { type: "touchStart", touchPoints: [{ x, y }] });
            for (let step = 1; step <= 8; step++) {
              await session.send("Input.dispatchTouchEvent", { type: "touchMove", touchPoints: [{ x, y: y - distance * step / 8 }] });
              await frames();
            }
            await session.send("Input.dispatchTouchEvent", { type: "touchEnd", touchPoints: [] });
            await session.detach();
          } else {
            // Playwright mobile WebKit cannot dispatch native swipes or wheels.
            // Replay the touch markers and stream offset; keep that gap explicit.
            await stream.evaluate(element => {
              const start = new Event("touchstart", { bubbles: true, cancelable: true });
              Object.defineProperty(start, "touches", { value: [{ clientX: 150, clientY: 200 }] });
              element.dispatchEvent(start); element.scrollTop += 180;
              element.dispatchEvent(new Event("scroll")); element.dispatchEvent(new Event("touchend", { bubbles: true }));
            });
          }
        };
        const scrollable = await stream.evaluate(element => element.scrollHeight > element.clientHeight + 20);
        await swipe();
        if (scrollable) await page.waitForFunction(value => document.querySelector("[data-agent-conversation-scroll]").scrollTop > value + 20, before);
        const swiped = await check(scrollable ? nativeTouch ? "native-touch" : "scripted-touch-scroll" : "short-stream-touch");
        assert(scrollable ? swiped.stream.top > before + 20 : swiped.stream.top === 0, "stream owns its scroll offset without moving the document");
        await stream.evaluate(element => { element.scrollTop = element.scrollHeight; }); await frames();
        await swipe(); await frames(); await check("stream-boundary");
        await page.locator("#prompt-input").fill("Synthetic scroll ownership draft");
        await page.locator("#prompt-input").evaluate(input => input.setSelectionRange(10, 10));
        await page.evaluate(() => setOwnerViewport(621)); await frames(); await check("chrome-height-621");
        await page.evaluate(() => setOwnerViewport(340, 82)); await frames(); await check("keyboard-pan-82");
        await page.evaluate(() => setOwnerViewport(null)); await page.setViewportSize({ width: 375, height: 240 });
        await page.evaluate(key => {
          state.pendingPromptAttachments[key] = Array.from({ length: 5 }, (_, index) => normalizePromptAttachmentFile(new File(["Synthetic"], `scroll-${index}.txt`, { type: "text/plain" })));
          state.pendingAttachmentDisclosureChoices.set(key, true); promptSubmissionOutbox(); syncPromptSubmissions();
        }, agentKey); await frames();
        const dock = page.locator("[data-agent-dock]");
        await dock.evaluate(element => { element.scrollTop = element.scrollHeight; }); await frames();
        const short = await check("short-dock"); assert(short.dock.height > short.dock.client && short.dock.top > 0, "dock retains independent scrolling");
        await page.setViewportSize({ width: 375, height: 664 }); await frames(); await check("return");
        assert(await page.evaluate(() => ownerInput === document.querySelector("#prompt-input")), "scroll and viewport changes retain the textarea");
        assert.equal(await page.locator("#prompt-input").inputValue(), "Synthetic scroll ownership draft");
        assert.equal(await page.locator("#prompt-input").evaluate(input => input.selectionStart), 10);
        if (captureDir && (trial === 0 || trial === 2)) await page.screenshot({ path: path.join(captureDir, `scroll-owner-${suffix ? "summary" : "conversation"}-${trial}-${browser.browserType().name()}.png`) });
        await page.evaluate(() => navigate({ type: "tab", tab: "agents" }));
        await page.waitForFunction(() => !document.querySelector("[data-agent-workspace]"));
        const ordinary = await page.evaluate(() => { const spacer = document.createElement("div"); spacer.style.height = "1400px"; document.getElementById("view").append(spacer); scrollTo(0, 100); return { top: scrollY, overflow: getComputedStyle(document.documentElement).overflowY }; });
        results.push({ suffix, trial, stage: "ordinary-route", geometry: ordinary }); persist();
        assert(ordinary.top > 0 && ordinary.overflow !== "hidden", "ordinary routes retain document scrolling");
        await page.evaluate(key => navigate({ type: "agent", key }), agentKey);
        await page.waitForFunction(() => document.querySelector("#prompt-input"));
        await check("return-from-document-scroll");
        assert.deepEqual(errors, []);
      } finally { await context.close(); }
    }
  }
  console.log(JSON.stringify({ engine: browser.browserType().name(), scrollOwnerChecks: results.length, limits: "Modeled Safari vh/dvh, visual pan and keyboard; Chrome CDP touch; WebKit touch/offset replay; physical touch acceptance pending." }));
};
