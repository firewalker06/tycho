const assert = require("node:assert/strict");

module.exports = async ({ page, api, agentKey, save, waitForFocus }) => {
  for (const viewport of [{ width: 1440, height: 900 }, { width: 390, height: 844 }]) {
    await page.setViewportSize(viewport);
    await save([{ title: "Notes", completed: true, items: [{ title: "Same task", completed: true }] }, { title: "Notes", completed: true, items: [{ title: "Same task", completed: true }] }]);
    await page.evaluate(() => refreshAgentFocus(parseRoute().key));
    const first = page.locator(".agent-focus-completed [data-focus-section]").first();
    await first.click();
    await page.locator('[data-focus-complete-group="0"]').click();
    await waitForFocus(focus => focus.sections[0]?.completed !== true);
    await page.locator('[data-focus-complete-group="0"]').click();
    await waitForFocus(focus => focus.sections[0]?.completed === true);
    assert.equal(await first.getAttribute("aria-expanded"), "false", "duplicate recompletion collapses the selected group");

    await save([{ title: "Notes", items: [{ title: "Original A" }] }, { title: "Notes", items: [{ title: "Survivor B" }] }]);
    await page.evaluate(() => refreshAgentFocus(parseRoute().key));
    await page.locator('[data-focus-edit-item="0:0"]').click();
    const form = page.locator(`[data-focus-edit-form="${agentKey}"][data-focus-item-index="0"]`);
    const title = form.locator('[data-focus-edit-field="title"]');
    let release;
    const gate = new Promise(resolve => { release = resolve; });
    let started;
    const startedWrite = new Promise(resolve => { started = resolve; });
    let puts = 0;
    await page.route(api, async route => {
      if (route.request().method() === "PUT" && ++puts === 1) { started(); await gate; }
      await route.continue();
    });
    await title.fill("First saved");
    await title.press("Enter");
    await startedWrite;
    await title.fill("Newer draft");
    release();
    await page.waitForFunction(key => state.agentFocusEditingEntries.get(key)?.identity.section.revision >= 2, agentKey);
    await title.press("Enter");
    await waitForFocus(focus => focus.sections[0]?.items[0]?.title === "Newer draft");
    assert.equal(puts, 2, "newer duplicate-item draft sends a follow-up write");
    await page.unroute(api);
  }
  await page.setViewportSize({ width: 1440, height: 900 });
  await save([{ title: "Release work", subtitle: "Active group", icon: "todo_working", items: [{ title: "First task", subtitle: "Ready" }, { title: "Second task", subtitle: "Next" }] }, { title: "Shipped work", icon: "todo_done", completed: true, items: [{ title: "Finished task", completed: true }] }]);
  await page.evaluate(() => refreshAgentFocus(parseRoute().key));
};
