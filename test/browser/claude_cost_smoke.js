const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");

module.exports = async ({ browser, baseUrl, agentKey, captureDir }) => {
  const errors = [];
  const results = [];
  for (const viewport of [{ width: 1440, height: 900 }, { width: 390, height: 844 }]) {
    const context = await browser.newContext({ viewport, isMobile: viewport.width < 500, hasTouch: viewport.width < 500 });
    const page = await context.newPage();
    page.on("pageerror", error => errors.push(error.message));
    await page.goto(`${baseUrl}/ui#agent/${encodeURIComponent(agentKey)}`, { waitUntil: "networkidle" });
    const ids = await page.evaluate(async key => {
      await ensureConversation(findAgent(key), true);
      return runSummaryBlocks(findAgent(key)).map(block => ({ id: runSummaryId(block), run: block.metadata.run_number }));
    }, agentKey);
    assert.equal(ids.length, 4);
    for (const item of ids) {
      await page.goto(`${baseUrl}/ui#agent/${encodeURIComponent(agentKey)}/summary/${encodeURIComponent(item.id)}`, { waitUntil: "networkidle" });
      const summary = page.locator("[data-agent-summary-page]");
      await summary.waitFor({ state: "visible" });
      const check = async () => {
        const text = await summary.innerText();
        if (item.run === 0) {
          assert(text.includes("Saved est. cost") && text.includes("$458.58+"), text);
        } else {
          const expected = ["$1.25", "$0.75", "$0.50"][item.run - 1];
          assert(text.includes("Run est. cost") && text.includes(expected), text);
          assert(!text.includes("$3.25") && !text.includes("$5.75"), text);
        }
        const layout = await page.evaluate(() => ({ width: innerWidth, scrollWidth: document.documentElement.scrollWidth }));
        assert(layout.scrollWidth <= layout.width + 1, JSON.stringify(layout));
        return text;
      };
      await check();
      await page.reload({ waitUntil: "networkidle" });
      await summary.waitFor({ state: "visible" });
      await check();
      await page.evaluate(async () => refresh({ force: true, forceConversation: true }));
      const text = await check();
      results.push({ viewport, run: item.run, text });
      if (captureDir && item.run === 3) {
        fs.mkdirSync(captureDir, { recursive: true });
        await page.screenshot({ path: path.join(captureDir, `claude-cost-${viewport.width}.png`) });
      }
    }
    assert.equal(await page.evaluate(() => summaryCostSnapshotText({ run_cost_scope: "run", run_amount_usd: null })), "Unavailable");
    assert.equal(await page.evaluate(() => sessionCostSnapshotText({ amount_usd: null })), "Unavailable");
    await context.close();
  }
  assert.deepEqual(errors, []);
  if (captureDir) fs.writeFileSync(path.join(captureDir, "claude-cost-results.json"), JSON.stringify(results, null, 2));
  console.log("claude_cost_smoke: ok (desktop/mobile, three resumed runs, legacy, reload, polling, missing cost)");
};
