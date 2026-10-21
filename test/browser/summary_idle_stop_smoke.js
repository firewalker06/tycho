const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");

module.exports = async ({ browser, baseUrl, agentKey, captureDir }) => {
  const errors = [];
  const results = [];
  if (captureDir) fs.mkdirSync(captureDir, { recursive: true });
  for (const viewport of [{width: 1440, height: 900}, {width: 390, height: 844}]) {
    const context = await browser.newContext({viewport, isMobile: viewport.width < 500, hasTouch: viewport.width < 500});
    const page = await context.newPage();
    page.on("pageerror", error => errors.push(error.message));
    for (const id of ["legacy-idle", "explicit-idle", "manual-stop", "rich-summary"]) {
      await page.goto(`${baseUrl}/ui#agent/${encodeURIComponent(agentKey)}/summary/${id}`, {waitUntil: "networkidle"});
      const summary = page.locator("[data-agent-summary-page]");
      await summary.waitFor({state: "visible"});
      const check = async () => {
        await page.waitForFunction((id) => {
          const agent = findAgent(parseRoute().key);
          return agent && agentSummaryDetail(agent, id).id === id;
        }, id, {timeout: 10000});
        const text = await summary.innerText();
        if (id.endsWith("idle")) {
          assert(text.includes("no structured agent output stayed idle for 300 seconds."), `${id}: reason absent at ${viewport.width}`);
          assert(text.includes("Run context"));
        } else if (id === "manual-stop") {
          assert(!text.includes("stayed idle"), "manual stop inherited idle reason");
          assert(text.includes("interrupted"));
        } else {
          assert(text.includes("Rich summary detail remains visible."));
          assert(!text.includes("stayed idle"));
        }
        assert(!text.includes("SYNTHETIC_") && !text.includes("example.test"), "wrapper secret reached Summary");
        const layout = await page.evaluate(() => {
          const summary = document.querySelector("[data-agent-summary-page]");
          const context = summary.querySelector("blockquote");
          const rect = (context || summary).getBoundingClientRect();
          return {width: innerWidth, overflow: document.documentElement.scrollWidth > innerWidth + 1, left: rect.left, right: rect.right, bottom: rect.bottom};
        });
        assert(!layout.overflow && layout.left >= 0 && layout.right <= viewport.width + 1, `Summary overflow: ${JSON.stringify(layout)}`);
        return layout;
      };
      await check();
      // Verify a persisted cold load, then a real polling refresh.
      await page.reload({waitUntil: "networkidle"});
      await summary.waitFor({state: "visible"});
      await check();
      await page.evaluate(async () => { await refresh({force: true}); });
      const layout = await check();
      if (captureDir && id.endsWith("idle")) {
        await page.screenshot({path: path.join(captureDir, `summary-${id}-${viewport.width}.png`), fullPage: false});
      }
      results.push({id, width: viewport.width, coldReload: true, pollingRefresh: true, layout});
    }
    await context.close();
  }
  assert.deepEqual(errors, []);
  if (captureDir) fs.writeFileSync(path.join(captureDir, "summary-idle-stop-results.json"), JSON.stringify(results, null, 2));
  console.log(`summary-idle-stop-smoke: ${JSON.stringify(results)}`);
};
