const clickFocusAction = require("./focus_menu_actions");
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

    await save([{ title: "Keyboard", items: [{ title: "Toggle me", completed: false }, { title: "Keep group open", completed: false }] }]);
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
    await page.evaluate(() => refresh({ force: true }));
    const pollCheckboxState = await page.evaluate(key => ({
      sameNode: window.__focusSpaceCheckbox === document.querySelector('[data-focus-toggle-item="0:0"]'),
      connected: window.__focusSpaceCheckbox?.isConnected,
      focused: window.__focusSpaceCheckbox === document.activeElement,
      active: document.activeElement?.outerHTML?.slice(0, 160),
      pending: state.agentFocusPendingCheckboxActivations.get(key) && {
        pressed: state.agentFocusPendingCheckboxActivations.get(key).pressed,
        renderPending: state.agentFocusPendingCheckboxActivations.get(key).renderPending,
        connected: state.agentFocusPendingCheckboxActivations.get(key).checkbox.isConnected,
      },
      route: parseRoute(),
    }), agentKey);
    assert.equal(pollCheckboxState.sameNode && pollCheckboxState.connected && pollCheckboxState.focused, true, `${viewport.name}: a normal polling render keeps the focused checkbox mounted while Space is down: ${JSON.stringify(pollCheckboxState)}`);
    await page.keyboard.up("Space");

    await page.waitForFunction(key => !state.agentFocusWriteQueues.has(key) && !state.agentFocusPendingCheckboxActivations.has(key), agentKey);
    const finalFocus = await waitForFocus(current => current.sections[0]?.items[0]?.completed !== true);
    assert.notEqual(finalFocus.sections[0].items[0].completed, true, `${viewport.name}: second Space activation is saved`);
    assert.equal(finalFocus.revision, start.revision + 2, `${viewport.name}: both Space activations receive revisions`);
    assert.equal(putCount, 2, `${viewport.name}: both Space activations send writes`);
    assert.notEqual(finalFocus.sections[0].items[1].completed, true, `${viewport.name}: the second item keeps the group active throughout the held-Space check`);
    await page.unroute(api);

    const runFailedDeleteQueueCase = async (ambiguous) => {
      const groupItems = ambiguous ? [{ title: "Same item" }] : [{ title: "Original A" }];
      const survivingItems = ambiguous ? [{ title: "Same item" }] : [{ title: "Survivor B" }];
      await save([
        { title: "Notes", items: groupItems },
        { title: "Notes", items: survivingItems },
        { title: "Other", items: [{ title: "Pending toggle" }, { title: "Second item" }] },
      ]);
      await page.evaluate(() => refreshAgentFocus(parseRoute().key));
      const base = (await (await context.request.get(api)).json()).focus;
      let releaseFirst;
      let startFirst;
      const firstGate = new Promise(resolve => { releaseFirst = resolve; });
      const firstStarted = new Promise(resolve => { startFirst = resolve; });
      let puts = 0;
      await page.route(api, async route => {
        if (route.request().method() === "PUT") {
          puts += 1;
          if (puts === 1) {
            startFirst();
            await firstGate;
            await route.continue();
          } else if (puts === 2) {
            await route.fulfill({ status: 500, contentType: "application/json", body: JSON.stringify({ error: "controlled delete failure" }) });
          } else {
            await route.continue();
          }
        } else await route.continue();
      });

      await page.locator('[data-focus-toggle-item="2:0"]').check();
      await firstStarted;
      await clickFocusAction(page.locator('[data-focus-delete-group="0"]'));
      await page.locator('#confirmation-dialog [data-confirmation-accept]').click();
      await page.locator('[data-focus-edit-group="0"]').waitFor({ state: "visible" });
      const editGroup = page.locator('[data-focus-edit-group="0"]');
      if (viewport.width < 600) await editGroup.tap();
      else await editGroup.click();
      const form = page.locator(`[data-focus-edit-form="${agentKey}"][data-focus-section-index="0"][data-focus-item-index=""]`);
      await form.waitFor({ state: "visible" });
      const input = form.locator('[data-focus-edit-field="title"]');
      const draft = ambiguous ? "Ambiguous draft" : "Edited B";
      await input.fill(draft);
      await input.press("Enter");
      await page.waitForFunction(key => state.agentFocusWriteQueues.get(key)?.pending.length >= 1, agentKey);
      releaseFirst();

      if (ambiguous) {
        await page.getByText(/Focus changed elsewhere/).waitFor();
        await page.waitForFunction(key => !state.agentFocusWriteQueues.has(key), agentKey);
        const stored = (await (await context.request.get(api)).json()).focus;
        assert.deepEqual(stored.sections.slice(0, 2).map(section => section.title), ["Notes", "Notes"], `${viewport.name}: ambiguous rollback preserves both duplicate groups`);
        assert.deepEqual(stored.sections.slice(0, 2).map(section => section.items[0].title), ["Same item", "Same item"], `${viewport.name}: ambiguous rollback does not edit a wrong duplicate`);
        assert.equal(puts, 2, `${viewport.name}: ambiguous identity sends no unsafe third write`);
        const keptEditor = page.locator(`[data-focus-edit-form="${agentKey}"]`);
        assert.equal(await keptEditor.locator('[data-focus-edit-field="title"]').inputValue(), draft, `${viewport.name}: unproved target retains the draft text`);
        assert.equal(await page.evaluate(key => state.agentFocusEditingEntries.get(key)?.invalidated, agentKey), true, `${viewport.name}: unproved target is invalidated`);
        await keptEditor.locator('[data-focus-edit-field="title"]').press("Escape");
      } else {
        const stored = await waitForFocus(focus => focus.sections[1]?.title === draft);
        await page.waitForFunction(key => !state.agentFocusWriteQueues.has(key), agentKey);
        assert.deepEqual(stored.sections.slice(0, 2).map(section => section.title), ["Notes", draft], `${viewport.name}: queued edit follows its unique row after failed delete`);
        assert.deepEqual(stored.sections.slice(0, 2).map(section => section.items[0].title), ["Original A", "Survivor B"], `${viewport.name}: failed delete is rolled back and original content remains`);
        assert.equal(stored.sections[2].items[0].completed, true, `${viewport.name}: accepted first write remains in the rebuilt document`);
        assert.equal(stored.revision, base.revision + 2, `${viewport.name}: only accepted writes advance revisions`);
        assert.equal(puts, 3, `${viewport.name}: one rebuilt edit follows the failed delete`);
      }
      await page.unroute(api);
    };

    await runFailedDeleteQueueCase(false);
    await runFailedDeleteQueueCase(true);

    const runDeleteFailureWithoutEarlierWrite = async (ambiguous) => {
      const repeated = ambiguous ? [{ title: "Same item" }] : null;
      await save([
        { title: "Notes", items: repeated || [{ title: "Original A" }] },
        { title: "Notes", items: repeated || [{ title: "Survivor B" }] },
      ]);
      await page.evaluate(() => refreshAgentFocus(parseRoute().key));
      const base = (await (await context.request.get(api)).json()).focus;
      let releaseDelete;
      let startDelete;
      const deleteGate = new Promise(resolve => { releaseDelete = resolve; });
      const deleteStarted = new Promise(resolve => { startDelete = resolve; });
      let puts = 0;
      await page.route(api, async route => {
        if (route.request().method() === "PUT") {
          puts += 1;
          if (puts === 1) {
            startDelete();
            await deleteGate;
            await route.fulfill({ status: 500, contentType: "application/json", body: JSON.stringify({ error: "controlled delete failure" }) });
          } else await route.continue();
        } else await route.continue();
      });
      await clickFocusAction(page.locator('[data-focus-delete-group="0"]'));
      await page.locator('#confirmation-dialog [data-confirmation-accept]').click();
      await deleteStarted;
      const selected = page.locator('[data-focus-edit-group="0"]');
      if (viewport.width < 600) await selected.tap();
      else await selected.click();
      const form = page.locator(`[data-focus-edit-form="${agentKey}"][data-focus-section-index="0"][data-focus-item-index=""]`);
      await form.waitFor({ state: "visible" });
      const input = form.locator('[data-focus-edit-field="title"]');
      const draft = ambiguous ? "Unproved draft" : "Survivor renamed";
      await input.fill(draft);
      await input.press("Enter");
      await page.waitForFunction(key => state.agentFocusWriteQueues.get(key)?.pending.length >= 1, agentKey);
      releaseDelete();
      if (ambiguous) {
        await page.getByText(/Focus changed elsewhere/).waitFor();
        await page.waitForFunction(key => !state.agentFocusWriteQueues.has(key), agentKey);
        const stored = (await (await context.request.get(api)).json()).focus;
        assert.deepEqual(stored.sections.map(section => section.title), ["Notes", "Notes"], `${viewport.name}: same-revision ambiguous replay preserves both groups`);
        assert.equal(puts, 1, `${viewport.name}: same-revision ambiguous replay does not send a second write`);
        const keptEditor = page.locator(`[data-focus-edit-form="${agentKey}"]`);
        assert.equal(await keptEditor.locator('[data-focus-edit-field="title"]').inputValue(), draft, `${viewport.name}: same-revision unproved target keeps its draft`);
        await keptEditor.locator('[data-focus-edit-field="title"]').press("Escape");
      } else {
        const stored = await waitForFocus(focus => focus.sections[1]?.title === draft);
        await page.waitForFunction(key => !state.agentFocusWriteQueues.has(key), agentKey);
        assert.deepEqual(stored.sections.map(section => section.title), ["Notes", draft], `${viewport.name}: same-revision replay edits the unique surviving group`);
        assert.deepEqual(stored.sections.map(section => section.items[0].title), ["Original A", "Survivor B"], `${viewport.name}: same-revision replay preserves both original items`);
        assert.equal(stored.revision, base.revision + 1, `${viewport.name}: only the rebuilt edit advances the revision`);
        assert.equal(puts, 2, `${viewport.name}: unique same-revision replay sends one rebuilt edit`);
      }
      await page.unroute(api);
    };

    await runDeleteFailureWithoutEarlierWrite(false);
    await runDeleteFailureWithoutEarlierWrite(true);
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
