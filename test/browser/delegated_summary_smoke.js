const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");

module.exports = async ({ browser, baseUrl, agentKey, captureDir }) => {
  const errors = [];
  const results = [];
  const before = (await (await fetch(`${baseUrl}/agents/${agentKey}/conversation`)).json()).conversation;
  const summary = before.find(block => block.kind === "run_summary" && block.metadata.run_id === "delegated-run");
  assert(summary, "Persisted run Summary missing");
  const summaryId = summary.metadata.summary_id;
  for (const viewport of [{ width: 1440, height: 1000 }, { width: 390, height: 844 }]) {
    const context = await browser.newContext({ viewport });
    const page = await context.newPage();
    page.on("pageerror", error => errors.push(error.message));
    await page.goto(`${baseUrl}/ui#agent/${agentKey}`, { waitUntil: "networkidle" });
    const card = page.locator(".message.run_summary").filter({ hasText: "Created" });
    await card.waitFor({ state: "visible" });
    assert.equal(await card.locator(".summary-delegated-actions li").count(), 4);
    const actions = card.locator(".summary-delegated-actions");
    const check = async (actions) => {
      assert.equal(await actions.locator("li").count(), 4);
      const text = await actions.innerText();
      for (const label of ["Created", "Started", "Message queued", "Message sent", "API contract review", "Removed review"]) assert(text.includes(label), label);
      assert(!text.includes("PRIVATE_PROMPT_SENTINEL"));
      assert.equal(await actions.locator('a[href="#agent/web-agent-api-review"]').count(), 3);
      assert.equal(await actions.locator(".unavailable").count(), 1);
      const overflow = await page.evaluate(() => document.documentElement.scrollWidth > innerWidth + 1);
      assert(!overflow, `Overflow at ${viewport.width}`);
    };
    await check(actions);
    await card.evaluate(element => element.scrollIntoView({ block: "center" }));
    if (captureDir) await page.screenshot({ path: path.join(captureDir, `delegated-summary-conversation-${viewport.width}.png`) });
    await card.getByRole("button", { name: "Open full summary" }).click();
    const detail = page.locator("[data-agent-summary-page]");
    await detail.waitFor({ state: "visible" });
    await check(detail.locator(".summary-delegated-actions"));
    assert((await detail.innerText()).includes("The API review is complete."), "Rich Summary body missing");
    await page.reload({ waitUntil: "networkidle" });
    await detail.waitFor({ state: "visible" });
    await check(detail.locator(".summary-delegated-actions"));
    await page.evaluate(async () => { await refresh({ force: true }); });
    await check(detail.locator(".summary-delegated-actions"));
    if (captureDir) await page.screenshot({ path: path.join(captureDir, `delegated-summary-detail-${viewport.width}.png`) });
    for (const runId of ["empty-run", "legacy"]) {
      const other = before.find(block => block.kind === "run_summary" && block.metadata.run_id === runId);
      await page.goto(`${baseUrl}/ui#agent/${agentKey}/summary/${encodeURIComponent(other.metadata.summary_id)}`, { waitUntil: "networkidle" });
      await page.waitForFunction((id) => {
        const agent = findAgent(parseRoute().key);
        return agent && agentSummaryDetail(agent, id).id === id;
      }, other.metadata.summary_id);
      assert.equal(await page.locator("[data-agent-summary-page] .summary-delegated-actions").count(), 0, `${runId} inherited actions`);
    }
    results.push({ width: viewport.width, actions: 4, coldReload: true, polling: true, runIsolation: true, legacy: true, missingTarget: true });
    await context.close();
  }
  const after = (await (await fetch(`${baseUrl}/agents/${agentKey}/conversation`)).json()).conversation;
  assert.deepEqual(after.filter(block => block.kind === "run_summary"), before.filter(block => block.kind === "run_summary"), "Summary reads changed persisted data");
  assert.deepEqual(errors, []);
  if (captureDir) fs.writeFileSync(path.join(captureDir, "delegated-summary-results.json"), JSON.stringify(results, null, 2));
  console.log(`delegated-summary-smoke: ${JSON.stringify(results)}`);
};
