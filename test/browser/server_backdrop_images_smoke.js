const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const { execFileSync } = require("node:child_process");
const { chromium } = require(process.env.TYCHO_PLAYWRIGHT_PATH);
const base = process.env.TYCHO_THEME_FIXTURE_URL;
const fixture = process.env.TYCHO_THEME_FIXTURE_ROOT;
const captures = process.env.TYCHO_REMOTE_UI_CAPTURE_DIR;
const auth = { Authorization: "Bearer synthetic-theme-fixture" };
const cli = (...args) => JSON.parse(execFileSync("bin/tycho", ["appearance", "images", ...args, "--json"], { encoding: "utf8" }));
async function request(method, route, body, authenticated = true) {
  return fetch(base + route, { method, headers: { ...(authenticated ? auth : {}), "Content-Type": "application/json" }, ...(body ? { body: JSON.stringify(body) } : {}) });
}
async function main() {
  const browser = await chromium.launch({ executablePath: process.env.CHROME_PATH, headless: true });
  try {
    const context = await browser.newContext({ viewport: { width: 1440, height: 1000 }, permissions: ["clipboard-read", "clipboard-write"], reducedMotion: "reduce" });
    await context.addInitScript(() => localStorage.setItem("hq.remote.token", "synthetic-theme-fixture"));
    const page = await context.newPage();
    const errors = []; page.on("pageerror", error => errors.push(error.message));
    await page.goto(`${base}/ui#settings`);
    await page.getByRole("button", { name: "Configuration", exact: true }).click();
    await page.locator("[data-theme-guide-copy]").waitFor();
    const ready = () => page.waitForFunction(() => window.TychoBackdropImages.getState().loaded && !window.TychoBackdropImages.getState().busy);
    await ready();
    const image = await page.evaluate(() => {
      const c = document.createElement("canvas"); c.width = 1600; c.height = 900;
      const ctx = c.getContext("2d"), gradient = ctx.createLinearGradient(0, 0, 1600, 900);
      gradient.addColorStop(0, "#143642"); gradient.addColorStop(.5, "#407d8d"); gradient.addColorStop(1, "#bda67b"); ctx.fillStyle = gradient; ctx.fillRect(0, 0, 1600, 900);
      for (let row = 0; row < 5; row++) { ctx.fillStyle = ["#193f4b", "#255362", "#326b79", "#518494", "#73a1ad"][row]; ctx.beginPath(); ctx.moveTo(0, 900); for (let x = 0; x <= 1600; x += 8) ctx.lineTo(x, 450 + row * 65 + Math.sin(x / 200 + row) * 70); ctx.lineTo(1600, 900); ctx.fill(); }
      return c.toDataURL("image/png").split(",")[1];
    });
    const file = path.join(fixture, "landscape.png"); fs.writeFileSync(file, Buffer.from(image, "base64"));
    assert.equal((await request("GET", "/appearance/images", null, false)).status, 401);
    assert.equal((await request("PUT", "/appearance/images/unauthorized", { name: "No", data: image }, false)).status, 401);
    assert.equal((await request("PUT", "/appearance/images/bad", { name: "Bad", data: Buffer.from("<svg/>").toString("base64") })).status, 422);
    assert.equal((await request("GET", "/appearance/images/missing/blob")).status, 404);
    assert.equal((await request("PUT", "/appearance/images/bad", { name: "Bad", data: "x".repeat(7 * 1024 * 1024) })).status, 413);
    const upload = cli("upload", "agent-landscape", file, "--name", "Agent landscape", "--server", "fixture-peer");
    assert.equal(upload.image.id, "agent-landscape");
    assert.equal(cli("list", "--server", "fixture-peer").images.length, 1);
    const read = await request("GET", "/appearance/images/agent-landscape/blob");
    assert.equal(read.headers.get("content-type"), "image/png");
    assert.match(read.headers.get("cache-control"), /private/);
    assert.equal((await request("GET", "/servers/fixture-peer/appearance/images/agent-landscape/blob")).status, 200);
    await page.locator("[data-theme-image-retry]").evaluate(button => button.click());
    await page.waitForFunction(() => window.TychoBackdropImages.getState().library.length === 1);
    assert.equal(await page.locator("html").getAttribute("data-image-backdrop"), "none", "Agent upload does not select any browser backdrop");
    await page.locator("[data-theme-guide-copy]").click();
    const guide = await page.evaluate(() => navigator.clipboard.readText());
    assert.match(guide, /inverse, info, success, warning, danger/); assert.match(guide, /tycho appearance images upload/); assert.match(guide, /--server SERVER_KEY/); assert.match(guide, /IndexedDB cannot be read by the CLI/);
    assert.match(await page.locator("[data-theme-guide-status]").textContent(), /copied/);
    assert(await page.locator("[data-theme-guide-copy]").isVisible());
    assert(!(await page.locator("[data-custom-theme-json]").isVisible()), "JSON editor is a disclosure");
    await page.locator("[data-theme-image-library]").selectOption("agent-landscape");
    await page.waitForFunction(() => window.TychoBackdropImages.getState().image?.serverId === "agent-landscape" && document.documentElement.dataset.imageBackdrop === "ready");
    const version = await page.evaluate(() => window.TychoBackdropImages.getState().image.version);
    await page.reload(); await page.getByRole("button", { name: "Configuration", exact: true }).click(); await ready();
    await page.waitForFunction(() => document.documentElement.dataset.imageBackdrop === "ready");
    assert.equal(await page.locator("[data-theme-image-library]").inputValue(), "agent-landscape");
    // Replacement through the agent CLI invalidates selected cache data.
    const replacement = await page.evaluate(() => { const c = document.createElement("canvas"); c.width = 1200; c.height = 700; c.getContext("2d").fillRect(0, 0, 1200, 700); return c.toDataURL().split(",")[1]; });
    const second = path.join(fixture, "replacement.png"); fs.writeFileSync(second, Buffer.from(replacement, "base64"));
    cli("upload", "agent-landscape", second, "--name", "Replaced landscape", "--server", "fixture-peer");
    await page.evaluate(() => window.TychoBackdropImages.refresh());
    assert.notEqual(await page.evaluate(() => window.TychoBackdropImages.getState().image.version), version);
    assert.equal(await page.evaluate(() => window.TychoBackdropImages.getState().image.width), 1200);
    // Offline cache remains usable. Auth rejection blocks server cache rendering.
    await page.route("**/appearance/images", route => route.abort());
    await page.evaluate(() => window.TychoBackdropImages.refresh());
    assert.equal(await page.locator("html").getAttribute("data-image-backdrop"), "ready");
    await page.unroute("**/appearance/images");
    await page.route("**/appearance/images", route => route.fulfill({ status: 401, contentType: "application/json", body: '{"error":"Unauthorized"}' }));
    await page.evaluate(() => window.TychoBackdropImages.refresh());
    assert.equal(await page.locator("html").getAttribute("data-image-backdrop"), "none");
    await page.unroute("**/appearance/images");
    await page.route("**/appearance/images", route => route.abort());
    await page.evaluate(() => window.TychoBackdropImages.refresh());
    assert.equal(await page.locator("html").getAttribute("data-image-backdrop"), "none", "Offline fallback cannot bypass a prior auth rejection");
    await page.unroute("**/appearance/images"); await page.evaluate(() => window.TychoBackdropImages.refresh());
    cli("remove", "agent-landscape", "--server", "fixture-peer");
    await page.evaluate(() => window.TychoBackdropImages.refresh());
    assert.equal(await page.locator("html").getAttribute("data-image-backdrop"), "none");
    assert.match(await page.locator("[data-theme-image-status]").textContent(), /missing|damaged/);
    // Seed an actual old browser record, then verify no automatic migration.
    await page.evaluate(async data => {
      await window.TychoBackdropImages.remove();
      const db = await new Promise(resolve => { const r = indexedDB.open("tycho-backdrop-images", 1); r.onsuccess = () => resolve(r.result); });
      const bytes = Uint8Array.from(atob(data), c => c.charCodeAt(0));
      await new Promise(resolve => { const tx = db.transaction("backdrops", "readwrite"); tx.objectStore("backdrops").put({ mode: "dark", assetId: "legacy-fixture", name: "Private local landscape", width: 1600, height: 900, blob: new Blob([bytes], { type: "image/png" }), x: 73, intensity: .7 }); tx.oncomplete = resolve; }); db.close();
      await window.TychoBackdropImages.refresh();
    }, image);
    assert.equal(cli("list").images.length, 0, "Legacy images remain private");
    await page.locator("[data-theme-image-migrate]").click(); await ready();
    await page.waitForFunction(() => Boolean(window.TychoBackdropImages.getState().image?.serverId));
    assert.equal(await page.evaluate(() => window.TychoBackdropImages.getState().image.x), 73);
    assert.equal(cli("list").images.length, 1);
    // Normal file input upload and separate light-mode choice.
    await page.locator("[data-appearance-preference]").selectOption("light");
    assert.equal(await page.locator("html").getAttribute("data-image-backdrop"), "none");
    let releaseCatalog, catalogHeld;
    const heldCatalog = new Promise(resolve => { catalogHeld = resolve; });
    let held = false;
    await page.route("**/appearance/images", async route => {
      if (route.request().method() === "GET" && !held) {
        held = true; catalogHeld();
        await new Promise(resolve => { releaseCatalog = resolve; });
        await route.fulfill({ status: 200, contentType: "application/json", body: JSON.stringify({ images: cli("list").images.filter(item => item.id === migratedId) }) });
      } else await route.continue();
    });
    const migratedId = await page.evaluate(() => window.TychoBackdropImages.getState().library[0].id);
    await page.evaluate(() => { void window.TychoBackdropImages.refresh(); });
    await heldCatalog;
    const uploadedResponse = page.waitForResponse(response => response.request().method() === "PUT" && response.url().includes("/appearance/images/"));
    await page.locator("[data-theme-image-file]").setInputFiles({ name: "Uploaded landscape.png", mimeType: "image/png", buffer: Buffer.from(image, "base64") });
    await uploadedResponse;
    releaseCatalog();
    await page.waitForFunction(() => !window.TychoBackdropImages.getState().busy && Boolean(window.TychoBackdropImages.getState().image?.serverId));
    await page.unroute("**/appearance/images");
    assert.equal(await page.locator("html").getAttribute("data-image-backdrop"), "ready", "A stale catalog cannot retire a newer upload");
    await page.locator("[data-theme-example]").first().click();
    assert.equal(await page.locator("[data-theme-mode=dark]").inputValue(), "builtin:synthwave");
    const editor = page.locator("#custom-theme-json");
    await page.getByText("Edit or import theme JSON", { exact: true }).click();
    const theme = await page.evaluate(() => ({ ...window.TychoAppearance.getThemeState().sample, id: "agent-theme", name: "Agent theme" }));
    await editor.fill(JSON.stringify(theme)); await page.locator("[data-theme-save]").click();
    assert.equal(await page.locator("[data-theme-mode=dark]").inputValue(), "agent-theme");
    await page.locator("[data-theme-load=dark]").click(); assert.equal(JSON.parse(await editor.inputValue()).id, "agent-theme");
    await page.getByText("Edit or import theme JSON", { exact: true }).click();
    await require("./theme_gallery_smoke")({ page, context, base, request, captures });
    const layoutResults = await require("./appearance_layout_smoke")({ page, captures, guide });
    // The read disclosure is the fallback when clipboard permission is denied.
    await page.evaluate(() => { window.fixtureClipboardWrite = navigator.clipboard.writeText.bind(navigator.clipboard); navigator.clipboard.writeText = () => Promise.reject(new Error("fixture denied")); });
    await page.locator("[data-theme-guide-copy]").click();
    assert.match(await page.locator("[data-theme-guide-status]").textContent(), /Copy failed/);
    await page.getByText("Read guide", { exact: true }).click();
    assert.equal(await page.locator(".theme-agent-guide pre").textContent(), guide);
    await page.getByText("Read guide", { exact: true }).click();
    await page.evaluate(() => { navigator.clipboard.writeText = window.fixtureClipboardWrite; });
    // Native confirmation and server deletion remain explicit.
    await page.locator(".theme-image-settings details summary").click();
    await page.locator("[data-theme-image-delete]").click();
    await page.getByRole("button", { name: "Delete image", exact: true }).click(); await ready();
    await page.waitForFunction(() => document.documentElement.dataset.imageBackdrop === "none");
    await page.evaluate(() => window.TychoAppearance.setPreference("dark"));
    await page.waitForFunction(() => document.documentElement.dataset.imageBackdrop === "ready");
    const created = await (await request("POST", "/agents", { project_key: "fixture", template_key: "custom", name: "Theme check", prompt: "Synthetic fixture. Do not run.", agent: "codex" })).json();
    assert(created.agent, JSON.stringify(created));
    const key = created.agent.key;
    const sections = [{ title: "Theme follow-up", icon: "todo_working", items: [{ title: "Review appearance", subtitle: "Synthetic Focus content" }] }];
    const focused = await request("PUT", `/agents/${key}/focus`, { revision: 0, sections });
    assert.equal(focused.status, 200);
    for (const width of [1440, 390]) {
      await page.setViewportSize({ width, height: 900 });
      await page.goto(`${base}/ui#agent/${key}`);
      await page.locator("#prompt-input").waitFor();
      await page.waitForFunction(() => document.documentElement.dataset.imageBackdrop === "ready");
      if (!(await page.locator("[data-agent-focus]").isVisible())) await page.locator("[data-show-agent-focus]").click();
      await page.getByText("Review appearance", { exact: true }).waitFor();
      await page.evaluate(() => refresh({ force: true }));
      assert(await page.getByText("Review appearance", { exact: true }).isVisible());
      const focusColor = await page.locator("[data-agent-focus]").evaluate(el => getComputedStyle(el).backgroundColor);
      assert(!["transparent", "rgba(0, 0, 0, 0)"].includes(focusColor), "Focus surface remains solid");
      if (captures) await page.screenshot({ path: path.join(captures, `theme-focus-${width}.png`) });
      await page.goto(`${base}/ui#project/fixture/edit`);
      await page.locator("#project-delete-form").waitFor();
      await page.locator("#project-delete-form").scrollIntoViewIfNeeded();
      assert.equal(await page.locator('[name="remove_data"]').isChecked(), false);
      await page.locator('[name="confirmation"]').fill("wrong");
      await page.locator('#project-delete-form [type="submit"]').click();
      await page.getByText("Type the project key to confirm deletion.", { exact: true }).waitFor();
      await page.evaluate(() => refresh({ force: true }));
      assert.equal(await page.locator('[name="confirmation"]').inputValue(), "wrong");
      assert(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth));
      if (captures) await page.screenshot({ path: path.join(captures, `theme-danger-zone-${width}.png`) });
    }
    assert.equal(errors.length, 0, errors.join("\n"));
    console.log(JSON.stringify({ result: "passed", checks: ["authenticated API limits and invalid data", "CLI peer upload/list/replace/remove", "broker image read", "copyable guide desktop/mobile dark/light", "browser selection reload and version refresh", "offline cache and auth rejection", "explicit legacy image migration", "browser file upload", "theme import/export and scene selection", "confirmed shared removal", "Focus and Danger zone preservation", "responsive Appearance layout, advanced errors, keyboard and drafts", "imported theme gallery, previews, delete, cross-tab and image preservation"], layout_cases: layoutResults.length, screenshots: captures || null }, null, 2));
    await context.close();
  } finally { await browser.close(); }
}
main().catch(error => { console.error(error); process.exit(1); });
