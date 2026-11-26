const assert = require("node:assert/strict");

module.exports = async ({ context, page, api, agentKey, save, waitForFocus }) => {
  const viewports = [
    { name: "desktop", width: 1440, height: 900 },
    { name: "mobile", width: 390, height: 844 },
  ];
  const openText = async (selector, viewport) => {
    const control = page.locator(selector);
    if (viewport.width < 600) await control.tap();
    else await control.click();
  };

  for (const viewport of viewports) {
    await page.setViewportSize(viewport);
    await save([
      { title: "Notes", items: [{ title: "Original A" }] },
      { title: "Notes", items: [{ title: "Survivor B" }] },
    ]);
    await page.evaluate(() => refreshAgentFocus(parseRoute().key));

    let releaseConflict;
    let startConflict;
    const conflictGate = new Promise(resolve => { releaseConflict = resolve; });
    const conflictStarted = new Promise(resolve => { startConflict = resolve; });
    let heldConflict = false;
    await page.route(api, async route => {
      if (route.request().method() === "PUT" && !heldConflict) {
        heldConflict = true;
        startConflict();
        await conflictGate;
      }
      await route.continue();
    });
    await openText('[data-focus-edit-group="0"]', viewport);
    let editor = page.locator(`[data-focus-edit-form="${agentKey}"][data-focus-section-index="0"]`);
    await editor.locator('[data-focus-edit-field="title"]').fill("A draft");
    await editor.locator('[data-focus-edit-field="title"]').press("Enter");
    await conflictStarted;
    const remote = (await (await context.request.get(api)).json()).focus;
    const survivor = JSON.parse(JSON.stringify(remote.sections[1]));
    const removeOriginal = await context.request.put(api, {
      data: { revision: remote.revision, sections: [survivor] },
    });
    assert(removeOriginal.ok(), await removeOriginal.text());
    releaseConflict();
    await page.getByText(/Focus changed elsewhere/).waitFor();
    const afterConflict = (await (await context.request.get(api)).json()).focus;
    assert.deepEqual(afterConflict.sections.map(section => section.title), ["Notes"], `${viewport.name}: conflict replay does not rename the surviving duplicate`);
    assert.deepEqual(afterConflict.sections[0].items.map(item => item.title), ["Survivor B"], `${viewport.name}: the surviving duplicate remains unchanged`);
    editor = page.locator(`[data-focus-edit-form="${agentKey}"]`);
    assert.equal(await editor.locator('[data-focus-edit-field="title"]').inputValue(), "A draft", `${viewport.name}: the rejected draft remains visible`);
    await page.unroute(api);
    await editor.locator('[data-focus-edit-field="title"]').press("Escape");

    await save([{ title: "Before", items: [{ title: "Task" }] }]);
    await page.evaluate(() => refreshAgentFocus(parseRoute().key));
    const startingRevision = (await (await context.request.get(api)).json()).focus.revision;
    let releaseFirst;
    let startFirst;
    const firstGate = new Promise(resolve => { releaseFirst = resolve; });
    const firstStarted = new Promise(resolve => { startFirst = resolve; });
    let putCount = 0;
    await page.route(api, async route => {
      if (route.request().method() === "PUT") {
        putCount += 1;
        if (putCount === 1) {
          startFirst();
          await firstGate;
        }
      }
      await route.continue();
    });
    await openText('[data-focus-edit-group="0"]', viewport);
    editor = page.locator(`[data-focus-edit-form="${agentKey}"][data-focus-section-index="0"]`);
    const title = editor.locator('[data-focus-edit-field="title"]');
    await title.fill("First local rename");
    await title.press("Enter");
    await firstStarted;
    editor = page.locator(`[data-focus-edit-form="${agentKey}"]`);
    const latestTitle = editor.locator('[data-focus-edit-field="title"]');
    await latestTitle.fill("Latest local draft");
    await latestTitle.press("Enter");
    await page.waitForFunction(key => state.agentFocusEditingEntries.get(key)?.generation >= 2, agentKey);
    releaseFirst();
    const accepted = await waitForFocus(focus => focus.sections[0]?.title === "Latest local draft");
    await page.waitForFunction(key => !state.agentFocusWriteQueues.has(key), agentKey);
    assert.equal(accepted.revision, startingRevision + 2, `${viewport.name}: each queued rename uses the accepted revision`);
    assert.equal(putCount, 2, `${viewport.name}: rapid saves send both ordered writes`);
    assert.equal(await page.locator(`[data-focus-edit-form="${agentKey}"]`).count(), 0, `${viewport.name}: latest accepted save closes the editor`);
    await page.unroute(api);
  }
  await page.setViewportSize({ width: 1440, height: 900 });
  await save([
    { title: "Release work", subtitle: "Active group", icon: "todo_working", items: [
      { title: "First task", subtitle: "Ready", attachments: [] },
      { title: "Second task", subtitle: "Next", attachments: [] },
    ] },
    { title: "Shipped work", icon: "todo_done", completed: true, items: [{ title: "Finished task", completed: true, attachments: [] }] },
  ]);
  await page.evaluate(() => refreshAgentFocus(parseRoute().key));
};
