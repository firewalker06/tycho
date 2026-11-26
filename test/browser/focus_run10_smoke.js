const assert = require("node:assert/strict");

module.exports = async ({ context, page, api, agentKey, save, waitForFocus }) => {
  const viewports = [
    { name: "desktop", width: 1440, height: 900 },
    { name: "mobile", width: 390, height: 844 },
  ];
  const activate = async (locator, viewport) => {
    if (viewport.width < 600) await locator.tap();
    else await locator.click();
  };

  for (const viewport of viewports) {
    await page.setViewportSize(viewport);
    for (const editCase of [
      { name: "group", sections: [{ title: "Original", items: [] }], trigger: '[data-focus-edit-group="0"]', form: `[data-focus-edit-form="${agentKey}"][data-focus-item-index=""]` },
      { name: "item", sections: [{ title: "Group", items: [{ title: "Original" }] }], trigger: '[data-focus-edit-item="0:0"]', form: `[data-focus-edit-form="${agentKey}"][data-focus-item-index="0"]` },
    ]) {
      await save(editCase.sections);
      await page.evaluate(() => refreshAgentFocus(parseRoute().key));
      await activate(page.locator(editCase.trigger), viewport);
      const form = page.locator(editCase.form);
      await form.waitFor({ state: "visible" });
      const title = form.locator('[data-focus-edit-field="title"]');
      let releaseFirst;
      let releaseSecond;
      let firstStarted;
      let secondStarted;
      const firstGate = new Promise(resolve => { releaseFirst = resolve; });
      const secondGate = new Promise(resolve => { releaseSecond = resolve; });
      const firstWrite = new Promise(resolve => { firstStarted = resolve; });
      const secondWrite = new Promise(resolve => { secondStarted = resolve; });
      let puts = 0;
      await page.route(api, async route => {
        if (route.request().method() !== "PUT") return route.continue();
        puts += 1;
        if (puts === 1) {
          firstStarted();
          await firstGate;
        } else if (puts === 2) {
          secondStarted();
          await secondGate;
        }
        await route.continue();
      });
      await title.fill("First");
      await title.press("Enter");
      await firstWrite;
      await title.fill("Second");
      await title.press("Enter");
      releaseFirst();
      await secondWrite;
      await title.fill("Latest");
      await title.press("Enter");
      releaseSecond();
      const stored = await waitForFocus(focus => editCase.name === "group"
        ? focus.sections[0]?.title === "Latest"
        : focus.sections[0]?.items[0]?.title === "Latest");
      assert.equal(editCase.name === "group" ? stored.sections[0].title : stored.sections[0].items[0].title, "Latest", `${viewport.name}: staggered ${editCase.name} save persists the latest draft`);
      assert.equal(puts, 3, `${viewport.name}: staggered ${editCase.name} save sends all three writes`);
      await page.unroute(api);
    }

    await save([
      { title: "Active A", items: [{ title: "A" }] },
      { title: "Completed B", completed: true, items: [{ title: "B", completed: true }] },
    ]);
    await page.evaluate(() => refreshAgentFocus(parseRoute().key));
    const completedToggle = page.locator(".agent-focus-completed [data-focus-section]");
    await activate(completedToggle, viewport);
    assert.equal(await completedToggle.getAttribute("aria-expanded"), "true", `${viewport.name}: completed group is expanded before replay`);
    let releaseDelete;
    let deleteStarted;
    const deleteGate = new Promise(resolve => { releaseDelete = resolve; });
    const deleteWrite = new Promise(resolve => { deleteStarted = resolve; });
    let puts = 0;
    await page.route(api, async route => {
      if (route.request().method() !== "PUT") return route.continue();
      puts += 1;
      if (puts === 1) {
        deleteStarted();
        await deleteGate;
        await route.fulfill({ status: 500, contentType: "application/json", body: JSON.stringify({ error: "controlled delete failure" }) });
      } else await route.continue();
    });
    await page.locator('[data-focus-delete-group="0"]').click();
    await page.locator("#confirmation-dialog [data-confirmation-accept]").click();
    await deleteWrite;
    await activate(page.locator('[data-focus-complete-group="0"]'), viewport);
    await activate(page.locator('[data-focus-complete-group="0"]'), viewport);
    releaseDelete();
    await waitForFocus(focus => focus.sections[1]?.completed === true);
    await page.waitForFunction(key => !state.agentFocusWriteQueues.has(key), agentKey);
    const finalToggle = page.locator(".agent-focus-completed [data-focus-section]");
    assert.equal(await finalToggle.getAttribute("aria-expanded"), "false", `${viewport.name}: rebased completed group collapses after failed delete`);
    assert.equal(puts, 3, `${viewport.name}: failed delete replays both completion writes`);
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
