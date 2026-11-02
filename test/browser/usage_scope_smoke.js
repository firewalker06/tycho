const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");

module.exports = async ({ browser, baseUrl, agentKey, captureDir }) => {
  const results = [];
  for (const width of [1440, 390]) for (const theme of ["dark", "light"]) {
    const context = await browser.newContext({ viewport: { width, height: 900 }, isMobile: width < 500, hasTouch: width < 500 });
    const page = await context.newPage();
    const errors = [];
    page.on("pageerror", error => errors.push(error.message));
    await page.goto(`${baseUrl}/ui#settings`, { waitUntil: "networkidle" });
    await page.locator("[data-appearance-preference]").selectOption(theme);
    await page.goto(`${baseUrl}/ui#agent/${agentKey}`, { waitUntil: "networkidle" });
    await page.evaluate(async key => ensureConversation(findAgent(key), true), agentKey);
    for (const run of [126, 127, 125]) {
      await page.goto(`${baseUrl}/ui#agent/${agentKey}/summary/usage-${run}`, { waitUntil: "networkidle" });
      const summary = page.locator("[data-agent-summary-page]");
      await summary.waitFor({ state: "visible" });
      await page.waitForFunction(run => document.querySelector(".agent-summary-heading")?.innerText.includes(`Run #${run}`), run);
      const check = async () => {
        const text = await summary.innerText();
        const expected = { 125: "Untracked", 126: "$30.17", 127: "$30.77+" }[run];
        const cards = await summary.locator(".summary-outcome-grid .kv").allInnerTexts();
        assert.equal(cards.length, 4, "original four metric cards");
        assert(cards[0].includes("Outcome"));
        assert(cards[1].includes("Total Runs") && cards[1].includes("127"));
        assert(cards[2].includes("Est. total cost") && cards[2].includes(expected), cards[2]);
        assert(cards[3].includes("Attachments"));
        assert(!text.includes("Selected run usage") && !text.includes("Native session usage"));
        assert(!text.includes("About usage and estimates"));
        assert(!text.includes("$0.0579"));
        if (run !== 127) assert(!text.includes("$30.77"), "historical Summary must not use latest cost");
        const layout = await page.evaluate(() => ({ width: innerWidth, scrollWidth: document.documentElement.scrollWidth }));
        assert(layout.scrollWidth <= layout.width + 1, JSON.stringify(layout));
        return text;
      };
      await check();
      await page.reload({ waitUntil: "networkidle" });
      await summary.waitFor({ state: "visible" });
      await check();
      await page.evaluate(() => refresh({ force: true, forceConversation: true }));
      results.push({ width, theme, run, text: await check(), cards: await summary.locator(".summary-outcome-grid .kv").evaluateAll(nodes => nodes.map(el => { const r = el.getBoundingClientRect(); return { x: r.x, y: r.y, width: r.width, height: r.height }; })) });
      if (run === 126 && captureDir) {
        fs.mkdirSync(captureDir, { recursive: true });
        await page.screenshot({ path: path.join(captureDir, `total-cost-${theme}-${width}.png`) });
      }
    }
    await page.getByRole("button", { name: "Next summary" }).focus();
    await page.keyboard.press("Enter");
    await page.waitForFunction(() => document.querySelector("[data-agent-summary-page]")?.innerText.includes("$30.17"));
    assert.deepEqual(errors, []);
    await context.close();
  }
  if (captureDir) fs.writeFileSync(path.join(captureDir, "total-cost-results.json"), JSON.stringify(results, null, 2));
  console.log("usage_scope_smoke: ok (saved cumulative cost, historical 126/127, partial/missing, keyboard, polling, desktop/mobile Dark/Nord Light)");
};
