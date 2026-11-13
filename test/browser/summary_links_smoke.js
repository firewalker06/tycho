const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");

module.exports = async ({ browser, baseUrl, agentKey, captureDir }) => {
  const results = [];
  for (const width of [1440, 390]) for (const theme of ["dark", "light"]) {
    const context = await browser.newContext({ viewport: { width, height: 900 }, isMobile: width === 390, hasTouch: width === 390 });
    const errors = [];
    const page = await context.newPage();
    page.on("pageerror", error => errors.push(error.message));
    await context.route("https://example.test/**", route => route.fulfill({ contentType: "text/html", body: "<h1>Synthetic destination</h1>" }));
    let baselineServed = false;
    if (process.env.TYCHO_REMOTE_UI_SUMMARY_LINKS_BASELINE) {
      await page.route("**/ui.js*", route => {
        baselineServed = true;
        const transport = ["prompt_submissions.js", "inquiry_submissions.js"].map(name => fs.readFileSync(path.join(__dirname, "../../lib/hq/remote_ui/assets", name), "utf8")).join("\n");
        return route.fulfill({ contentType: "application/javascript", body: transport + "\n" + fs.readFileSync(process.env.TYCHO_REMOTE_UI_SUMMARY_LINKS_BASELINE, "utf8") });
      });
    }
    await page.goto(`${baseUrl}/ui#agent/${agentKey}/summary/links-2`, { waitUntil: "networkidle" });
    await page.evaluate(theme => window.TychoAppearance.setPreference(theme), theme);
    const summary = page.locator("[data-agent-summary-page]");
    await summary.locator(".summary-sections").waitFor();
    if (captureDir) {
      fs.mkdirSync(captureDir, { recursive: true });
      await page.screenshot({ path: path.join(captureDir, `summary-links-${theme}-${width}.png`) });
    }
    if (process.env.TYCHO_REMOTE_UI_SUMMARY_LINKS_BASELINE) assert(baselineServed, "pinned baseline served");
    const rows = summary.locator(".summary-sections a.summary-attachment-row");
    assert.equal(await rows.count(), 4, "link blocks must use the same attachment row as nested link/file blocks");
    const first = rows.nth(0);
    assert((await first.innerText()).includes("Change #42"));
    assert((await first.innerText()).includes("link"));
    const target = "https://example.test/review/42?view=full&tab=files#diff";
    assert.equal(await first.getAttribute("href"), target);
    assert.equal(await first.getAttribute("target"), "_blank");
    assert((await first.getAttribute("rel")).includes("noreferrer"));
    assert.equal(await summary.locator('a.summary-attachment-row[href="https://example.test/review/42?view=full&tab=files#diff"]').count(), 1, "no duplicate footer");
    const data = await page.evaluate(key => agentAttachments(findAgent(key)).map(item => ({ type: item.type, title: item.title, path: item.path, url: item.url })), agentKey);
    assert.equal(data.filter(item => item.url === target).length, 1);
    assert.equal(data.filter(item => item.type === "file").length, 2, "links must not create file resources");
    assert.equal(await first.locator("[data-download-attachment]").count(), 0);
    const popupEvent = page.waitForEvent("popup");
    if (width === 390) await first.tap();
    else { await first.focus(); await first.press("Enter"); }
    const popup = await popupEvent;
    await popup.waitForLoadState();
    assert.equal(popup.url(), target);
    assert.equal(await popup.evaluate(() => window.opener), null);
    await popup.close();
    await page.evaluate(() => refresh({ force: true, forceConversation: true }));
    assert.equal(await rows.count(), 4);
    await page.reload({ waitUntil: "networkidle" });
    assert.equal(await rows.count(), 4);
    const bounds = await summary.locator(".summary-sections").evaluate(el => ({ left: el.getBoundingClientRect().left, right: el.getBoundingClientRect().right, width: innerWidth, overflow: document.documentElement.scrollWidth > innerWidth }));
    assert(bounds.left >= 0 && bounds.right <= width + 1 && !bounds.overflow, JSON.stringify(bounds));
    await rows.nth(2).click();
    await page.waitForFunction(() => document.querySelector(".agent-attachment-viewer")?.innerText.includes("The local file still opens."));
    await page.goto(`${baseUrl}/ui#agent/${agentKey}/summary/links-2`, { waitUntil: "networkidle" });
    await rows.nth(3).click();
    await page.waitForFunction(() => [...document.querySelectorAll(".agent-attachment-viewer img")].some(img => img.complete && img.naturalWidth > 0));
    await page.goto(`${baseUrl}/ui#agent/${agentKey}/summary/links-1`, { waitUntil: "networkidle" });
    assert.equal(await summary.locator(".summary-sections a.summary-attachment-row").count(), 1, "historical link-only blocks work without catalog IDs");
    assert.equal(await summary.locator(".summary-sections a.summary-attachment-row").getAttribute("href"), target);
    assert.deepEqual(errors, []);
    results.push({ width, theme, bounds, resources: data.map(item => ({ type: item.type, title: item.title })) });
    await context.close();
  }
  if (captureDir) fs.writeFileSync(path.join(captureDir, "summary-links-results.json"), JSON.stringify(results, null, 2));
  console.log("summary_links_smoke: ok (named link rows, exact URLs, safe navigation, resource types, no duplicate footer, files/images, history, reload/polling, desktop/mobile Dark/Light)");
};
