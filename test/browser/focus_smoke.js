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
  const waitForFocusState = async (sectionIndex, completed) => {
    const deadline = Date.now() + 10_000;
    let focus;
    while (Date.now() < deadline) {
      focus = (await (await context.request.get(api)).json()).focus;
      const section = focus.sections[sectionIndex];
      if (section && (section.completed === true) === completed) return focus;
      await new Promise(resolve => setTimeout(resolve, 50));
    }
    assert.fail(`Focus section ${sectionIndex} did not reach completed=${completed}; latest=${JSON.stringify(focus?.sections?.[sectionIndex])}`);
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
  await page.evaluate(() => refreshAgentFocus(parseRoute().key));
  await page.evaluate(() => refresh({ force: true }));
  await page.locator('.side-conversation-controls [data-side-conversation="focus"]').click();
  await page.locator("[data-agent-focus]").waitFor({ state: "visible" });
  assert.equal((await page.locator(".agent-focus-completed > h3").innerText()).toLowerCase(), "completed");
  assert.equal(await page.locator('[data-focus-edit-group="1"]').getAttribute("data-focus-agent"), agentKey);
  const actionChecks = await page.locator(".agent-focus-panel button.agent-focus-action").evaluateAll(buttons => buttons.filter(button => button.getClientRects().length > 0).map(button => {
    const style = getComputedStyle(button);
    const rect = button.getBoundingClientRect();
    return {
      name: button.getAttribute("aria-label"),
      title: button.getAttribute("title"),
      iconOnly: [...button.children].every(child => child.matches("svg")),
      borderWidth: style.borderTopWidth,
      background: style.backgroundColor,
      width: rect.width,
      height: rect.height,
    };
  }));
  assert(actionChecks.length >= 8, "Focus actions render as icon controls");
  for (const action of actionChecks) {
    assert(action.name && action.title, "each icon action has an accessible name and tooltip");
    assert.equal(action.iconOnly, true, "action buttons show icons without text");
    assert.equal(action.borderWidth, "0px", "action buttons have no border");
    assert.equal(action.background, "rgba(0, 0, 0, 0)", "action buttons have no background");
    assert(action.width >= 44 && action.height >= 44, "action buttons have a 44px touch target");
  }
  assert.equal(await page.locator(".agent-focus-section").first().locator("h3").innerText().then(text => text.includes("Release work")), true);
  assert.equal(await page.locator(".agent-focus-completed .agent-focus-section").getAttribute("class").then(value => value.includes("is-completed")), true);
  assert.equal(await page.locator(".agent-focus-completed .agent-focus-section-toggle").getAttribute("aria-expanded"), "false", "completed groups start collapsed");
  const captureDir = process.env.TYCHO_REMOTE_UI_CAPTURE_DIR;
  if (captureDir) {
    fs.mkdirSync(captureDir, { recursive: true });
    await page.screenshot({ path: path.join(captureDir, "focus-desktop.png"), fullPage: true });
    await page.screenshot({ path: path.join(captureDir, "focus-desktop-initial.png"), fullPage: true });
    await page.setViewportSize({ width: 390, height: 844 });
    await page.evaluate(() => refresh({ force: true }));
    await page.screenshot({ path: path.join(captureDir, "focus-mobile.png"), fullPage: true });
    await page.screenshot({ path: path.join(captureDir, "focus-mobile-initial.png"), fullPage: true });
    await page.setViewportSize({ width: 1440, height: 900 });
    await page.evaluate(() => refresh({ force: true }));
  }
  await page.locator(".agent-focus-completed .agent-focus-section-toggle").click();
  assert.equal(await page.locator(".agent-focus-completed .agent-focus-section-toggle").getAttribute("aria-expanded"), "true", "users can expand a completed group");
  await page.locator(".agent-focus-completed .agent-focus-section-toggle").click();
  const beforeInlineConflict = (await (await context.request.get(api)).json()).focus;
  await page.locator('[data-focus-edit-group="0"]').click();
  const conflictedEdit = page.locator(`[data-focus-edit-form="${agentKey}"][data-focus-item-index=""]`);
  await conflictedEdit.waitFor();
  const concurrentSections = JSON.parse(JSON.stringify(beforeInlineConflict.sections));
  concurrentSections[1].title = "Concurrent shipped";
  const concurrentWrite = await context.request.put(api, { data: { revision: beforeInlineConflict.revision, sections: concurrentSections } });
  assert(concurrentWrite.ok(), await concurrentWrite.text());
  await conflictedEdit.locator('[data-focus-edit-field="title"]').fill("Stale group edit");
  await conflictedEdit.locator('[data-focus-edit-field="title"]').press("Enter");
  await page.getByText("Focus changed elsewhere. The latest version is loaded. Retry your edit.").waitFor();
  let afterInlineConflict = (await (await context.request.get(api)).json()).focus;
  assert.deepEqual(afterInlineConflict.sections.map(section => section.title), ["Release work", "Concurrent shipped"], "inline edit conflict preserves the concurrent document");
  assert.equal(await conflictedEdit.locator('[data-focus-edit-field="title"]').inputValue(), "Stale group edit", "failed stale edit keeps its draft for retry");
  await conflictedEdit.locator('[data-focus-edit-field="title"]').press("Escape");
  const groupEditButton = page.locator('[data-focus-edit-group="0"]');
  await groupEditButton.focus();
  await page.keyboard.press("Enter");
  const groupForm = page.locator(`[data-focus-edit-form="${agentKey}"][data-focus-item-index=""]`);
  await groupForm.waitFor();
  assert.equal(await groupForm.locator("input[type=text]").count(), 2, "group edit uses two ordinary single-line inputs");
  assert.equal(await groupForm.locator("textarea").count(), 0, "group edit has no textarea");
  assert.equal(await page.evaluate(() => document.activeElement?.matches("[data-focus-edit-title]")), true, "keyboard edit moves focus to the title input");
  await groupForm.locator('[data-focus-edit-field="title"]').fill("Release work edited");
  await groupForm.locator('[data-focus-edit-field="subtitle"]').fill("Updated group");
  await groupForm.getByRole("button", { name: "Save group" }).click();
  await page.getByText("Release work edited", { exact: true }).waitFor();
  await page.locator('[data-focus-edit-group="0"]').waitFor();
  assert.equal(await page.evaluate(() => document.activeElement?.matches('[data-focus-edit-group="0"]')), true, "saving restores focus to the Edit action");
  assert.equal(await page.locator(".agent-focus-completed").innerText().then(text => text.includes("Concurrent shipped")), true, "completed groups stay in Completed after an edit");
  const editedGroupActive = page.locator('.agent-focus-section').filter({ hasText: "Release work edited" });
  await editedGroupActive.locator('[data-focus-toggle-item]').nth(0).check();
  await page.waitForTimeout(150);
  await editedGroupActive.locator('[data-focus-toggle-item]').nth(1).check();
  await page.locator(".agent-focus-completed").getByText("Release work edited", { exact: true }).waitFor();
  assert.equal(await page.locator('.agent-focus-completed [data-focus-section]').last().getAttribute("aria-expanded"), "false", "a fully completed group moves below Completed and collapses");
  await page.locator('[data-focus-complete-group="0"]').click();
  await page.locator(".agent-focus-section").first().getByText("Release work edited", { exact: true }).waitFor();
  await page.locator('.agent-focus-section').filter({ hasText: "Release work edited" }).locator('[data-focus-edit-item]').first().click();
  const itemEditForm = page.locator(`[data-focus-edit-form="${agentKey}"][data-focus-item-index="0"]`);
  await itemEditForm.waitFor();
  assert.equal(await itemEditForm.locator("input[type=text]").count(), 2, "item edit uses two ordinary single-line inputs");
  assert.equal(await itemEditForm.locator("textarea").count(), 0, "item edit has no textarea");
  await itemEditForm.locator('[data-focus-edit-field="title"]').fill("Discarded task title");
  await itemEditForm.locator('[data-focus-edit-field="subtitle"]').press("Escape");
  await page.getByText("First task", { exact: true }).waitFor();
  assert.equal(await page.locator(`[data-focus-edit-form="${agentKey}"]`).count(), 0, "Escape cancels inline editing");
  await page.locator('.agent-focus-section').filter({ hasText: "Release work edited" }).locator('[data-focus-edit-item]').first().click();
  const finalItemEditForm = page.locator(`[data-focus-edit-form="${agentKey}"][data-focus-item-index="0"]`);
  await finalItemEditForm.waitFor();
  await finalItemEditForm.locator('[data-focus-edit-field="title"]').fill("First task edited");
  await finalItemEditForm.locator('[data-focus-edit-field="subtitle"]').fill("Edited details");
  await finalItemEditForm.getByRole("button", { name: "Save item" }).click();
  await page.getByText("First task edited", { exact: true }).waitFor();
  // Adding an incomplete task reopens a completed group. Completing it by item
  // returns the group to Completed and collapses it. Recompletion after reopen
  // must also collapse, through both the group and item controls.
  const reopenedGroup = page.locator('.agent-focus-completed .agent-focus-section').first();
  await reopenedGroup.locator('[data-focus-section]').click({ force: true });
  await reopenedGroup.locator('[data-focus-add-item]').waitFor();
  page.on("dialog", async dialog => dialog.accept("New active task"));
  const reopenedGroupIndex = Number(await reopenedGroup.locator('[data-focus-add-item]').getAttribute("data-focus-add-item"));
  await reopenedGroup.locator('[data-focus-add-item]').click();
  await page.getByText("New active task", { exact: true }).waitFor();
  assert.equal(await page.locator(".agent-focus-completed").count(), 0, "adding incomplete work returns its group to active work");
  const addedItem = page.locator(`[data-focus-toggle-item="${reopenedGroupIndex}:1"]`);
  await addedItem.waitFor();
  await waitForFocusState(reopenedGroupIndex, false);
  await addedItem.check();
  await waitForFocusState(reopenedGroupIndex, true);
  const reopenedCompleteAction = page.locator(`[data-focus-complete-group="${reopenedGroupIndex}"]`);
  await page.locator('.agent-focus-completed').waitFor();
  assert.equal(await page.locator('.agent-focus-completed').locator(`[data-focus-complete-group="${reopenedGroupIndex}"]`).count(), 1, "item completion returns the group to Completed");
  const reopenedDisclosure = page.locator(`.agent-focus-completed [data-focus-section]`);
  assert.equal(await reopenedDisclosure.getAttribute("aria-expanded"), "false", "item completion collapses the group again");
  await reopenedDisclosure.click({ force: true });
  assert.equal(await reopenedDisclosure.getAttribute("aria-expanded"), "true", "users can still expand after automatic collapse");
  await reopenedCompleteAction.click();
  await waitForFocusState(reopenedGroupIndex, false);
  await reopenedCompleteAction.click();
  await waitForFocusState(reopenedGroupIndex, true);
  await page.locator('.agent-focus-completed').waitFor();
  assert.equal(await page.locator('.agent-focus-completed [data-focus-section]').getAttribute("aria-expanded"), "false", "group completion after reopen collapses again");
  const assertFocusedInsideFocusScroll = async () => page.evaluate(() => {
    const focus = document.querySelector("[data-agent-focus]");
    const scroll = focus?.querySelector(".agent-focus-scroll");
    const active = document.activeElement;
    if (!focus || !scroll || !active || !focus.contains(active)) return false;
    const viewport = scroll.getBoundingClientRect();
    const target = active.getBoundingClientRect();
    return scroll.scrollTop > 0 && target.top >= viewport.top && target.bottom <= viewport.bottom;
  });

  // Late success and failure for group A must preserve a newer group B draft and focus.
  for (const viewport of [{ width: 1440, height: 900 }, { width: 390, height: 844 }]) {
    await page.setViewportSize(viewport);
    await save([{ title: "Group A", items: [{ title: "Task A" }] }, { title: "Group B", items: [{ title: "Task B" }] }]);
    await page.evaluate(() => refreshAgentFocus(parseRoute().key));
    await page.evaluate(() => refresh({ force: true }));

    let releaseSave;
    let startSave;
    const saveGate = new Promise(resolve => { releaseSave = resolve; });
    const saveStarted = new Promise(resolve => { startSave = resolve; });
    await page.route(api, async route => {
      if (route.request().method() === "PUT") {
        startSave();
        await saveGate;
      }
      await route.continue();
    });
    await page.locator('[data-focus-edit-group="0"]').click();
    const editA = page.locator(`[data-focus-edit-form="${agentKey}"][data-focus-section-index="0"]`);
    await editA.locator('[data-focus-edit-field="title"]').fill("Group A saved");
    await editA.getByRole("button", { name: "Save group" }).click();
    await saveStarted;
    await page.locator('[data-focus-edit-group="1"]').click();
    const editB = page.locator(`[data-focus-edit-form="${agentKey}"][data-focus-section-index="1"]`);
    await editB.locator('[data-focus-edit-field="title"]').fill("Group B newer draft");
    await editB.locator('[data-focus-edit-field="subtitle"]').fill("Keep this draft and focus");
    await editB.locator('[data-focus-edit-field="subtitle"]').focus();
    releaseSave();
    await page.waitForFunction(async api => (await (await fetch(api)).json()).focus.sections[0]?.title === "Group A saved", api);
    await page.waitForFunction(({ agentKey }) => {
      const form = document.querySelector(`[data-focus-edit-form="${agentKey}"][data-focus-section-index="1"]`);
      return form && document.activeElement === form.querySelector('[data-focus-edit-field="subtitle"]');
    }, { agentKey });
    await editB.waitFor();
    assert.equal(await editB.locator('[data-focus-edit-field="title"]').inputValue(), "Group B newer draft");
    assert.equal(await editB.locator('[data-focus-edit-field="subtitle"]').inputValue(), "Keep this draft and focus");
    assert.equal(await page.evaluate(({ agentKey }) => {
      const active = document.activeElement;
      const form = active?.closest(`[data-focus-edit-form="${agentKey}"]`);
      return active?.dataset.focusEditField === "subtitle" && form?.dataset.focusSectionIndex === "1";
    }, { agentKey }), true, "late success preserves newer editor focus");
    await page.unroute(api);

    await save([{ title: "Same editor", subtitle: "Original", items: [{ title: "Task" }] }]);
    await page.evaluate(() => refreshAgentFocus(parseRoute().key));
    await page.evaluate(() => refresh({ force: true }));
    let releaseSameEditorSave;
    let startSameEditorSave;
    const sameEditorSaveGate = new Promise(resolve => { releaseSameEditorSave = resolve; });
    const sameEditorSaveStarted = new Promise(resolve => { startSameEditorSave = resolve; });
    let holdFirstSameEditorPut = true;
    let retryRevision = null;
    await page.route(api, async route => {
      if (route.request().method() === "PUT" && holdFirstSameEditorPut) {
        holdFirstSameEditorPut = false;
        startSameEditorSave();
        await sameEditorSaveGate;
        await route.continue();
      } else {
        if (route.request().method() === "PUT") retryRevision = route.request().postDataJSON().revision;
        await route.continue();
      }
    });
    await page.locator('[data-focus-edit-group="0"]').click();
    const sameEditor = page.locator(`[data-focus-edit-form="${agentKey}"][data-focus-section-index="0"]`);
    await sameEditor.locator('[data-focus-edit-field="title"]').fill("Submitted title");
    await sameEditor.locator('[data-focus-edit-field="subtitle"]').fill("Submitted details");
    await sameEditor.getByRole("button", { name: "Save group" }).click();
    await sameEditorSaveStarted;
    await sameEditor.locator('[data-focus-edit-field="title"]').fill("Newer title while saving");
    await sameEditor.locator('[data-focus-edit-field="subtitle"]').fill("Newer details while saving");
    await sameEditor.locator('[data-focus-edit-field="subtitle"]').focus();
    releaseSameEditorSave();
    await page.waitForFunction(({ api }) => {
      const focus = state.agentFocusSnapshots.get(parseRoute().key)?.data;
      return focus?.sections?.[0]?.title === "Submitted title";
    }, { api });
    await sameEditor.waitFor();
    assert.equal(await sameEditor.locator('[data-focus-edit-field="title"]').inputValue(), "Newer title while saving");
    assert.equal(await sameEditor.locator('[data-focus-edit-field="subtitle"]').inputValue(), "Newer details while saving");
    assert.equal(await page.evaluate(() => document.activeElement?.dataset.focusEditField), "subtitle", "late success keeps focus in the newer same-editor draft");
    const acceptedRevision = (await (await context.request.get(api)).json()).focus.revision;
    await sameEditor.getByRole("button", { name: "Save group" }).click();
    await page.waitForFunction(() => state.agentFocusSnapshots.get(parseRoute().key)?.data?.sections?.[0]?.title === "Newer title while saving");
    const afterRetry = (await (await context.request.get(api)).json()).focus;
    assert.equal(afterRetry.sections[0].title, "Newer title while saving", "the retained same-editor draft can be saved");
    assert.equal(afterRetry.sections[0].subtitle, "Newer details while saving");
    assert.equal(retryRevision, acceptedRevision, "the next save uses the revision accepted by the late reply");
    await page.unroute(api);

    await save([{ title: "Group A", items: [{ title: "Task A" }] }, { title: "Group B", items: [{ title: "Task B" }] }]);
    await page.evaluate(() => refreshAgentFocus(parseRoute().key));
    await page.evaluate(() => refresh({ force: true }));
    let releaseFailure;
    let startFailure;
    const failureGate = new Promise(resolve => { releaseFailure = resolve; });
    const failureStarted = new Promise(resolve => { startFailure = resolve; });
    await page.route(api, async route => {
      if (route.request().method() === "PUT") {
        startFailure();
        await failureGate;
        await route.fulfill({ status: 500, contentType: "application/json", body: JSON.stringify({ error: "Synthetic save failure" }) });
      } else await route.continue();
    });
    await page.locator('[data-focus-edit-group="0"]').click();
    const failedEditA = page.locator(`[data-focus-edit-form="${agentKey}"][data-focus-section-index="0"]`);
    await failedEditA.locator('[data-focus-edit-field="title"]').fill("Group A failed save");
    await failedEditA.getByRole("button", { name: "Save group" }).click();
    await failureStarted;
    await page.locator('[data-focus-edit-group="1"]').click();
    const failedEditB = page.locator(`[data-focus-edit-form="${agentKey}"][data-focus-section-index="1"]`);
    await failedEditB.locator('[data-focus-edit-field="title"]').fill("Group B failed-save draft");
    await failedEditB.locator('[data-focus-edit-field="subtitle"]').fill("Keep after failure");
    await failedEditB.locator('[data-focus-edit-field="subtitle"]').focus();
    releaseFailure();
    await page.getByText("Could not save Focus: Synthetic save failure").waitFor();
    await failedEditB.waitFor();
    assert.equal(await failedEditB.locator('[data-focus-edit-field="title"]').inputValue(), "Group B failed-save draft");
    assert.equal(await failedEditB.locator('[data-focus-edit-field="subtitle"]').inputValue(), "Keep after failure");
    assert.equal(await page.evaluate(({ agentKey }) => {
      const active = document.activeElement;
      const form = active?.closest(`[data-focus-edit-form="${agentKey}"]`);
      return active?.dataset.focusEditField === "subtitle" && form?.dataset.focusSectionIndex === "1";
    }, { agentKey }), true, "late failure preserves newer editor focus");
    await page.unroute(api);
  }

  // Edit, cancel, and save a lower item at both widths. Keep the edit inside the panel viewport.
  const longItems = Array.from({ length: 35 }, (_, index) => ({ title: `Long task ${index + 1}`, subtitle: "Long-list item", attachments: [] }));
  for (const viewport of [{ width: 1440, height: 900 }, { width: 390, height: 844 }]) {
    await page.setViewportSize(viewport);
    await save([{ title: "Long list", items: longItems }]);
    await page.evaluate(() => refreshAgentFocus(parseRoute().key));
    await page.evaluate(() => refresh({ force: true }));
    await page.locator(".agent-focus-scroll").evaluate(element => { element.scrollTop = element.scrollHeight; });
    await page.locator('[data-focus-edit-item="0:34"]').click();
    const lowerForm = page.locator(`[data-focus-edit-form="${agentKey}"][data-focus-item-index="34"]`);
    await lowerForm.waitFor();
    assert.equal(await assertFocusedInsideFocusScroll(), true, "starting a lower edit keeps its focused input visible");
    await lowerForm.locator('[data-focus-edit-field="title"]').press("Escape");
    await page.locator('[data-focus-edit-item="0:34"]').waitFor();
    assert.equal(await assertFocusedInsideFocusScroll(), true, "cancel keeps the lower edit control visible");
    await page.locator('[data-focus-edit-item="0:34"]').click();
    const lowerSaveForm = page.locator(`[data-focus-edit-form="${agentKey}"][data-focus-item-index="34"]`);
    await lowerSaveForm.locator('[data-focus-edit-field="title"]').fill("Long task 35 saved");
    await lowerSaveForm.getByRole("button", { name: "Save item" }).click();
    await page.getByText("Long task 35 saved", { exact: true }).waitFor();
    assert.equal(await assertFocusedInsideFocusScroll(), true, "save keeps the lower edit action visible");
  }
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
  assert.equal(await page.locator("[data-agent-focus]").evaluate(element => element.scrollWidth <= element.clientWidth), true, "mobile Focus must not overflow horizontally");
  const mobileActions = await page.locator(".agent-focus-panel button.agent-focus-action").evaluateAll(buttons => buttons.filter(button => button.getClientRects().length > 0).map(button => {
    const rect = button.getBoundingClientRect();
    return { width: rect.width, height: rect.height, background: getComputedStyle(button).backgroundColor };
  }));
  assert(mobileActions.length > 0 && mobileActions.every(button => button.width >= 44 && button.height >= 44 && button.background === "rgba(0, 0, 0, 0)"), "mobile icon actions keep transparent 44px touch targets");
  page.on("dialog", async dialog => dialog.accept());
  await page.locator('[data-focus-delete-group="1"]').click();
  await page.locator("#confirmation-dialog").getByRole("button", { name: "Delete group" }).click();
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
