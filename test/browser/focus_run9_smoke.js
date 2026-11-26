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
      { title: "Notes", items: [] },
      { title: "Notes", items: [] },
    ]);
    await page.evaluate(() => refreshAgentFocus(parseRoute().key));
    await openText('[data-focus-edit-group="1"]', viewport);
    let form = page.locator(`[data-focus-edit-form="${agentKey}"][data-focus-section-index="1"][data-focus-item-index=""]`);
    await form.waitFor({ state: "visible" });
    await form.locator('[data-focus-edit-field="title"]').fill("Second Notes");
    await form.locator('[data-focus-edit-field="title"]').press("Enter");
    let focus = await waitForFocus(current => current.sections[1]?.title === "Second Notes");
    assert.deepEqual(focus.sections.map(section => section.title), ["Notes", "Second Notes"], `${viewport.name}: current-revision group editing uses the selected duplicate row`);

    await save([
      { title: "Notes", items: [{ title: "Original A" }] },
      { title: "Notes", items: [{ title: "Survivor B" }] },
    ]);
    await page.evaluate(() => refreshAgentFocus(parseRoute().key));
    await openText('[data-focus-edit-item="0:0"]', viewport);
    form = page.locator(`[data-focus-edit-form="${agentKey}"][data-focus-section-index="0"][data-focus-item-index="0"]`);
    await form.waitFor({ state: "visible" });
    await form.locator('[data-focus-edit-field="title"]').fill("Original A edited");
    await form.locator('[data-focus-edit-field="title"]').press("Enter");
    focus = await waitForFocus(current => current.sections[0]?.items[0]?.title === "Original A edited");
    assert.deepEqual(focus.sections.map(section => section.items[0].title), ["Original A edited", "Survivor B"], `${viewport.name}: item editing uses the selected duplicate row`);

    await openText('[data-focus-edit-item="1:0"]', viewport);
    form = page.locator(`[data-focus-edit-form="${agentKey}"][data-focus-section-index="1"][data-focus-item-index="0"]`);
    await form.waitFor({ state: "visible" });
    await form.locator('[data-focus-edit-field="title"]').fill("Survivor B edited");
    await form.locator('[data-focus-edit-field="title"]').press("Enter");
    focus = await waitForFocus(current => current.sections[1]?.items[0]?.title === "Survivor B edited");
    assert.deepEqual(focus.sections.map(section => section.items[0].title), ["Original A edited", "Survivor B edited"], `${viewport.name}: the second duplicate item remains distinct`);

    await save([{ title: "Keyboard", items: [{ title: "Toggle me", completed: false }] }]);
    await page.evaluate(() => refreshAgentFocus(parseRoute().key));
    const start = (await (await context.request.get(api)).json()).focus;
    const checkbox = page.locator('[data-focus-toggle-item="0:0"]');
    await checkbox.focus();
    await page.evaluate(() => { window.__focusSpaceCheckbox = document.querySelector('[data-focus-toggle-item="0:0"]'); });
    let releaseFirstWrite;
    let firstWriteStarted;
    const writeGate = new Promise(resolve => { releaseFirstWrite = resolve; });
    const writeStarted = new Promise(resolve => { firstWriteStarted = resolve; });
    let putCount = 0;
    await page.route(api, async route => {
      if (route.request().method() === "PUT") {
        putCount += 1;
        if (putCount === 1) {
          firstWriteStarted();
          await writeGate;
        }
      }
      await route.continue();
    });

    await page.keyboard.down("Space");
    await page.keyboard.up("Space");
    await firstWriteStarted;
    await page.keyboard.down("Space");
    releaseFirstWrite();
    try {
      await page.waitForFunction(key => state.agentFocusPendingCheckboxActivations.get(key)?.renderPending === true, agentKey, { timeout: 8_000 });
    } catch (error) {
      const debug = await page.evaluate(key => ({ pending: state.agentFocusPendingCheckboxActivations.get(key) && { renderPending: state.agentFocusPendingCheckboxActivations.get(key).renderPending, pressed: state.agentFocusPendingCheckboxActivations.get(key).pressed }, active: document.activeElement?.outerHTML?.slice(0, 100) }), agentKey);
      assert.fail(`${viewport.name}: Focus did not defer the Space redraw: ${JSON.stringify(debug)}; ${error.message}`);
    }
    assert.equal(await page.evaluate(() => window.__focusSpaceCheckbox === document.querySelector('[data-focus-toggle-item="0:0"]') && window.__focusSpaceCheckbox === document.activeElement), true, `${viewport.name}: the focused checkbox stays mounted while Space is down`);
    await page.keyboard.up("Space");

    await page.waitForFunction(key => !state.agentFocusWriteQueues.has(key) && !state.agentFocusPendingCheckboxActivations.has(key), agentKey);
    const finalFocus = await waitForFocus(current => current.sections[0]?.items[0]?.completed !== true);
    assert.notEqual(finalFocus.sections[0].items[0].completed, true, `${viewport.name}: second Space activation is saved`);
    assert.equal(finalFocus.revision, start.revision + 2, `${viewport.name}: both Space activations receive revisions`);
    assert.equal(putCount, 2, `${viewport.name}: both Space activations send writes`);
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
