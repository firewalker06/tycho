const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");

module.exports = async ({ browser, baseUrl, agentKey, captureDir }) => {
  const results = [];
  for (const theme of ["dark", "light"]) {
    const context = await browser.newContext({ viewport: { width: 320, height: 844 }, hasTouch: true, reducedMotion: "reduce" });
    const page = await context.newPage();
    const errors = [];
    page.on("pageerror", error => errors.push(error.message));
    const frames = () => page.evaluate(() => new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve))));
    const strip = page.locator("[data-agent-floating-actions]");
    const input = page.locator("#prompt-input");
    const geometry = () => strip.evaluate(el => {
      const rect = el.getBoundingClientRect(), css = getComputedStyle(el);
      return { left: el.scrollLeft, max: el.scrollWidth - el.clientWidth, width: el.clientWidth, right: rect.right, mask: css.maskImage, scrollbar: css.scrollbarWidth, buttons: [...el.querySelectorAll("button")].map(button => {
        const r = button.getBoundingClientRect();
        const range = document.createRange(); range.selectNodeContents(button.querySelector("span"));
        return { text: button.textContent.trim(), x: r.x, right: r.right, y: r.y, height: r.height, lines: range.getClientRects().length };
      }) };
    });
    const capture = async name => { if (captureDir) await page.screenshot({ path: path.join(captureDir, `action-strip-${theme}-${name}.png`) }); };
    await page.goto(`${baseUrl}/ui#agent/${agentKey}`, { waitUntil: "networkidle" });
    await input.waitFor();
    await page.evaluate(theme => window.TychoAppearance.setPreference(theme), theme);
    const configure = async (running, focus, fresh = false) => {
      await page.evaluate(({ key, running, focus, fresh }) => {
        const agent = findAgent(key);
        agent.running = running;
        agent.focus = { sections: focus ? [{ title: "Next", items: [{ title: "Synthetic task" }] }] : [] };
        if (fresh) { state.renderedRouteKey = null; state.renderedViewHtml = null; }
        render();
      }, { key: agentKey, running, focus, fresh });
      await frames();
    };
    await configure(true, true, true);
    let g = await geometry();
    assert.equal(g.buttons.length, 4, JSON.stringify(g));
    assert(g.max > 0 && Math.abs(g.left - g.max) < 2, JSON.stringify(g));
    assert(g.mask.includes("linear-gradient") && g.scrollbar === "none");
    assert(g.buttons.at(-1).text === "Stop" && g.buttons.at(-1).right <= g.right);
    assert.equal(new Set(g.buttons.map(b => b.y)).size, 1);
    assert(g.buttons.every(b => b.lines === 1 && b.height >= 38));
    await capture("320-right");
    results.push({ theme, state: "initial running with Focus", geometry: g });

    // Native horizontal wheel and keyboard scrolling must reach the left edge.
    await strip.hover(); await page.mouse.wheel(-1000, 0);
    await page.waitForFunction(() => document.querySelector("[data-agent-floating-actions]").scrollLeft < 1);
    await frames();
    g = await geometry(); assert.equal(g.mask, "none");
    await capture("320-left");
    await strip.focus(); await page.keyboard.press("ArrowRight");
    await page.waitForFunction(() => document.querySelector("[data-agent-floating-actions]").scrollLeft > 1);
    await strip.focus(); await page.keyboard.press("End");
    await page.waitForFunction(() => { const el = document.querySelector("[data-agent-floating-actions]"); return el.scrollLeft >= el.scrollWidth - el.clientWidth - 2; });
    await strip.focus(); await page.keyboard.press("Home");
    await page.waitForFunction(() => document.querySelector("[data-agent-floating-actions]").scrollLeft < 1);

    await input.fill("Preserve this draft and selected text");
    await input.evaluate(el => { el.focus(); el.setSelectionRange(9, 19); });
    // A real forced API refresh replaces the row and must preserve a chosen left edge.
    await page.evaluate(() => refresh({ force: true })); await frames();
    assert((await geometry()).left < 1);
    assert.equal(await input.inputValue(), "Preserve this draft and selected text");
    assert.deepEqual(await input.evaluate(el => [el.selectionStart, el.selectionEnd, document.activeElement === el]), [9, 19, true]);
    await configure(true, true);
    await strip.evaluate(el => { el.scrollLeft = 15; }); await frames();
    await page.evaluate(() => render()); await frames();
    assert(Math.abs((await geometry()).left - 15) < 2, "render reset the user scroll position");
    // Focused-workspace action replacement follows the same position rule.
    await page.evaluate(key => { findAgent(key).running = false; syncAgentFloatingActions(findAgent(key)); }, agentKey);
    await frames(); assert((await geometry()).left <= 15);
    await page.evaluate(key => { findAgent(key).running = true; syncAgentFloatingActions(findAgent(key)); }, agentKey);
    await frames(); assert((await geometry()).left <= 15);

    for (const running of [false, true]) for (const focus of [false, true]) {
      await configure(running, focus);
      g = await geometry();
      assert.equal(g.buttons.length, 2 + Number(running) + Number(focus));
      assert.equal(new Set(g.buttons.map(b => b.y)).size, 1);
      assert(g.buttons.every(b => b.lines === 1));
      results.push({ theme, running, focus, geometry: g });
    }
    await configure(true, true);
    await page.setViewportSize({ width: 640, height: 844 });
    await configure(true, true, true);
    assert.equal((await geometry()).max, 0);
    await page.setViewportSize({ width: 320, height: 844 }); await frames();
    g = await geometry();
    assert(Math.abs(g.left - g.max) < 2, "first overflow after a fit must reveal Stop");
    // Long labels exercise intrinsic sizing without changing production strings.
    await strip.locator("button").first().locator("span").evaluate(el => { el.textContent = "Focus and next actionable items"; });
    await frames(); g = await geometry();
    assert(g.max > 100 && g.buttons.every(b => b.lines === 1));
    await strip.locator("button").first().focus(); await frames();
    g = await geometry(); assert(g.buttons[0].x >= -1 && g.buttons[0].right <= g.right, JSON.stringify(g));
    const focusStyle = await strip.locator("button").first().evaluate(el => ({ style: getComputedStyle(el).outlineStyle, width: getComputedStyle(el).outlineWidth }));
    assert(focusStyle.style === "solid" && parseFloat(focusStyle.width) >= 2);
    await capture("320-long-label-focus");

    // Native Chrome touch scrolling, with no production event interception.
    const cdp = await context.newCDPSession(page);
    const box = await strip.boundingBox();
    await cdp.send("Input.dispatchTouchEvent", { type: "touchStart", touchPoints: [{ x: box.x + box.width - 25, y: box.y + box.height / 2 }] });
    for (let i = 1; i <= 6; i++) await cdp.send("Input.dispatchTouchEvent", { type: "touchMove", touchPoints: [{ x: box.x + box.width - 25 - i * 25, y: box.y + box.height / 2 }] });
    await cdp.send("Input.dispatchTouchEvent", { type: "touchEnd", touchPoints: [] });
    await page.waitForFunction(() => document.querySelector("[data-agent-floating-actions]").scrollLeft > 1);
    await frames(); assert((await geometry()).mask.includes("linear-gradient"));
    await cdp.detach();

    await configure(true, true);
    for (const width of [390, 640, 844, 390, 1440]) {
      await page.setViewportSize({ width, height: 844 }); await frames();
      g = await geometry();
      assert(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth));
      if (width <= 640) {
        assert.equal(new Set(g.buttons.map(b => b.y)).size, 1);
        if (g.max === 0) {
          assert.equal(g.mask, "none");
          assert(Math.abs(g.buttons.at(-1).right - (g.right - 4)) < 2, JSON.stringify(g));
        }
      } else {
        assert.equal(await strip.getAttribute("tabindex"), null);
        assert.equal(g.mask, "none");
      }
      results.push({ theme, width, geometry: g });
      await capture(`${width}-resized`);
    }
    // A retained shortcut keeps keyboard focus when live actions change.
    await strip.locator("[data-open-agent-summary]").focus();
    await page.evaluate(key => { findAgent(key).running = false; syncAgentFloatingActions(findAgent(key)); }, agentKey);
    assert(await strip.locator("[data-open-agent-summary]").evaluate(el => document.activeElement === el));
    await configure(true, true);
    // Fade composes with both opaque composer surfaces and an image backdrop.
    await page.setViewportSize({ width: 320, height: 844 }); await frames();
    await page.evaluate(() => {
      const canvas = document.createElement("canvas"); canvas.width = 800; canvas.height = 800;
      const ctx = canvas.getContext("2d");
      const gradient = ctx.createLinearGradient(0, 0, 800, 800);
      gradient.addColorStop(0, "#c8a56a"); gradient.addColorStop(1, "#335577");
      ctx.fillStyle = gradient; ctx.fillRect(0, 0, 800, 800);
      for (let x = 0; x < 800; x += 80) { ctx.fillStyle = "#ffffff44"; ctx.fillRect(x, 0, 20, 800); }
      return new Promise(resolve => canvas.toBlob(async blob => {
        await window.TychoBackdropImages.choose(new File([blob], "synthetic-backdrop.png", { type: "image/png" })); resolve();
      }, "image/png"));
    });
    await page.waitForFunction(() => document.documentElement.dataset.imageBackdrop === "ready");
    await strip.evaluate(el => { el.scrollLeft = el.scrollWidth; });
    await frames(); await capture("320-backdrop");
    assert((await geometry()).mask.includes("linear-gradient"));
    const surfaces = await page.evaluate(() => ({ image: getComputedStyle(document.body, "::before").backgroundImage, dock: getComputedStyle(document.querySelector(".agent-dock")).backgroundColor }));
    assert(surfaces.image.includes("blob:"), JSON.stringify(surfaces));
    results.push({ theme, state: "raster backdrop", surfaces });
    assert.deepEqual(errors, []);
    await context.close();
  }
  if (captureDir) fs.writeFileSync(path.join(captureDir, "action-strip-results.json"), JSON.stringify(results, null, 2));
  console.log("mobile_action_strip_smoke: ok (Dark/Light, 320/390/640/844/1440, states, long labels, wheel/touch/keyboard, polling, draft/selection, resize, fade)");
};
