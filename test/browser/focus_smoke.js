const assert = require("node:assert/strict");
const fixedSlots = require("./fixed_panel_slots_smoke");
const fs = require("node:fs");
const path = require("node:path");

// Fixed slots supersede fit-based accordion defaults. Keep the Focus-only entry
// point on the same layout assertions, plus late-document and API guards.
module.exports = async options => {
  await fixedSlots(options);
  const { browser, baseUrl, agentKey } = options;
  const context = await browser.newContext({ viewport: { width: 1440, height: 900 } });
  const api = `${baseUrl}/agents/${agentKey}/focus`;
  let revision = (await (await context.request.get(api)).json()).focus.revision;
  const save = async sections => {
    revision = (await (await context.request.get(api)).json()).focus.revision;
    let response = await context.request.put(api, { data: { revision, sections } });
    if (response.status() === 409) {
      revision = (await (await context.request.get(api)).json()).focus.revision;
      response = await context.request.put(api, { data: { revision, sections } });
    }
    assert(response.ok(), await response.text());
    revision = (await response.json()).focus.revision;
  };
  await save([]);
  const page = await context.newPage();
  await page.goto(`${baseUrl}/ui#agent/${agentKey}`, { waitUntil: "networkidle" });
  await page.locator("#prompt-input").waitFor();
  assert.equal(await page.locator("[data-agent-focus]").count(), 0);
  await save([
    { title: "Release work", subtitle: "Active group", icon: "todo_working", items: [
      { title: "First task", subtitle: "Ready", attachments: [] },
      { title: "Second task", subtitle: "Next", attachments: [] },
    ] },
    { title: "Shipped work", icon: "todo_done", completed: true, items: [{ title: "Finished task", completed: true, attachments: [] }] },
  ]);
  await page.evaluate(() => refresh({ force: true }));
  await page.locator('.side-conversation-controls [data-side-conversation="focus"]').click();
  await page.locator("[data-agent-focus]").waitFor({ state: "visible" });
  assert.equal((await page.locator(".agent-focus-completed > h3").innerText()).toLowerCase(), "completed");
  assert.equal(await page.locator('[data-focus-edit-group="1"]').getAttribute("data-focus-agent"), agentKey);
  assert.equal(await page.locator(".agent-focus-section").first().locator("h3").innerText().then(text => text.includes("Release work")), true);
  assert.equal(await page.locator(".agent-focus-completed .agent-focus-section").getAttribute("class").then(value => value.includes("is-completed")), true);
  assert.equal(await page.locator(".agent-focus-completed .agent-focus-section-toggle").getAttribute("aria-expanded"), "false", "completed groups start collapsed");
  const captureDir = process.env.TYCHO_REMOTE_UI_CAPTURE_DIR;
  if (captureDir) {
    fs.mkdirSync(captureDir, { recursive: true });
    await page.screenshot({ path: path.join(captureDir, "focus-desktop.png"), fullPage: true });
  }
  await page.locator(".agent-focus-completed .agent-focus-section-toggle").click();
  assert.equal(await page.locator(".agent-focus-completed .agent-focus-section-toggle").getAttribute("aria-expanded"), "true", "users can expand a completed group");
  await page.locator(".agent-focus-completed .agent-focus-section-toggle").click();
  const promptAnswers = ["Release work edited", "Updated group"];
  page.on("dialog", async dialog => dialog.accept(promptAnswers.shift() || ""));
  await page.locator('[data-focus-edit-group="0"]').click();
  await page.getByText("Release work edited", { exact: true }).waitFor();
  assert.equal(await page.locator(".agent-focus-completed").innerText().then(text => text.includes("Shipped work")), true, "completed groups stay in Completed after an edit");
  await page.locator('[data-focus-toggle-item="0:0"]').check();
  await page.waitForTimeout(150);
  await page.locator('[data-focus-toggle-item="0:1"]').check();
  await page.locator(".agent-focus-completed").getByText("Release work edited", { exact: true }).waitFor();
  assert.equal(await page.locator('.agent-focus-completed [data-focus-section]').last().getAttribute("aria-expanded"), "false", "a fully completed group moves below Completed and collapses");
  await page.locator('[data-focus-complete-group="0"]').click();
  await page.locator(".agent-focus-section").first().getByText("Release work edited", { exact: true }).waitFor();
  const itemAnswers = ["First task edited", "Edited details"];
  page.removeAllListeners("dialog");
  page.on("dialog", async dialog => dialog.accept(itemAnswers.shift() || ""));
  await page.locator('[data-focus-edit-item="0:0"]').click();
  await page.getByText("First task edited", { exact: true }).waitFor();
  // Adding an incomplete task reopens a completed group. Completing it by item
  // returns the group to Completed and collapses it. Recompletion after reopen
  // must also collapse, through both the group and item controls.
  await page.locator('.agent-focus-completed [data-focus-section]').click({ force: true });
  page.removeAllListeners("dialog");
  page.on("dialog", async dialog => dialog.accept("New active task"));
  await page.locator('.agent-focus-completed [data-focus-add-item="1"]').click();
  await page.getByText("New active task", { exact: true }).waitFor();
  assert.equal(await page.locator(".agent-focus-completed").count(), 0, "adding incomplete work returns its group to active work");
  await page.locator('[data-focus-toggle-item="1:1"]').check();
  await page.locator('.agent-focus-completed .agent-focus-section').filter({ hasText: "Shipped work" }).waitFor();
  assert.equal(await page.locator('.agent-focus-completed [data-focus-section]').getAttribute("aria-expanded"), "false", "item completion collapses the group again");
  await page.locator('[data-focus-complete-group="1"]').click();
  await page.locator('.agent-focus-section').filter({ hasText: "Shipped work" }).waitFor();
  await page.locator('[data-focus-complete-group="1"]').click();
  await page.locator('.agent-focus-completed .agent-focus-section').filter({ hasText: "Shipped work" }).waitFor();
  assert.equal(await page.locator('.agent-focus-completed [data-focus-section]').getAttribute("aria-expanded"), "false", "group completion after reopen collapses again");
  await page.locator('.agent-focus-completed [data-focus-section]').click({ force: true });
  assert.equal(await page.locator('.agent-focus-completed [data-focus-section]').getAttribute("aria-expanded"), "true", "users can still expand after automatic collapse");
  // Hold the manual refresh response after Delete captures its document. A
  // concurrent reorder must conflict instead of deleting the new index 0.
  await save([{ title: "Group A", items: [{ title: "Keep A" }] }, { title: "Group B", items: [{ title: "Keep B" }] }]);
  await page.evaluate(() => refresh({ force: true }));
  let releaseRefresh;
  let refreshStarted;
  const started = new Promise(resolve => { refreshStarted = resolve; });
  const heldRefresh = new Promise(resolve => { releaseRefresh = resolve; });
  let holdNextGet = true;
  await page.route(api, async route => {
    if (holdNextGet && route.request().method() === "GET") {
      holdNextGet = false;
      refreshStarted();
      await heldRefresh;
    }
    await route.continue();
  });
  await page.locator(`[data-refresh-focus="${agentKey}"]`).click();
  await started;
  await page.locator('[data-focus-delete-group="0"]').click();
  await page.locator("#confirmation-dialog").getByRole("button", { name: "Delete group" }).waitFor();
  let latest = (await (await context.request.get(api)).json()).focus;
  const reordered = await context.request.put(api, { data: { revision: latest.revision, sections: [{ title: "Group B", items: [{ title: "Keep B" }] }, { title: "Group A", items: [{ title: "Keep A" }] }] } });
  assert(reordered.ok(), await reordered.text());
  releaseRefresh();
  await page.locator("#confirmation-dialog").getByRole("button", { name: "Delete group" }).click();
  await page.getByText("Focus changed elsewhere. The latest version is loaded. Retry your edit.").waitFor();
  latest = (await (await context.request.get(api)).json()).focus;
  assert.deepEqual(latest.sections.map(section => section.title), ["Group B", "Group A"], "delete conflict preserves both reordered groups");
  await page.unroute(api);

  // Clear all must use the same pre-confirmation revision rule.
  await save([{ title: "Old work", items: [{ title: "Keep old work" }] }]);
  await page.evaluate(() => refresh({ force: true }));
  await page.locator("[data-focus-clear]").click();
  latest = (await (await context.request.get(api)).json()).focus;
  const replacement = await context.request.put(api, { data: { revision: latest.revision, sections: [{ title: "New work", items: [{ title: "Keep new work" }] }] } });
  assert(replacement.ok(), await replacement.text());
  await page.locator("#confirmation-dialog").getByRole("button", { name: "Clear all" }).click();
  await page.getByText("Focus changed elsewhere. The latest version is loaded. Retry your edit.").waitFor();
  latest = (await (await context.request.get(api)).json()).focus;
  assert.deepEqual(latest.sections.map(section => section.title), ["New work"], "clear conflict preserves data written after confirmation opened");
  await page.setViewportSize({ width: 1440, height: 900 });
  // Restore the original fixture after the stale-write cases.
  await save([
    { title: "Release work edited", subtitle: "Updated group", icon: "todo_working", items: [
      { title: "First task edited", subtitle: "Edited details", attachments: [] },
      { title: "Second task", subtitle: "Next", attachments: [] },
    ] },
    { title: "Shipped work", icon: "todo_done", completed: true, items: [{ title: "Finished task", completed: true, attachments: [] }] },
  ]);
  await page.evaluate(() => refresh({ force: true }));
  await page.setViewportSize({ width: 390, height: 844 });
  await page.evaluate(() => refresh({ force: true }));
  await page.locator("[data-agent-focus]").waitFor({ state: "visible" });
  if (captureDir) await page.screenshot({ path: path.join(captureDir, "focus-mobile.png"), fullPage: true });
  assert.equal(await page.locator("[data-agent-focus]").evaluate(element => element.scrollWidth <= element.clientWidth), true, "mobile Focus must not overflow horizontally");
  page.on("dialog", async dialog => dialog.accept());
  await page.locator('[data-focus-delete-group="1"]').click();
  await page.getByRole("button", { name: "Delete group" }).click();
  await page.locator(".agent-focus-completed").waitFor({ state: "detached" });
  await page.locator("[data-focus-clear]").click();
  await page.locator("#confirmation-dialog").getByRole("button", { name: "Clear all" }).click();
  await page.waitForFunction(async api => (await (await fetch(api)).json()).focus.sections.length === 0, api);
  revision = (await (await context.request.get(api)).json()).focus.revision;
  const unsafe = await context.request.put(api, { data: { revision, sections: [{ title: "Unsafe", items: [{ title: "Bad", attachments: [{ type: "link", title: "Bad", url: "javascript:alert(1)" }] }] }] } });
  assert.equal(unsafe.status(), 422);
  assert.equal((await context.request.put(api, { data: { revision: 0, sections: [] } })).status(), 409);

  await save([]);
  await page.evaluate(() => refresh({ force: true }));
  assert.equal(await page.locator("[data-agent-focus]").count(), 0);
  await context.close();
};
