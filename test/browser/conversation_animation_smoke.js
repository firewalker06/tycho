const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");

async function fixture(page, key, mode, long = false) {
  await page.evaluate(({ key, mode, long }) => {
    clearTimeout(state.timer);
    clearTimeout(state.activityTimer);
    const agent = findAgent(key);
    Object.assign(agent, {
      name: "Synthetic animation check", status: mode === "running" ? "running" : "succeeded",
      running: mode === "running", current_run_id: "animation-run-1", run_count: 1,
      last_result: mode === "running" ? "in progress" : "success", last_exit_code: mode === "running" ? null : 0,
      finished_at: mode === "running" ? null : "2026-10-15T03:00:00Z",
      awaiting_input: false, blocked: false, summary: "Public synthetic animation fixture",
    });
    state.conversations[key] = {
      loaded: true, loading: false, revision: agent.revision,
      blocks: [
        { kind: "message", role: "user", id: "prompt", content: "Check the conversation layout." },
        { kind: "message", role: "assistant", id: "reply", content: long
          ? Array.from({ length: 35 }, (_, index) => `Paragraph ${index + 1}. This is public synthetic text for the scroll check.`).join("\n\n")
          : "The layout check is complete. The composer is ready for the next prompt." },
        ...(mode === "running" ? [] : [{ kind: "run_summary", id: "summary", content: "The conversation layout is ready.",
          metadata: { status: "success", run_id: "animation-run-1", run_number: 1, summary_id: "summary" } }]),
      ],
    };
    state.loadingConversations[key] = false;
    render();
  }, { key, mode, long });
  await page.waitForSelector(`[data-conversation-marker="${mode}"]`);
}

async function bottom(page) {
  await page.evaluate(() => {
    const pane = conversationScrollRoot();
    pane.scrollTop = pane.scrollHeight;
    if (pane === document.scrollingElement) window.scrollTo(0, pane.scrollHeight);
  });
}

async function facts(page) {
  return page.evaluate(() => {
    const marker = document.querySelector("[data-conversation-marker]");
    const pane = document.querySelector("[data-agent-conversation-scroll]");
    const dock = document.querySelector("[data-agent-dock]");
    const r = marker.getBoundingClientRect();
    const d = dock.getBoundingClientRect();
    const label = marker.querySelector("span");
    const canvas = document.createElement("canvas");
    canvas.width = canvas.height = 1;
    const context = canvas.getContext("2d");
    const rgb = color => {
      context.clearRect(0, 0, 1, 1);
      context.fillStyle = color;
      context.fillRect(0, 0, 1, 1);
      return [...context.getImageData(0, 0, 1, 1).data].slice(0, 3);
    };
    const luminance = color => {
      const channels = rgb(color).map(c => c / 255).map(c => c <= .04045 ? c / 12.92 : ((c + .055) / 1.055) ** 2.4);
      return channels[0] * .2126 + channels[1] * .7152 + channels[2] * .0722;
    };
    const labelColor = getComputedStyle(label).color;
    const background = getComputedStyle(marker).getPropertyValue("--ds-background-canvas");
    const textLight = luminance(labelColor);
    const backgroundLight = luminance(background);
    return {
      mode: marker.dataset.conversationMarker, width: r.width, height: r.height,
      top: r.top, bottom: r.bottom, dockTop: d.top, viewport: window.innerHeight,
      overflow: document.documentElement.scrollWidth > window.innerWidth || pane.scrollWidth > pane.clientWidth,
      liveRegions: marker.querySelectorAll('[aria-live], [role="status"], [role="alert"]').length,
      decorative: marker.querySelector("svg").getAttribute("aria-hidden"),
      artOpacity: getComputedStyle(marker.querySelector("svg")).opacity,
      labelOpacity: getComputedStyle(marker.querySelector("span")).opacity,
      label: label.textContent,
      labelColor,
      labelRGB: rgb(labelColor),
      labelContrast: (Math.max(textLight, backgroundLight) + .05) / (Math.min(textLight, backgroundLight) + .05),
      containerOpacity: getComputedStyle(marker).opacity,
      animations: marker.getAnimations({ subtree: true }).map(a => ({ name: a.animationName, time: a.currentTime,
        iterations: a.effect.getTiming().iterations === Infinity ? "infinite" : a.effect.getTiming().iterations,
        duration: a.effect.getTiming().duration })),
    };
  });
}

