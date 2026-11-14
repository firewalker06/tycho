const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");

module.exports = async function backdropImagesSmoke({ browser, baseUrl, agentKey, captureDir = "" }) {
  const context = await browser.newContext({ viewport: { width: 1440, height: 1000 }, serviceWorkers: "block", reducedMotion: "reduce" });
  await context.addInitScript(() => {
    const create = URL.createObjectURL.bind(URL), revoke = URL.revokeObjectURL.bind(URL);
    window.imageUrlAudit = { created: 0, revoked: 0, live: new Set() };
    URL.createObjectURL = blob => { const url = create(blob); if (blob.type.startsWith("image/")) { imageUrlAudit.created++; imageUrlAudit.live.add(url); } return url; };
    URL.revokeObjectURL = url => { if (imageUrlAudit.live.delete(url)) imageUrlAudit.revoked++; revoke(url); };
    const put = IDBObjectStore.prototype.put;
    IDBObjectStore.prototype.put = function (...args) { if (window.failImageWrite && this.name === "backdrops") throw new DOMException("fixture quota", "QuotaExceededError"); return put.apply(this, args); };
  });
  const page = await context.newPage();
  const route = `${baseUrl}/ui#agent/${encodeURIComponent(agentKey)}`;
  const requests = [];
  page.on("request", request => { if (request.url().startsWith(baseUrl) && !["GET", "HEAD"].includes(request.method())) requests.push(request.method() + " " + new URL(request.url()).pathname); });
  const ready = () => page.waitForFunction(() => window.TychoBackdropImages?.getState().loaded && !window.TychoBackdropImages.getState().busy);
  const saved = () => page.waitForFunction(() => document.documentElement.dataset.imageBackdrop === "ready" && !window.TychoBackdropImages.getState().busy);
  const settings = async () => {
    await page.goto(`${baseUrl}/ui#settings`);
    await page.locator("[data-theme-image-file]").waitFor(); await ready();
    await page.locator('[data-scroll-settings-section="settings-configuration"]').click();
  };
  const capture = async name => {
    await page.locator(".app-header").evaluate(async element => {
      await Promise.all(element.getAnimations().filter(animation => Number.isFinite(animation.effect.getComputedTiming().endTime)).map(animation => animation.finished.catch(() => {})));
      await new Promise(requestAnimationFrame); await new Promise(requestAnimationFrame);
    });
    if (captureDir) { fs.mkdirSync(captureDir, { recursive: true }); await page.screenshot({ path: path.join(captureDir, name + ".png") }); }
  };
  const set = async (key, value) => {
    await page.locator(`[data-theme-image-setting="${key}"]`).evaluate((element, value) => { element.value = String(value); element.dispatchEvent(new Event("change", { bubbles: true })); }, value);
    await page.waitForFunction(([key, value]) => !window.TychoBackdropImages.getState().busy && window.TychoBackdropImages.getState().image?.[key] === value, [key, value]);
  };
  const file = (buffer, mimeType = "image/png", name = "owned-landscape.png") => ({ name, mimeType, buffer });
  try {
    await settings();
    const encoded = await page.evaluate(() => {
      const canvas = document.createElement("canvas"); canvas.width = 1600; canvas.height = 1000;
      const ctx = canvas.getContext("2d");
      const sky = ctx.createLinearGradient(0, 0, 0, 1000); sky.addColorStop(0, "#10294e"); sky.addColorStop(.55, "#e7997f"); sky.addColorStop(1, "#1f3c4e"); ctx.fillStyle = sky; ctx.fillRect(0, 0, 1600, 1000);
      const sun = ctx.createRadialGradient(1250, 300, 15, 1250, 300, 350); sun.addColorStop(0, "#fff2b5"); sun.addColorStop(.2, "#ffd0a0bb"); sun.addColorStop(1, "#ffd0a000"); ctx.fillStyle = sun; ctx.fillRect(0, 0, 1600, 1000);
      for (let band = 0; band < 6; band++) {
        ctx.beginPath(); ctx.moveTo(0, 1000);
        for (let x = 0; x <= 1600; x += 4) ctx.lineTo(x, 480 + band * 68 + Math.sin(x / (150 + band * 20) + band) * (80 - band * 8) + Math.sin(x / 31 + band * 5) * 7);
        ctx.lineTo(1600, 1000); ctx.closePath(); ctx.fillStyle = ["#6e7689", "#5d6c81", "#465d74", "#304f64", "#213e51", "#102c40"][band]; ctx.fill();
      }
      const scaled = document.createElement("canvas"); scaled.width = 3200; scaled.height = 1000; scaled.getContext("2d").drawImage(canvas, 0, 0, 3200, 1000);
      return { scaled: scaled.toDataURL("image/png").split(",")[1], png: canvas.toDataURL("image/png").split(",")[1], jpeg: canvas.toDataURL("image/jpeg", .9).split(",")[1], webp: canvas.toDataURL("image/webp", .9).split(",")[1] };
    });
    const png = Buffer.from(encoded.png, "base64");
    const started = await page.evaluate(() => performance.now());
    await page.locator("[data-theme-image-file]").setInputFiles(file(png)); await saved();
    const loadMs = await page.evaluate(start => performance.now() - start, started);
    const savedBytes = await page.evaluate(() => window.TychoBackdropImages.getState().image.bytes);
    assert.equal(await page.locator("[data-theme-mode=dark]").inputValue(), "dracula", "choosing an image preserves the palette");
    assert(await page.locator("[data-theme-image-img]").evaluate(image => image.complete && image.naturalWidth === 1600));
    assert.equal(await page.evaluate(() => JSON.stringify(localStorage).includes("base64")), false);
    assert.equal(await page.evaluate(() => getComputedStyle(document.body, "::before").animationName), "none");
    const originalUrl = await page.evaluate(() => window.TychoBackdropImages.getState().image.url);
    await page.reload(); await page.locator("[data-theme-image-file]").waitFor(); await saved();
    assert.notEqual(await page.evaluate(() => window.TychoBackdropImages.getState().image.url), originalUrl, "reload reads a durable blob and creates a fresh URL");
    const peer = await context.newPage(); await peer.goto(route);
    await peer.waitForFunction(() => document.documentElement.dataset.imageBackdrop === "ready");
    await peer.locator("#prompt-input").fill("Raster tab sync preserves this draft.");
    const urlCount = await page.evaluate(() => imageUrlAudit.created);
    await page.locator("[data-theme-image-setting=x]").focus();
    await page.locator("[data-theme-image-setting=x]").press("ArrowRight");
    await page.waitForFunction(() => !window.TychoBackdropImages.getState().busy && window.TychoBackdropImages.getState().image.x === 51 && document.activeElement?.dataset.themeImageSetting === "x");
    await set("x", 75); await set("y", 35); await set("intensity", .85); await set("fade", .55);
    await peer.waitForFunction(() => window.TychoBackdropImages.getState().image?.x === 75);
    assert.match(await page.evaluate(() => getComputedStyle(document.body, "::before").backgroundPosition), /75% 35%/);
    assert.equal(await peer.locator("#prompt-input").inputValue(), "Raster tab sync preserves this draft.");
    assert.equal(await page.evaluate(() => imageUrlAudit.created), urlCount, "settings changes reuse the decoded object URL");
    await page.evaluate(() => refresh({ force: true }));
    assert.equal(await page.locator("[data-theme-image-setting=x]").inputValue(), "75", "polling keeps saved image controls");
    for (const [mime, key] of [["image/jpeg", "jpeg"], ["image/webp", "webp"]]) {
      const before = await page.evaluate(() => window.TychoBackdropImages.getState().image.url);
      await page.locator("[data-theme-image-file]").setInputFiles(file(Buffer.from(encoded[key], "base64"), mime, `replacement.${key}`)); await saved();
      assert.notEqual(await page.evaluate(() => window.TychoBackdropImages.getState().image.url), before);
      assert(await page.evaluate(url => !imageUrlAudit.live.has(url), before), "replacement revokes the old URL");
    }
    await page.locator("[data-theme-image-file]").setInputFiles(file(Buffer.from(encoded.scaled, "base64")));
    await saved();
    assert.equal(await page.evaluate(() => window.TychoBackdropImages.getState().image.width), 2560, "large input is bounded in the stored raster copy");
    await page.locator("[data-theme-image-file]").setInputFiles(file(png)); await saved();
    const prior = await page.evaluate(() => window.TychoBackdropImages.getState().image.url);
    const oversized = Buffer.from(png); oversized.writeUInt32BE(5000, 16);
    const corrupt = png.subarray(0, 24);
    for (const [input, message] of [
      [file(Buffer.from('<svg xmlns="http://www.w3.org/2000/svg"/>'), "image/svg+xml", "active.svg"), /PNG, JPEG, or WebP/],
      [file(png, "image/jpeg", "wrong.jpg"), /not a supported/],
      [file(Buffer.alloc(5 * 1024 * 1024 + 1)), /5 MiB/],
      [file(oversized), /dimensions/], [file(corrupt), /decoded/]
    ]) {
      await page.locator("[data-theme-image-file]").setInputFiles(input);
      await page.waitForFunction(() => !window.TychoBackdropImages.getState().busy && !!window.TychoBackdropImages.getState().error);
      assert.match(await page.locator("[data-theme-image-status]").textContent(), message);
      assert.equal(await page.evaluate(() => window.TychoBackdropImages.getState().image.url), prior, "rejected files retain the previous image");
    }
    await page.evaluate(() => { window.failImageWrite = true; });
    await page.locator("[data-theme-image-file]").setInputFiles(file(png));
    await page.waitForFunction(() => !window.TychoBackdropImages.getState().busy && window.TychoBackdropImages.getState().error.includes("Cannot save"));
    assert.equal(await page.evaluate(() => window.TychoBackdropImages.getState().image.url), prior);
    await page.evaluate(() => { window.failImageWrite = false; });
    await page.locator("[data-theme-image-retry]").click(); await ready();
    const download = page.waitForEvent("download"); await page.locator("[data-theme-image-download]").click();
    const exported = await download;
    assert.match(exported.suggestedFilename(), /^tycho-backdrop-dark\.(webp|png)$/);
    const transfer = fs.readFileSync(await exported.path());
    await page.evaluate(() => window.TychoAppearance.setPreference("light"));
    assert.equal(await page.locator("html").getAttribute("data-image-backdrop"), "none", "dark and light images are independent");
    await page.locator("[data-theme-image-file]").setInputFiles(file(transfer, "image/webp", "transferred.webp")); await saved();
    await page.evaluate(() => window.TychoAppearance.setPreference("dark"));
    assert.equal(await page.evaluate(() => window.TychoBackdropImages.getState().image.x), 75);
    const focusApi = `${baseUrl}/agents/${agentKey}/focus`;
    const focusBefore = await (await context.request.get(focusApi)).json();
    const focusSave = await context.request.put(focusApi, { data: { revision: focusBefore.focus.revision, sections: [
      { title: "Theme integration", subtitle: "Synthetic Focus fixture", icon: "todo_done", items: [{ title: "Raster and peer panels", subtitle: "Keep text surfaces opaque and the Close control borderless." }] }
    ] } });
    assert(focusSave.ok(), await focusSave.text());
    for (const [device, viewport] of Object.entries({ desktop: { width: 1440, height: 1000 }, mobile: { width: 390, height: 844 } })) {
      await page.setViewportSize(viewport);
      for (const colorMode of ["dark", "light"]) {
        await page.evaluate(mode => window.TychoAppearance.setPreference(mode), colorMode); await saved();
        await page.goto(route); await page.locator("#prompt-input").fill(`Local raster backdrop - ${colorMode} ${device}.`); await saved();
        assert.equal(await page.evaluate(() => document.documentElement.scrollWidth > innerWidth), false);
        if (device === "mobile") await page.waitForFunction(() => Math.abs(document.querySelector(".app-header").getBoundingClientRect().left) < 1);
        const focusPanel = page.locator("[data-agent-focus]");
        const openFocus = page.locator("[data-show-agent-focus]");
        const closeFocus = page.getByRole("button", { name: "Close Focus panel", exact: true });
        if (!(await focusPanel.isVisible())) await openFocus.click();
        await focusPanel.waitFor({ state: "visible" });
        assert(await focusPanel.evaluate(element => {
          const probe = document.createElement("div"); probe.style.background = "var(--ds-background-surface)"; probe.style.visibility = "hidden";
          document.body.append(probe); const expected = getComputedStyle(probe).backgroundColor; probe.remove();
          return getComputedStyle(element).backgroundColor === expected;
        }), "Focus inherits the opaque semantic surface over raster art");
        assert.equal(await closeFocus.evaluate(element => getComputedStyle(element).borderTopWidth), "0px");
        await capture(`raster-${colorMode}-${device}-focus`);
        await closeFocus.click();
        await focusPanel.waitFor({ state: "hidden" });
        assert.equal(await page.locator("#prompt-input").inputValue(), `Local raster backdrop - ${colorMode} ${device}.`);
        await capture(`raster-${colorMode}-${device}-conversation`);
        await settings();
        await page.locator(".theme-image-preview").evaluate(element => element.scrollIntoView({ block: "center", behavior: "instant" }));
        await capture(`raster-${colorMode}-${device}-settings`);
      }
    }
    await page.setViewportSize({ width: 1440, height: 1000 });
    const scroll = await page.evaluate(async () => {
      const gaps = [], scroller = settingsScrollRoot(); let last = performance.now();
      for (let i = 0; i < 45; i++) { await new Promise(requestAnimationFrame); const now = performance.now(); if (i) gaps.push(now - last); last = now; scroller.scrollTop += i % 2 ? -12 : 12; }
      gaps.sort((a, b) => a - b); return { medianMs: gaps[Math.floor(gaps.length / 2)], p95Ms: gaps[Math.floor(gaps.length * .95)], maxMs: gaps.at(-1) };
    });
    console.log("raster measurements: " + JSON.stringify({ browser: browser.version(), loadMs, inputBytes: png.length, savedBytes, viewport: "1440x1000", scroll }));
    // Remove from another tab and verify fallback plus object-URL cleanup.
    await page.evaluate(() => window.TychoBackdropImages.remove());
    await peer.waitForFunction(() => window.TychoBackdropImages.getState().mode === "light" && !window.TychoBackdropImages.getState().image);
    assert.equal(await page.locator("html").getAttribute("data-image-backdrop"), "none");
    await page.evaluate(async () => {
      const db = await new Promise(resolve => { const request = indexedDB.open("tycho-backdrop-images", 1); request.onsuccess = () => resolve(request.result); });
      await new Promise(resolve => { const transaction = db.transaction("backdrops", "readwrite"); transaction.objectStore("backdrops").put({ mode: "light", assetId: "missing", name: "missing fixture" }); transaction.oncomplete = resolve; }); db.close();
      await window.TychoBackdropImages.refresh();
    });
    assert.match(await page.locator("[data-theme-image-status]").textContent(), /missing or damaged/);
    assert.equal(await page.locator("html").getAttribute("data-image-backdrop"), "none");
    await page.locator("[data-theme-image-remove]").click(); await ready();
    // A late decode must not restore an image after removal.
    await page.evaluate(async () => {
      const original = window.createImageBitmap; let release;
      window.createImageBitmap = async (...args) => { await new Promise(resolve => { release = resolve; window.imageRace.waiting = true; }); return original(...args); };
      window.imageRace = { release: () => release(), original, waiting: false, finished: false };
      const choose = window.TychoBackdropImages.choose;
      window.TychoBackdropImages.choose = (...args) => choose(...args).finally(() => { window.imageRace.finished = true; });
    });
    await page.locator("[data-theme-image-file]").setInputFiles(file(png));
    await page.waitForFunction(() => window.imageRace.waiting);
    await page.evaluate(() => window.TychoBackdropImages.remove());
    await page.evaluate(() => { imageRace.release(); window.createImageBitmap = imageRace.original; });
    await ready();
    await page.waitForFunction(() => window.imageRace.finished);
    assert.equal(await page.locator("html").getAttribute("data-image-backdrop"), "none");
    assert.deepEqual(requests.filter(request => !["POST /push/status", "POST /servers/resources/refresh"].includes(request)), [], "images make no API writes; existing status/resource refresh calls remain");
    await page.evaluate(() => window.TychoBackdropImages.dispose());
    assert.equal(await page.evaluate(() => imageUrlAudit.live.size), 0, "disposing revokes all cached image URLs");
    await peer.close();
    const denied = await browser.newContext({ serviceWorkers: "block" });
    await denied.addInitScript(() => { const open = indexedDB.open.bind(indexedDB); window.denyImageStorage = true; indexedDB.open = (...args) => { if (window.denyImageStorage) throw new Error("fixture denied"); return open(...args); }; });
    const blocked = await denied.newPage(); await blocked.goto(`${baseUrl}/ui#settings`);
    await blocked.locator("[data-theme-image-file]").waitFor();
    await blocked.waitForFunction(() => window.TychoBackdropImages.getState().loaded);
    assert.match(await blocked.locator("[data-theme-image-status]").textContent(), /storage is unavailable/);
    await blocked.evaluate(() => { window.denyImageStorage = false; });
    await blocked.locator("[data-theme-image-retry]").click();
    await blocked.waitForFunction(() => window.TychoBackdropImages.getState().loaded && !window.TychoBackdropImages.getState().error);
    await denied.close();
    console.log("backdrop_images_smoke: ok");
  } finally { await context.close(); }
};
