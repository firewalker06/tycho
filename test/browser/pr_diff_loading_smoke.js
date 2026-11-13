const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");

module.exports = async ({ browser, baseUrl, agentKey, captureDir }) => {
  const evidence = [];
  const baseline = process.env.TYCHO_REMOTE_UI_PR_DIFF_LOADING_BASELINE;
  for (const [device, viewport] of Object.entries({ desktop: { width: 1440, height: 900 }, mobile: { width: 390, height: 844 } })) {
    const context = await browser.newContext({ viewport, hasTouch: device === "mobile" });
    const page = await context.newPage();
    const errors = [], calls = [], saved = new Map();
    let inFlight = 0, peak = 0, baselineServed = false, failureMode = false, selectedResponseAt = 0;
    const delay = Number(device === "desktop" ? process.env.TYCHO_REMOTE_UI_PR_DIFF_DELAY_MS || 160 : 160);
    const refs = Array.from({ length: 15 }, (_, i) => ({ id: `pr-${i + 1}`, title: `Synthetic PR ${i + 1}`, repository: "example/fixture", number: i + 1, url: `https://github.com/example/fixture/pull/${i + 1}` }));
    const diff = id => ({ ...refs.find(r => r.id === id), snapshot_id: `snapshot-${id}`, fetched_at: "2026-11-13T00:00:00Z", diff_format: "github_diff_v3", file_count: 1, additions: 1, deletions: 0, files: [{ path: "fixture.txt", status: "modified", additions: 1, deletions: 0, hunks: [{ header: "@@ -0,0 +1 @@", lines: [{ kind: "added", content: "Synthetic visible change", new_number: 1 }] }] }] });
    page.on("pageerror", error => errors.push(error.message));
    if (baseline) await page.route("**/ui.js*", r => { baselineServed = true; return r.fulfill({ contentType: "text/javascript", body: ["prompt_submissions.js", "inquiry_submissions.js"].map(name => fs.readFileSync(path.join(__dirname, "../../lib/hq/remote_ui/assets", name), "utf8")).join("\n") + "\n" + fs.readFileSync(baseline, "utf8") }); });
    await page.route("**/agents/*/pull-requests**", async route => {
      const request = route.request(), pathname = new URL(request.url()).pathname;
      const send = body => route.fulfill({ contentType: "application/json", body: JSON.stringify(body) });
      if (pathname.endsWith("/pull-requests")) return send({ pull_requests: refs.map(r => ({ ...r, snapshot: saved.has(r.id) ? { snapshot_id: `snapshot-${r.id}`, file_count: 1 } : null })), catalog_revision: 1 });
      if (pathname.endsWith("/pull-requests/refresh")) {
        calls.push("bulk");
        const refreshed = [];
        for (const ref of refs) { await new Promise(r => setTimeout(r, delay)); saved.set(ref.id, true); refreshed.push(diff(ref.id)); }
        selectedResponseAt = Date.now();
        return send({ refreshed, failed: [] });
      }
      const id = pathname.split("/").at(-2);
      calls.push(id); inFlight++; peak = Math.max(peak, inFlight);
      await new Promise(r => setTimeout(r, failureMode ? 10 : delay));
      inFlight--;
      if (failureMode && ["pr-15", "pr-3"].includes(id)) return route.fulfill({ status: 403, contentType: "application/json", body: JSON.stringify({ error: "Synthetic denied PR" }) });
      saved.set(id, true);
      if (id === "pr-15" && !failureMode) selectedResponseAt = Date.now();
      return send({ diff: diff(id) });
    });
    const started = Date.now();
    await page.goto(`${baseUrl}/ui#agent/${encodeURIComponent(agentKey)}/pr-diffs/pr-15`);
    await page.locator(".pr-diff-nav-item").first().waitFor();
    const listMs = Date.now() - started;
    await page.waitForFunction(() => !state.refreshInFlight);
    const fetching = Date.now();
    await page.locator("[data-refresh-all-pr-diffs]").click();
    await page.locator('[data-pr-diff-viewer][data-pull-request-id="pr-15"]').waitFor({ timeout: 120000 });
    const selectedMs = Date.now() - fetching;
    const renderAfterResponseMs = Date.now() - selectedResponseAt;
    const pendingAtSelected = await page.evaluate(() => Object.values(state.pullRequestDiffFetches).filter(r => r.pullRequestId).length);
    if (baseline) { assert(baselineServed, "baseline asset must be served"); assert.equal(calls[0], "bulk"); }
    if (!baseline) { assert.equal(calls[0], "pr-15"); assert(peak <= 3); assert(pendingAtSelected > 0, "selected diff must display before the batch ends"); }
    if (captureDir) {
      await page.locator("[data-toggle-pr-diff-full-view]").click();
      await page.evaluate(() => document.fonts.ready);
      await page.waitForFunction(() => Boolean(state.pullRequestDiffRenderReadyKey));
      await page.waitForTimeout(250);
      if (device === "mobile") await page.locator("[data-pr-diff-viewer]").scrollIntoViewIfNeeded();
      await page.screenshot({ path: path.join(captureDir, `${device}-${baseline ? "before" : "after"}-selected.png`) });
    }
    await page.waitForFunction(() => !Object.keys(state.pullRequestDiffFetches).length, null, { timeout: 120000 });
    const allMs = Date.now() - fetching;
    assert.equal(saved.size, 15);
    const geometry = await page.evaluate(() => ({ page: document.documentElement.scrollWidth, width: innerWidth }));
    assert(geometry.page <= geometry.width + 1, JSON.stringify(geometry));
    assert.deepEqual(errors, []);
    if (!baseline) {
      failureMode = true;
      await page.locator("[data-refresh-all-pr-diffs]").click();
      await page.waitForFunction(() => !Object.keys(state.pullRequestDiffFetches).length);
      assert.equal(await page.evaluate(key => state.pullRequestDiffs[pullRequestDiffKey(key, "pr-15")]?.snapshot_id, agentKey), "snapshot-pr-15", "failed selected refresh preserves the saved diff");
      for (const preference of ["light", "system"]) {
        await page.evaluate(value => TychoAppearance.setPreference(value), preference);
        await page.waitForTimeout(100);
        assert(await page.locator('[data-pr-diff-viewer][data-pull-request-id="pr-15"]').isVisible());
        assert(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth + 1));
        if (captureDir) await page.screenshot({ path: path.join(captureDir, `${device}-${preference}-saved-after-failure.png`) });
      }
    }
    assert.deepEqual(errors, []);
    evidence.push({ device, baseline: Boolean(baseline), listMs, selectedMs, renderAfterResponseMs, allMs, peak, pendingAtSelected, calls: calls.length });
    await context.close();
  }
  if (captureDir) fs.writeFileSync(path.join(captureDir, baseline ? "before.json" : "after.json"), JSON.stringify(evidence, null, 2));
  console.log(JSON.stringify(evidence));
};