module.exports = async function ({ browser, baseUrl, agentKey, captureDir }) {
  const results = [];
  for (const viewport of [{ width: 1060, height: 737 }, { width: 390, height: 844 }]) {
    const page = await browser.newPage({ viewport, deviceScaleFactor: 1 });
    const errors = [];
    page.on("pageerror", error => errors.push(error.message));
    await page.goto(`${baseUrl}/ui#agent/${encodeURIComponent(agentKey)}`, { waitUntil: "networkidle" });
    await page.waitForSelector("#prompt-input", { state: "visible" });
    await page.evaluate(async () => { if (markdownParser.promise) await markdownParser.promise; await document.fonts.ready; });
    await fixture(page, agentKey, "complete");
    await bottom(page);
    if (captureDir) {
      await page.addStyleTag({ content: ".conversation-marker { display: none !important; }" });
      await page.screenshot({ path: path.join(captureDir, `before-${viewport.width}.png`) });
      await page.evaluate(() => [...document.querySelectorAll("style")].find(e => e.textContent.includes("display: none !important"))?.remove());
    }
    await bottom(page);
    const complete = await facts(page);
    assert.equal(complete.decorative, "true");
    assert.equal(complete.artOpacity, "0.2");
    assert.equal(complete.labelOpacity, "1");
    assert.equal(complete.label, "you have reached the end");
    assert.ok(complete.labelContrast >= 4.5, JSON.stringify(complete));
    assert.equal(complete.containerOpacity, "1");
    assert.equal(complete.liveRegions, 0);
    assert.ok(!complete.overflow);
    assert.ok(complete.bottom <= complete.dockTop, JSON.stringify(complete));
    assert.ok(complete.animations.every(a => a.iterations === 1 && a.duration === 1280));
    assert.equal(complete.animations.length, 2);
    await page.waitForTimeout(200);
    const midMotion = await facts(page);
    assert.equal(midMotion.artOpacity, "0.2");
    await page.evaluate((key) => {
      state.conversations[key].blocks[1].content += " Mid-animation poll.";
      render();
    }, agentKey);
    assert.ok((await facts(page)).animations[0].time >= midMotion.animations[0].time - 2);
    if (captureDir) {
      for (let i = 0; i < 8; i += 1) {
        await page.evaluate(time => document.querySelector("[data-conversation-marker]").getAnimations({ subtree: true }).forEach(a => { a.pause(); a.currentTime = time; }), i * 160);
        await page.locator("[data-conversation-marker]").screenshot({ path: path.join(captureDir, `complete-${viewport.width}-frame-${i}.png`) });
      }
      await page.evaluate(() => document.querySelector("[data-conversation-marker]").getAnimations({ subtree: true }).forEach(a => a.play()));
    }
    await page.waitForTimeout(1400);
    assert.equal((await facts(page)).artOpacity, "0.2");
    assert.equal((await facts(page)).label, "you have reached the end");
    assert.ok((await facts(page)).labelContrast >= 4.5);
    assert.ok((await facts(page)).animations.every(a => a.time >= 1280));
    if (captureDir) {
      await page.screenshot({ path: path.join(captureDir, `complete-${viewport.width}.png`) });
      await page.locator("[data-conversation-marker]").screenshot({ path: path.join(captureDir, `complete-${viewport.width}-frame-8.png`) });
    }

    // A second run can play, but a rendered poll cannot replay this run.
    await page.evaluate((key) => {
      window.__oldMarker = document.querySelector("[data-conversation-marker]");
      state.conversations[key].blocks[1].content += " Poll update.";
      render();
    }, agentKey);
    assert.ok(await page.evaluate(() => window.__oldMarker === document.querySelector("[data-conversation-marker]")));
    assert.ok((await facts(page)).animations.every(a => a.time >= 1280));
    await fixture(page, agentKey, "running");
    await bottom(page);
    await page.waitForTimeout(550);
    const running = await facts(page);
    assert.equal(running.artOpacity, "1");
    assert.equal(running.label, "Agent is working");
    assert.deepEqual(running.labelRGB, [189, 194, 219]);
    assert.equal(running.animations.length, 4);
    assert.ok(running.animations.every(a => a.iterations === "infinite" && a.duration === 2400));
    await page.locator("#prompt-input").fill("Keep this draft during a poll");
    await page.evaluate((key) => {
      window.__oldMarker = document.querySelector("[data-conversation-marker]");
      state.conversations[key].blocks[1].content += " Another poll update.";
      render();
    }, agentKey);
    assert.equal(await page.locator("#prompt-input").inputValue(), "Keep this draft during a poll");
    assert.ok(await page.evaluate(() => window.__oldMarker === document.querySelector("[data-conversation-marker]")));
    assert.ok((await facts(page)).animations[0].time >= running.animations[0].time - 2, "running motion must retain its time");
    if (captureDir) {
      await page.locator("#prompt-input").fill("");
      await page.screenshot({ path: path.join(captureDir, `running-${viewport.width}.png`) });
      const marker = page.locator("[data-conversation-marker]");
      for (let i = 0; i < 8; i += 1) {
        await page.evaluate(time => document.querySelector("[data-conversation-marker]").getAnimations({ subtree: true }).forEach(a => { a.pause(); a.currentTime = time; }), i * 300);
        await marker.screenshot({ path: path.join(captureDir, `running-${viewport.width}-frame-${i}.png`) });
      }
      if (viewport.width === 1060) fs.writeFileSync(path.join(captureDir, "running-marker.html"), await marker.evaluate(e => e.outerHTML));
    }
    await fixture(page, agentKey, "complete", true);
    await bottom(page);
    await page.waitForTimeout(100);
    assert.ok((await facts(page)).bottom <= (await facts(page)).dockTop);
    await page.evaluate(() => { const pane = conversationScrollRoot(); pane.scrollTop = 180; window.__scrollBefore = pane.scrollTop; });
    await page.evaluate((key) => { state.conversations[key].blocks[1].content += " Tail update."; render(); }, agentKey);
    const scroll = await page.evaluate(() => ({ before: window.__scrollBefore, after: conversationScrollRoot().scrollTop }));
    assert.ok(Math.abs(scroll.after - scroll.before) <= 1, `poll must preserve older-history scroll: ${JSON.stringify(scroll)}`);

    // Remove all success markers for failures, stops, reset and loading.
    for (const status of ["failed", "stopped", "partial", "blocked", "idle"]) {
      await page.evaluate(({ key, status }) => { findAgent(key).status = status; render(); }, { key: agentKey, status });
      assert.equal(await page.locator("[data-conversation-marker]").count(), 0, status);
    }
    await fixture(page, agentKey, "complete");
    assert.equal(await page.locator("[data-conversation-marker]").getAttribute("data-motion"), "rest");
    await page.evaluate((key) => { state.conversations[key].loading = true; render(); }, agentKey);
    assert.equal(await page.locator("[data-conversation-marker]").count(), 0);
    await page.evaluate((key) => state.conversationAnimationRuns.delete(`${key}:animation-run-1:complete`), agentKey);
    await fixture(page, agentKey, "complete");
    await page.emulateMedia({ reducedMotion: "reduce" });
    await page.waitForFunction(() => document.querySelector("[data-conversation-marker]").dataset.motion === "rest");
    assert.equal((await facts(page)).animations.length, 0, "reduced motion must stop an active completion");
    await page.emulateMedia({ reducedMotion: "no-preference" });
    assert.equal((await facts(page)).animations.length, 0, "changing motion preference must not replay completion");
    await fixture(page, agentKey, "running");
    await page.emulateMedia({ reducedMotion: "reduce" });
    assert.equal((await facts(page)).animations.length, 0);
    await fixture(page, agentKey, "complete");
    assert.equal((await facts(page)).animations.length, 0);
    assert.equal((await facts(page)).artOpacity, "0.2");
    assert.equal((await facts(page)).labelOpacity, "1");
    assert.equal((await facts(page)).label, "you have reached the end");
    assert.ok((await facts(page)).labelContrast >= 4.5);
    if (captureDir) {
      await bottom(page);
      await page.screenshot({ path: path.join(captureDir, `reduced-${viewport.width}.png`) });
      if (viewport.width === 1060) fs.writeFileSync(path.join(captureDir, "complete-marker.html"), await page.locator("[data-conversation-marker]").evaluate(e => e.outerHTML));
    }
    assert.deepEqual(errors, []);
    results.push({ viewport, complete, running, reducedMotion: "static", transitions: "passed", pollScrollAndDraft: "passed" });
    await page.close();
  }
  if (captureDir) fs.writeFileSync(path.join(captureDir, "measurements.json"), JSON.stringify(results, null, 2));
  console.log(JSON.stringify(results, null, 2));
};
