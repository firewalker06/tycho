const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");

module.exports = async ({ browser, baseUrl, agentKey, captureDir }) => {
  const results = [];
  for (const width of [1440, 390]) for (const theme of ["dark", "light"]) {
    const context = await browser.newContext({ viewport: { width, height: 1000 }, isMobile: width < 500, hasTouch: width < 500 });
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
      const check = async () => {
        const text = await summary.innerText();
        assert(text.includes(`Selected run\n#${run}`), text);
        assert(text.includes("Agent runs now\n127"), text);
        assert(!text.includes("Total Runs"), text);
        if (run === 126) {
          for (const value of ["$0.0579", "$30.17", "505,349", "503,168", "326", "203,236,472", "200,196,608", "407,172", "Complete cost coverage"]) assert(text.includes(value), value + text);
          assert(!text.includes("$30.77") && !text.includes("204,255,421"), text);
        } else if (run === 127) {
          for (const value of ["Partial tracked cost", "$30.77+", "204,255,421", "Unavailable"]) assert(text.includes(value), text);
        } else {
          assert(text.includes("coverage is unavailable") && text.includes("Unavailable"), text);
          assert(!text.includes("$30.77") && !text.includes("203,236,472"), text);
        }
        const layout = await page.evaluate(() => ({ width: innerWidth, scrollWidth: document.documentElement.scrollWidth }));
        assert(layout.scrollWidth <= layout.width + 1, JSON.stringify(layout));
        return text;
      };
      await check();
      await page.reload({ waitUntil: "networkidle" });
      await summary.waitFor({ state: "visible" });
      await check();
      await page.evaluate(() => refresh({ force: true, forceConversation: true }));
      results.push({ width, theme, run, text: await check() });
      const help = page.locator("[data-summary-usage] summary");
      await help.focus();
      await page.keyboard.press("Enter");
      assert(await page.locator("[data-summary-usage] details").getAttribute("open") !== null);
      assert((await summary.innerText()).includes("not invoices, actual charges, or subscription usage"));
      await page.evaluate(() => refresh({ force: true }));
      assert(await page.locator("[data-summary-usage] details").getAttribute("open") !== null);
      await page.locator("[data-summary-usage] summary").press("Enter");
      if (run === 126 && captureDir) {
        fs.mkdirSync(captureDir, { recursive: true });
        await page.screenshot({ path: path.join(captureDir, `usage-scope-${theme}-${width}.png`) });
      }
    }
    // Native keyboard Summary navigation must choose the saved run, not the live count.
    const next = page.getByRole("button", { name: "Next summary" });
    {
      await next.focus();
      await page.keyboard.press("Enter");
      await page.waitForURL(/usage-126/);
      await page.waitForFunction(() => document.querySelector("[data-agent-summary-page]")?.innerText.includes("Selected run\n#126"));
    }
    const edges = await page.evaluate(() => {
      const render = snapshot => renderSummaryUsage({ costSnapshot: snapshot });
      return {
        reset: render({ session_id: "new-session", coverage: "complete", amount_usd: 0.5, run_cost_scope: "run", run_amount_usd: 0.5, token_snapshot: { input_tokens: 10 }, run_tokens: { input_tokens: 10 } }),
        unknown: render({ amount_usd: 8, coverage: "complete" }),
        missing: render({ session_id: "same-session", coverage: "partial", amount_usd: 1.5, run_cost_scope: "run" }),
        event: renderAgentUsageSummaryContent({ kind: "summary", metadata: { event_type: "turn.completed", usage: { input_tokens: 203236472 } } })
      };
    });
    assert(edges.reset.includes("$0.50") && edges.reset.includes("Excludes other sessions"));
    assert(!edges.unknown.includes("Complete cost coverage"));
    assert(edges.missing.includes("Unavailable") && edges.missing.includes("Partial tracked cost"));
    assert(edges.event.includes("Native session token totals through this turn"));
    assert.deepEqual(errors, []);
    await context.close();
  }
  if (captureDir) fs.writeFileSync(path.join(captureDir, "usage-scope-results.json"), JSON.stringify(results, null, 2));
  console.log("usage_scope_smoke: ok (126/127, historical, missing, partial, reset, keyboard, polling, Dark/Nord Light, desktop/mobile)");
};
