const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");

module.exports = async function logoSmoke({ browser, baseUrl, captureDir = "" }) {
  const context = await browser.newContext({ viewport: { width: 1440, height: 900 }, reducedMotion: "reduce", serviceWorkers: "block" });
  await context.addInitScript(() => localStorage.setItem("hq.remote.appearance", "light"));
  const page = await context.newPage();
  const capture = async (name) => {
    if (!captureDir) return;
    fs.mkdirSync(captureDir, { recursive: true });
    await page.screenshot({ path: path.join(captureDir, `${name}.png`) });
  };
  const logoContent = (selector) => page.locator(selector).first().evaluate((el) => getComputedStyle(el).content);
  const checkMode = async (mode) => {
    const content = await logoContent(".brand-logo");
    assert(mode === "light" ? content.includes("/remote-logo-light.png?v=") : content === "normal", `header selects ${mode}: ${content}`);
    assert.equal(await page.locator(".brand-logo").first().getAttribute("alt"), "");
    assert.equal(await page.locator("#header-mark").getAttribute("aria-label").then((v) => v.includes("Open agent switcher")), true);
  };
  try {
    // Hold the app script to inspect the real first-paint shell, before hydration.
    let release;
    const gate = new Promise((resolve) => { release = resolve; });
    await page.route("**/ui.js?*", async (route) => { await gate; await route.continue(); });
    const navigation = page.goto(`${baseUrl}/ui`, { waitUntil: "load" });
    await page.locator(".tycho-boot-mark").waitFor();
    await page.waitForFunction(() => getComputedStyle(document.querySelector(".brand-logo")).content.includes("remote-logo-light"));
    assert.equal(await page.locator(".tycho-boot-light").first().evaluate((el) => getComputedStyle(el).stroke), "rgb(46, 52, 64)");
    assert.equal(await page.locator(".tycho-boot-mark path").first().evaluate((el) => getComputedStyle(el).stroke), "rgb(255, 138, 0)");
    assert.equal(await page.locator(".tycho-boot-mark").evaluate((el) => getComputedStyle(el).animationName), "none");
    await capture("logo-light-desktop-boot");
    await page.setViewportSize({ width: 390, height: 844 });
    await capture("logo-light-mobile-boot");
    release();
    await navigation;
    await page.unroute("**/ui.js?*");
    await page.waitForFunction(() => typeof state === "object" && state.setup);
    await page.locator("#tycho-boot-shell").waitFor({ state: "hidden" });

    // Decoded pixel checks prove the export preserves every alpha and orange pixel.
    const pixels = await page.evaluate(async () => {
      const results = [];
      for (const [name, cx, cy, radius] of [["remote-logo", 130, 130, 65], ["remote-logo-horizontal", 118.5, 112.5, 50]]) {
        const read = async (suffix) => {
          const image = new Image(); image.src = `/${name}${suffix}.png`; await image.decode();
          const canvas = document.createElement("canvas"); canvas.width = image.width; canvas.height = image.height;
          const ctx = canvas.getContext("2d"); ctx.drawImage(image, 0, 0);
          return { width: image.width, height: image.height, data: ctx.getImageData(0, 0, image.width, image.height).data };
        };
        const a = await read(""), b = await read("-light");
        let alphaErrors = 0, orangeErrors = 0, changed = 0;
        for (let i = 0; i < a.data.length; i += 4) {
          if (a.data[i + 3] !== b.data[i + 3]) alphaErrors++;
          const x = (i / 4) % a.width - cx, y = Math.floor(i / 4 / a.width) - cy;
          const orange = x < 0 && y < 0 && x * x + y * y > radius * radius;
          for (let c = 0; c < 3; c++) if (a.data[i + c] !== b.data[i + c]) { if (orange) orangeErrors++; changed++; }
        }
        results.push({ name, dimensionsMatch: a.width === b.width && a.height === b.height, alphaErrors, orangeErrors, changed });
      }
      return results;
    });
    for (const result of pixels) {
      assert(result.dimensionsMatch); assert.equal(result.alphaErrors, 0); assert.equal(result.orangeErrors, 0); assert(result.changed > 0);
    }
    console.log("Logo pixel preservation:", JSON.stringify(pixels));

    for (const [device, viewport] of Object.entries({ desktop: { width: 1440, height: 900 }, mobile: { width: 390, height: 844 } })) {
      await page.setViewportSize(viewport);
      for (const mode of ["light", "dark"]) {
        await page.evaluate((mode) => { window.TychoAppearance.setPreference(mode); renderOnboarding(); }, mode);
        await checkMode(mode);
        const content = await logoContent(".onboarding-logo-horizontal");
        assert(mode === "light" ? content.includes("remote-logo-horizontal-light.png?v=") : content === "normal");
        assert.equal(await page.locator(".onboarding-logo-horizontal").getAttribute("alt"), "");
        await page.evaluate(async () => { await Promise.all([...document.images].map((img) => img.decode().catch(() => {}))); });
        await capture(`logo-${mode}-${device}-onboarding`);
        if (mode === "light") {
          // Before preview: the same live page with the original logo selection.
          const style = await page.addStyleTag({ content: ".brand-logo, .onboarding-logo-horizontal { content: normal !important; }" });
          await capture(`logo-before-${device}-onboarding`);
          await style.evaluate((el) => el.remove());
        }
        await page.evaluate(() => replaceView(tychoLoadingState("Loading agents...")));
        assert((await logoContent(".tycho-loading-logo")) === (mode === "light" ? await logoContent(".brand-logo") : "normal"));
        assert.equal(await page.locator(".tycho-loading-state").getAttribute("role"), "status");
        assert.equal(await page.locator(".tycho-loading-logo").evaluate((el) => getComputedStyle(el).animationName), "none");
        await capture(`logo-${mode}-${device}-loading`);
        assert(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth), "no horizontal overflow");
      }
    }
    await page.evaluate(() => window.TychoAppearance.setPreference("system"));
    for (const mode of ["light", "dark", "light"]) {
      await page.emulateMedia({ colorScheme: mode });
      await page.waitForFunction((mode) => document.documentElement.dataset.appearance === mode, mode);
      await checkMode(mode);
    }
    await page.evaluate(() => window.TychoAppearance.setPreference("light"));
    await page.reload();
    await page.waitForFunction(() => typeof state === "object" && state.setup);
    await checkMode("light");
    console.log("Logo browser checks passed: first paint, pixels, header, onboarding, loading, desktop/mobile, System changes, reload.");
  } finally { await context.close(); }
};
