const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");

module.exports = async ({ browser, baseUrl, captureDir }) => {
  const results = [];
  const sortedKeys = ["alpha-a", "alpha-b", "web", "zulu"];
  for (const viewport of [{ width: 1440, height: 900 }, { width: 390, height: 844 }]) {
    const context = await browser.newContext({ viewport, isMobile: viewport.width < 500, hasTouch: viewport.width < 500 });
    const page = await context.newPage();
    const errors = [];
    page.on("pageerror", error => errors.push(error.message));
    const name = page.locator("#quick-agent-name");
    const project = page.locator("#quick-agent-project");
    const prompt = page.locator("#quick-agent-prompt");
    const currentProject = page.locator("[data-quick-agent-current-project]");
    const toggle = page.locator("[data-quick-agent-toggle]");
    const checkOverflow = async () => {
      assert(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth + 1));
    };
    const capture = async state => {
      await checkOverflow();
      if (captureDir) await page.screenshot({ path: path.join(captureDir, `auto-name-${state}-${viewport.width}.png`) });
    };
    const checkProject = async (key, label) => {
      assert.equal(await currentProject.isVisible(), true);
      assert.equal(await currentProject.innerText(), label);
      assert.equal(await currentProject.getAttribute("data-project-key"), key);
      assert.equal(await currentProject.evaluate(el => el.isContentEditable || el.matches("input, select, textarea")), false);
      assert.equal(await project.inputValue(), key);
      assert.equal(await page.locator("#quick-agent-form").getAttribute("data-project-key"), key);
    };
    const checkCollapsed = async () => {
      assert.equal(await toggle.getAttribute("aria-expanded"), "false");
      assert.equal(await currentProject.isVisible(), true);
      assert.equal(await name.isVisible(), false);
      assert.equal(await project.isVisible(), false);
      assert.equal(await page.locator("#quick-agent-harness").isVisible(), false);
      assert.equal(await prompt.evaluate(el => document.activeElement === el), true);
      await checkOverflow();
    };
    const api = async (url, method, body) => {
      const response = await context.request.fetch(`${baseUrl}${url}`, { method, data: body });
      assert(response.ok(), `${method} ${url}: ${await response.text()}`);
      return response.json();
    };
    await api("/settings/quick-agent", "PATCH", { default_project_key: "" });
    await page.goto(`${baseUrl}/ui#agents`, { waitUntil: "networkidle" });
    await page.locator("#quick-agent-fab").click();
    await prompt.waitFor({ state: "visible" });
    await checkCollapsed();
    await checkProject("web", "Web");
    assert.deepEqual(await page.evaluate(() => {
      const original = state.projects;
      try {
        state.projects = [...original,
          { key: "fixture-peer/online", name: "Peer online", server_key: "fixture-peer", server_status: "online", server_stale: false },
          { key: "fixture-peer/offline", name: "Peer offline", server_key: "fixture-peer", server_status: "offline", server_stale: true }];
        const eligible = quickAgentEligibleProjects().map(project => project.key);
        return [eligible.includes("fixture-peer/online"), eligible.includes("fixture-peer/offline")];
      } finally { state.projects = original; }
    }), [true, false], "local default must preserve available explicit peer choices");
    await page.keyboard.press("Escape");
    assert.equal(await page.locator("#quick-agent-dialog").evaluate(el => el.open), false);

    await page.goto(`${baseUrl}/ui#settings`, { waitUntil: "networkidle" });
    const setting = page.locator("#quick-agent-default-project");
    await setting.waitFor({ state: "visible" });
    assert.deepEqual(await setting.locator("option").evaluateAll(items => items.map(el => el.value)), ["", ...sortedKeys]);
    await setting.selectOption("alpha-a");
    await page.evaluate(() => refresh({ force: true }));
    assert.equal(await setting.inputValue(), "alpha-a", "Settings refresh lost an unsaved choice");
    await setting.selectOption("alpha-b");
    const savedResponse = page.waitForResponse(response => response.url() === `${baseUrl}/settings/quick-agent` && response.request().method() === "PATCH");
    await page.locator("#quick-agent-settings-form button[type=submit]").click();
    assert((await savedResponse).ok());
    await page.reload({ waitUntil: "networkidle" });
    assert.equal(await setting.inputValue(), "alpha-b", "default did not survive reload");
    await setting.scrollIntoViewIfNeeded();
    await capture("settings");
    // Scoped starts keep their project, but must still offer the selector.
    await page.goto(`${baseUrl}/ui#project/web`, { waitUntil: "networkidle" });
    await page.evaluate(() => openQuickAgent());
    await checkCollapsed();
    await checkProject("web", "Web");
    await toggle.click();
    assert.equal(await project.isVisible(), true);
    assert.deepEqual(await project.locator("option").evaluateAll(items => items.map(el => el.value)), sortedKeys);
    await prompt.fill("Scoped prompt");
    await name.fill("Scoped Name");
    await project.selectOption("zulu");
    await checkProject("zulu", "Zulu");
    await toggle.click();
    await checkCollapsed();
    await checkProject("zulu", "Zulu");
    await toggle.click();
    assert.equal(await prompt.inputValue(), "Scoped prompt");
    assert.equal(await name.inputValue(), "Scoped Name");
    // Even a one-project catalog keeps summary and selection as separate controls.
    await page.evaluate(() => {
      const original = state.projects;
      try {
        state.projects = original.filter(project => project.key === "web");
        renderQuickAgentDialog("web", {advancedOpen: true});
      } finally { state.projects = original; }
    });
    assert.equal(await project.isVisible(), true);
    assert.equal(await project.locator("option").count(), 1);
    await checkProject("web", "Web");
    await page.keyboard.press("Escape");
    await page.goto(`${baseUrl}/ui#agents`, { waitUntil: "networkidle" });
    await page.locator("#quick-agent-fab").click();
    await prompt.waitFor({ state: "visible" });
    await checkCollapsed();
    await checkProject("alpha-b", "alpha");
    assert.equal(await page.evaluate(() => quickAgentInitialProject({type: "project", key: "web"}).key), "web", "project scope lost its override");
    await prompt.fill("Check the export output.");
    const overlay = await page.locator("#quick-agent-dialog").evaluate(el => {
      const backdrop = getComputedStyle(el, "::backdrop");
      return { blur: backdrop.backdropFilter, webkitBlur: backdrop.webkitBackdropFilter,
        filter: backdrop.filter, background: backdrop.backgroundColor, opacity: getComputedStyle(el).opacity };
    });
    assert(!String(overlay.blur).includes("blur") && !String(overlay.webkitBlur).includes("blur"));
    assert.equal(overlay.filter, "none");
    assert.equal(overlay.opacity, "1");
    assert.equal(overlay.background, "rgba(0, 0, 0, 0.75)");
    await capture("collapsed");
    await toggle.click();
    await name.waitFor({ state: "visible" });
    assert.equal(await name.getAttribute("required"), null);
    assert.deepEqual(await project.locator("option").evaluateAll(items => items.map(el => el.value)), sortedKeys);
    const order = await page.evaluate(() => {
      const section = document.querySelector("#quick-agent-options");
      return { projectFirst: section.firstElementChild.contains(document.querySelector("#quick-agent-project")),
        nameSecond: section.children[1].contains(document.querySelector("#quick-agent-name")),
        toggleBottom: document.querySelector(".quick-agent-options-row").getBoundingClientRect().bottom,
        projectTop: document.querySelector("#quick-agent-project").getBoundingClientRect().top,
        nameBottom: document.querySelector("#quick-agent-name").getBoundingClientRect().bottom,
        harnessTop: document.querySelector("#quick-agent-harness").getBoundingClientRect().top };
    });
    assert(order.projectFirst && order.nameSecond && order.projectTop >= order.toggleBottom && order.nameBottom <= order.harnessTop);
    await capture("expanded");
    await toggle.click();
    await checkCollapsed();
    const responsePromise = page.waitForResponse(response => response.url() === `${baseUrl}/agents` && response.request().method() === "POST");
    await page.locator("#quick-agent-form button[type=submit]").click();
    const response = await responsePromise;
    assert(response.ok());
    assert(!Object.hasOwn(response.request().postDataJSON(), "name"));
    assert.equal(response.request().postDataJSON().project_key, "alpha-b");
    const { agent } = await response.json();
    assert.equal(agent.project_key, "alpha-b", "created project differs from visible current project");
    assert.match(agent.name, /^alpha custom \d+$/);
    await page.waitForFunction(async ({baseUrl, key}) => {
      const data = await (await fetch(`${baseUrl}/agents/${key}`)).json();
      return data.agent.name === "Export Check" && data.agent.status === "success";
    }, { baseUrl, key: agent.key });
    await page.evaluate(() => refresh({ force: true }));
    await page.getByRole("heading", { name: "Export Check", exact: true }).waitFor({ state: "visible" });
    await capture("result");

    await page.goto(`${baseUrl}/ui#agents`, { waitUntil: "networkidle" });
    await page.locator("#quick-agent-fab").click();
    await prompt.waitFor({ state: "visible" });
    await checkCollapsed();
    await prompt.fill("Keep this name and project.");
    await toggle.click();
    await name.fill("Manual Export");
    await page.evaluate(() => { delete state.projectDetails.web; });
    let releaseProject;
    const projectGate = new Promise(resolve => { releaseProject = resolve; });
    await page.route(`${baseUrl}/projects/web`, async route => { await projectGate; await route.continue(); });
    try {
      await project.selectOption("web");
      await checkProject("web", "Web");
      // Collapse while detail loading; the read-only name must already be current.
      await toggle.click();
      await checkCollapsed();
      await checkProject("web", "Web");
    } finally { releaseProject(); }
    await page.waitForFunction(() => Boolean(state.projectDetails.web));
    await page.unroute(`${baseUrl}/projects/web`);
    await toggle.click();
    assert.equal(await name.inputValue(), "Manual Export");
    assert.equal(await prompt.inputValue(), "Keep this name and project.");
    await toggle.click();
    await checkCollapsed();
    await api("/settings/quick-agent", "PATCH", { default_project_key: "zulu" });
    await page.evaluate(() => refresh({ force: true }));
    await checkCollapsed();
    await toggle.click();
    await checkProject("web", "Web");
    assert.equal(await name.inputValue(), "Manual Export");
    assert.equal(await prompt.inputValue(), "Keep this name and project.");
    await toggle.click();
    await checkCollapsed();
    await checkProject("web", "Web");
    await capture("changed");
    const explicitResponse = page.waitForResponse(response => response.url() === `${baseUrl}/agents` && response.request().method() === "POST");
    await page.locator("#quick-agent-form button[type=submit]").click();
    const explicitResult = await explicitResponse;
    assert(explicitResult.ok());
    assert.equal(explicitResult.request().postDataJSON().name, "Manual Export");
    assert.equal(explicitResult.request().postDataJSON().project_key, "web");
    const explicit = await explicitResult.json();
    assert.equal(explicit.agent.project_key, "web", "manual create target differs from current project label");
    await page.waitForFunction(async ({baseUrl, key}) => {
      const data = await (await fetch(`${baseUrl}/agents/${key}`)).json();
      return data.agent.status === "success" && data.agent.name === "Manual Export";
    }, { baseUrl, key: explicit.agent.key });
    assert.deepEqual(errors, []);
    results.push({ viewport: viewport.width, currentProjectVisible: true, selectorAndNameHidden: true, scopedSelector: true, singleProjectSelector: true,
      labelMatchesCreateTarget: true, delayedProjectConsistency: true, promptFocus: true, alphabeticProjectKeys: sortedKeys,
      persistedDefault: "alpha-b", scopedOverride: "web", manualSelectionPreserved: true, collapsedBlankAutoName: "Export Check",
      collapsedExplicitName: "Manual Export", overlay, overflow: false });
    await context.close();
  }
  if (captureDir) fs.writeFileSync(path.join(captureDir, "browser-results.json"), JSON.stringify(results, null, 2));
  console.log("agent-auto-name-smoke: ok", JSON.stringify(results));
};
