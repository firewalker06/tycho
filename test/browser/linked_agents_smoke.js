const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");

module.exports = async ({ browser, baseUrl, agentKey, captureDir }) => {
  const results = [];
  const baselineSource = process.env.TYCHO_REMOTE_UI_LINKED_AGENTS_BASELINE ? fs.readFileSync(process.env.TYCHO_REMOTE_UI_LINKED_AGENTS_BASELINE, "utf8") : "";
  for (const [device, viewport] of Object.entries({ desktop: { width: 1440, height: 900 }, mobile: { width: 390, height: 844 } })) {
    const context = await browser.newContext({ viewport, hasTouch: device === "mobile", colorScheme: "light", reducedMotion: "reduce" });
    const page = await context.newPage();
    const errors = [];
    page.on("pageerror", error => errors.push(error.message));
    await page.goto(`${baseUrl}/ui#agent/${agentKey}`, { waitUntil: "networkidle" });
    await page.locator("#prompt-input").waitFor();
    // Fixtures exist only in this isolated browser. No harness or production action runs.
    await page.evaluate(key => {
      window.linkedFixtureOwner = structuredClone(findAgent(key));
      window.installLinkedFixture = (mode = "mixed") => {
        const owner = structuredClone(window.linkedFixtureOwner);
        const ref = (key, name, extra = {}) => ({ key, agent_key: key, name, server_key: "local", state: "active", connected: true, status: "succeeded", ...extra });
        const refs = [
          ref("fixture-idle", "Linked idle", { status: "idle" }),
          ref("fixture-input", "Linked awaiting input", { status: "awaiting-input", owner: "user" }),
          ref("fixture-running", "Linked running", { status: "running" }),
          ref("fixture-archive", "Archived review", { state: "archived", archived: true }),
          ref("fixture-disconnected", "Disconnected reports", { connected: false }),
          ref("fixture-unknown", "Unknown catalog entry", { state: "missing", status: "" }),
        ];
        owner.delegation = { children: mode === "old" ? refs.slice(3, 5) : mode === "empty" ? [] : refs };
        state.agents = state.agents.filter(agent => !agent.key.startsWith("fixture-"));
        for (const reference of refs.filter(ref => ref.state === "active")) state.agents.push({ ...reference, archived: false, running: reference.status === "running", delegation: { parent: { key: owner.key, owner: reference.owner } } });
        state.agentDetails[key] = owner;
        window.linkedFixtureDelegation = owner.delegation;
        state.renderedViewHtml = "";
        render();
      };
      window.installLinkedFixture();
      const fixtureResponse = original => async (...args) => {
        const data = await original(...args);
        const patch = value => {
          if (!value || typeof value !== "object") return;
          if (value.key === key && value.project_key) value.delegation = structuredClone(window.linkedFixtureDelegation);
          for (const nested of Object.values(value)) patch(nested);
        };
        patch(data);
        return data;
      };
      apiGet = fixtureResponse(apiGet);
      brokerGet = fixtureResponse(brokerGet);
    }, agentKey);
    if (baselineSource && captureDir) {
      await page.evaluate(source => {
        window.currentLinkedRenderer = renderLinkedAgentsFlyout;
        const start = source.indexOf("function renderLinkedAgentsFlyout(");
        const end = source.indexOf("\nfunction renderLinkedAgentsToggle", start);
        renderLinkedAgentsFlyout = new Function(`return (${source.slice(start, end)})`)();
        window.TychoAppearance.setPreference("dark");
        state.renderedViewHtml = ""; render();
      }, baselineSource);
      await page.locator("[data-toggle-linked-agents]").click();
      await page.screenshot({ path: path.join(captureDir, `${device}-before.png`) });
      await page.keyboard.press("Escape");
      await page.evaluate(() => { renderLinkedAgentsFlyout = window.currentLinkedRenderer; state.renderedViewHtml = ""; render(); });
    }
    for (const preference of ["dark", "light", "system"]) {
      await page.evaluate(() => window.installLinkedFixture());
      await page.evaluate(value => window.TychoAppearance.setPreference(value), preference);
      if (preference === "system") {
        await page.emulateMedia({ colorScheme: "dark" });
        await page.waitForFunction(() => document.documentElement.dataset.appearance === "dark");
        assert.equal(await page.locator("html").getAttribute("data-appearance"), "dark");
        await page.emulateMedia({ colorScheme: "light" });
        await page.waitForFunction(() => document.documentElement.dataset.appearance === "light");
      }
      await page.locator("[data-toggle-linked-agents]").click();
      const flyout = page.locator("[data-linked-agents-flyout]");
      await flyout.waitFor({ state: "visible" });
      const summary = flyout.locator(".linked-agent-history > summary");
      assert.equal(await summary.innerText(), "Archived or disconnected (2)");
      for (const key of ["idle", "input", "running"]) assert(await flyout.locator(`[data-open-agent='fixture-${key}']`).isVisible(), `linked ${key} stays visible`);
      assert(await flyout.getByText("Unknown catalog entry", { exact: true }).isVisible());
      assert(!await flyout.getByText("Archived review", { exact: true }).isVisible());
      assert(!await flyout.getByText("Disconnected reports", { exact: true }).isVisible());
      const capture = async suffix => { if (captureDir) await page.screenshot({ path: path.join(captureDir, `${device}-${preference}-${suffix}.png`) }); };
      await summary.scrollIntoViewIfNeeded();
      await capture("closed");
      await summary.focus();
      await page.keyboard.press("Enter");
      assert(await flyout.locator("details").evaluate(el => el.open), "Enter expands native disclosure");
      const accessibility = await context.newCDPSession(page);
      const { root } = await accessibility.send("DOM.getDocument");
      const { nodeId } = await accessibility.send("DOM.querySelector", { nodeId: root.nodeId, selector: ".linked-agent-history > summary" });
      const { nodes } = await accessibility.send("Accessibility.getPartialAXTree", { nodeId });
      assert(nodes.some(node => node.properties?.some(property => property.name === "expanded" && property.value.value === true)), `native disclosure accessibility: ${JSON.stringify(nodes)}`);
      await accessibility.detach();
      assert(await flyout.getByText("Archived review", { exact: true }).isVisible());
      assert(await flyout.getByText("Archived", { exact: true }).isVisible());
      assert(await flyout.getByText(/Reports disconnected/).isVisible());
      assert.equal(await flyout.locator("[data-open-agent='fixture-archive']").getAttribute("href"), "#agent/fixture-archive");
      assert.equal(await flyout.locator("[data-set-delegation-connection='fixture-archive']").count(), 0, "archive has no connection action");
      assert.equal(await flyout.locator("[data-set-delegation-connection='fixture-disconnected']").getAttribute("aria-label"), "Reconnect delegation reports");
      assert.equal(await flyout.locator("[data-set-delegation-connection='fixture-idle']").getAttribute("aria-label"), "Disconnect delegation reports");
      await flyout.locator("[data-open-agent='fixture-disconnected']").scrollIntoViewIfNeeded();
      await capture("open");
      await page.evaluate(() => refresh({ force: true }));
      assert(await flyout.locator("details").evaluate(el => el.open), "open state survives rendering");
      assert(await summary.evaluate(el => el === document.activeElement), "keyboard focus survives rendering");
      await page.keyboard.press("Space");
      assert(!await flyout.locator("details").evaluate(el => el.open), "Space collapses native disclosure");
      await page.evaluate(() => { state.renderedViewHtml = ""; render(); });
      assert(!await flyout.locator("details").evaluate(el => el.open), "closed state survives rendering");
      if (device === "mobile") await summary.tap(); else await summary.click();
      assert(await flyout.locator("details").evaluate(el => el.open), "pointer/touch expands disclosure");
      await summary.click();
      const bounds = await flyout.boundingBox();
      assert(bounds.x >= 0 && bounds.x + bounds.width <= viewport.width + 1 && bounds.y >= 0 && bounds.y + bounds.height <= viewport.height + 1, "flyout fits viewport");
      assert(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth), "no horizontal overflow");
      results.push({ device, preference, nativeDisclosure: true, keyboard: true, touch: device === "mobile", renderPreservation: true, actionLabels: true, bounds });
      await page.keyboard.press("Escape");
    }
    await page.evaluate(() => window.installLinkedFixture("old"));
    await page.locator("[data-toggle-linked-agents]").click();
    assert.equal(await page.locator(".linked-agent-history > summary").innerText(), "Archived or disconnected (2)");
    assert.equal(await page.locator("[data-linked-agents-flyout] .agent-reference:visible").count(), 0);
    await page.evaluate(() => window.installLinkedFixture("empty"));
    assert.equal(await page.locator("[data-toggle-linked-agents]").count(), 0);
    // Restore the server-backed fixture and check a real forced refresh.
    await page.evaluate(key => { state.agentDetails[key] = window.linkedFixtureOwner; }, agentKey);
    await page.evaluate(() => refresh({ force: true }));
    assert.deepEqual(errors, []);
    await context.close();
  }
  if (captureDir) fs.writeFileSync(path.join(captureDir, "linked-agents-browser-checks.json"), JSON.stringify(results, null, 2));
  console.log("linked-agents-smoke: desktop/mobile Dark/Nord Light/System, keyboard, touch, render refresh, lifecycle and actions passed");
};
