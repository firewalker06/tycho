const clickFocusAction = require("./focus_menu_actions");
const assert = require("node:assert/strict");

module.exports = async ({ browser, context, page, api, agentKey, save, waitForFocus }) => {
  const viewports = [
    { name: "desktop", width: 1440, height: 900 },
    { name: "mobile", width: 390, height: 844 },
  ];
  const refreshFocus = async sections => {
    await save(sections);
    await page.evaluate(() => refreshAgentFocus(parseRoute().key));
    await page.waitForFunction(title => state.agentFocusSnapshots.get(parseRoute().key)?.data?.sections?.[0]?.title === title, sections[0]?.title || "");
  };
  const openText = async (selector, viewport) => {
    const control = page.locator(selector);
    if (viewport.width < 600) await control.tap();
    else await control.click();
  };

  for (const viewport of viewports) {
    await page.setViewportSize(viewport);
    await refreshFocus([
      { title: "Group A", subtitle: "Original A", items: [{ title: "Task A" }] },
      { title: "Group B", subtitle: "Original B", items: [{ title: "Task B" }] },
    ]);

    let reordered = false;
    await page.route(api, async route => {
      if (!reordered && route.request().method() === "PUT") {
        reordered = true;
        const latest = (await (await context.request.get(api)).json()).focus;
        const response = await context.request.put(api, {
          data: { revision: latest.revision, sections: [...latest.sections].reverse() },
        });
        assert(response.ok(), await response.text());
      }
      await route.continue();
    });
    await openText('[data-focus-edit-group="0"]', viewport);
    let editA = page.locator(`[data-focus-edit-form="${agentKey}"][data-focus-section-index="0"]`);
    await editA.locator('[data-focus-edit-field="title"]').fill("A retained draft");
    await editA.locator('[data-focus-edit-field="subtitle"]').fill("A retained details");
    await editA.locator('[data-focus-edit-field="subtitle"]').press("Enter");
    await waitForFocus(focus => focus.sections[0]?.title === "Group B" && focus.sections[1]?.title === "Group A");
    await page.waitForFunction(key => state.agentFocusEditingEntries.get(key)?.sectionIndex === 1, agentKey);
    await page.unroute(api);

    const retainedForm = page.locator(`[data-focus-edit-form="${agentKey}"]`);
    await retainedForm.waitFor({ state: "visible" });
    assert.equal(await retainedForm.getAttribute("data-focus-section-index"), "1", `${viewport.name}: conflict draft remains bound to Group A after reorder`);
    assert.equal(await retainedForm.locator('[data-focus-edit-field="title"]').inputValue(), "A retained draft");
    await retainedForm.locator('[data-focus-edit-field="subtitle"]').press("Enter");
    const savedA = await waitForFocus(focus => focus.sections[1]?.title === "A retained draft");
    assert.deepEqual(savedA.sections.map(section => section.title), ["Group B", "A retained draft"], `${viewport.name}: retry does not overwrite Group B`);
    await refreshFocus([
      { title: "Switch A", subtitle: "Before click", items: [{ title: "Task A" }] },
      { title: "Switch B", subtitle: "Next editor", items: [{ title: "Task B" }] },
    ]);
    let putCount = 0;
    await page.route(api, async route => {
      if (route.request().method() === "PUT") putCount += 1;
      await route.continue();
    });
    await openText('[data-focus-edit-group="0"]', viewport);
    const departingForm = page.locator(`[data-focus-edit-form="${agentKey}"][data-focus-section-index="0"]`);
    await departingForm.locator('[data-focus-edit-field="title"]').fill("Switch A saved");
    await openText('[data-focus-edit-group="1"]', viewport);
    const nextForm = page.locator(`[data-focus-edit-form="${agentKey}"][data-focus-section-index="1"]`);
    await nextForm.waitFor({ state: "visible" });
    assert.equal(await nextForm.locator('[data-focus-edit-field="title"]').inputValue(), "Switch B", `${viewport.name}: the clicked editor opens immediately`);
    await waitForFocus(focus => focus.sections[0]?.title === "Switch A saved");
    await page.waitForTimeout(80);
    assert.equal(putCount, 1, `${viewport.name}: switching text entries saves the departing draft exactly once`);
    await page.unroute(api);
    await nextForm.locator('[data-focus-edit-field="title"]').press("Escape");

    await refreshFocus([{ title: "Clear A", items: [{ title: "Clear task" }] }]);
    let releaseWrite;
    let startWrite;
    const writeGate = new Promise(resolve => { releaseWrite = resolve; });
    const writeStarted = new Promise(resolve => { startWrite = resolve; });
    let putCountWithClear = 0;
    await page.route(api, async route => {
      if (route.request().method() === "PUT") {
        putCountWithClear += 1;
        if (putCountWithClear === 1) {
          startWrite();
          await writeGate;
        }
      }
      await route.continue();
    });
    await page.locator('[data-focus-toggle-item="0:0"]').check();
    await writeStarted;
    await clickFocusAction(page.locator("[data-focus-clear]"));
    await page.locator("#confirmation-dialog").getByRole("button", { name: "Clear all" }).click();
    assert.equal(await page.locator(".agent-focus-section").count(), 0, `${viewport.name}: confirmed Clear All is immediate`);
    releaseWrite();
    const cleared = await waitForFocus(focus => focus.sections.length === 0);
    assert.equal(cleared.sections.length, 0, `${viewport.name}: Clear All follows the known local write`);
    assert.equal(putCountWithClear, 2, `${viewport.name}: Clear All is sent after the held write`);
    await page.unroute(api);

    await refreshFocus([{ title: "External A", items: [{ title: "External task" }] }]);
    let releaseExternalWrite;
    let startExternalWrite;
    const externalGate = new Promise(resolve => { releaseExternalWrite = resolve; });
    const externalStarted = new Promise(resolve => { startExternalWrite = resolve; });
    let holdExternalWrite = true;
    await page.route(api, async route => {
      if (route.request().method() === "PUT" && holdExternalWrite) {
        holdExternalWrite = false;
        startExternalWrite();
        await externalGate;
      }
      await route.continue();
    });
    await page.locator('[data-focus-toggle-item="0:0"]').check();
    await externalStarted;
    await clickFocusAction(page.locator("[data-focus-clear]"));
    const externalBase = (await (await context.request.get(api)).json()).focus;
    const externalSections = JSON.parse(JSON.stringify(externalBase.sections));
    externalSections[0].title = "External writer changed this";
    const externalResponse = await context.request.put(api, { data: { revision: externalBase.revision, sections: externalSections } });
    assert(externalResponse.ok(), await externalResponse.text());
    releaseExternalWrite();
    await waitForFocus(focus => focus.sections[0]?.title === "External writer changed this");
    await page.locator("#confirmation-dialog").getByRole("button", { name: "Clear all" }).click();
    await page.getByText(/Focus changed/).waitFor();
    const preserved = (await (await context.request.get(api)).json()).focus;
    assert.equal(preserved.sections[0].title, "External writer changed this", `${viewport.name}: Clear All rejects an unseen external change`);
    await page.unroute(api);
  }

  await save([
    { title: "Release work", subtitle: "Active group", icon: "todo_working", items: [
      { title: "First task", subtitle: "Ready", attachments: [] },
      { title: "Second task", subtitle: "Next", attachments: [] },
    ] },
    { title: "Shipped work", icon: "todo_done", completed: true, items: [{ title: "Finished task", completed: true, attachments: [] }] },
  ]);
  await page.evaluate(() => refreshAgentFocus(parseRoute().key));
};
