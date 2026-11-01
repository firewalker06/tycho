const assert = require("node:assert/strict");
const path = require("node:path");

module.exports = async ({ browser, baseUrl, agentKey, captureDir }) => {
  const results = [];
  for (const [device, viewport] of Object.entries({ desktop: { width: 1440, height: 900 }, mobile: { width: 390, height: 844 } })) {
    const context = await browser.newContext({ viewport, hasTouch: device === "mobile", colorScheme: "light", reducedMotion: "reduce" });
    const page = await context.newPage();
    const errors = [];
    let conversationReads = 0;
    page.on("request", request => { if (request.url().includes("/conversation")) conversationReads++; });
    page.on("pageerror", error => errors.push(error.message));
    await page.goto(`${baseUrl}/ui#agent/${agentKey}`, { waitUntil: "networkidle" });
    await page.locator("#prompt-input").waitFor();
    await page.evaluate(key => {
      const original = structuredClone(findAgent(key));
      window.installCollapseFixture = () => {
        const parent = { ...structuredClone(original), name: "Tree parent", unread: true, delegation: { children: [{ key: "fixture-child", agent_key: "fixture-child" }] } };
        const child = (key, name, parentKey, extra = {}) => ({ ...structuredClone(original), key, resource_key: key, name, delegation: { parent: { key: parentKey, agent_key: parentKey, connected: true }, children: [] }, unread: false, running: false, ...extra });
        state.agents = [parent,
          child("fixture-child", "Hidden child", key),
          child("fixture-grandchild", "Nested needle", "fixture-child"),
          child("fixture-peer", "Peer sibling", key, { server_key: "peer" }),
          child("fixture-orphan", "Unknown parent", "missing"),
          child("fixture-disconnected", "Disconnected root", "absent"),
          child("fixture-same", "Tree parent", "missing"),
        ];
        state.agentDetails = { [key]: parent };
        window.collapseFixtureAgents = structuredClone(state.agents);
      };
      window.installCollapseFixture();
      state.activityReadyServerKeys.clear();
      state.activityAgents.clear();
      const originalActivity = applyAgentActivity;
      applyAgentActivity = (data, ...args) => originalActivity({ ...data, servers: data.servers.map(server => ({ ...server, agents: window.collapseFixtureAgents })) }, ...args);
      // Polling runs the real refresh lifecycle; inject synthetic catalog data at its boundary.
      const originalGet = apiGet;
      apiGet = async (...args) => {
        const data = await originalGet(...args);
        const fixture = window.collapseFixtureAgents?.find(agent => agent.key === data.agent?.key);
        if (fixture) Object.assign(data.agent, { name: fixture.name, delegation: structuredClone(fixture.delegation) });
        return data;
      };
      const originalCatalog = loadResourceCatalog;
      loadResourceCatalog = async (...args) => {
        const data = await originalCatalog(...args);
        const local = data.servers.find(server => server.key === "local");
        return { ...data, servers: [
          { ...local, agents: window.collapseFixtureAgents },
        ] };
      };
    }, agentKey);
    for (const theme of ["dark", "light", "system"]) {
      // Every visible root has linked children. Start at the real shortcut's search focus.
      await page.evaluate(({ key, theme }) => {
        window.TychoAppearance.setPreference(theme);
        closeUnreadPanel();
        const child = { ...structuredClone(findAgent(key)), name: "Needle child", delegation: { parent: { key: "keyboard-parent", agent_key: "keyboard-parent" }, children: [{ key: "keyboard-grand", agent_key: "keyboard-grand" }] } };
        const parent = { ...structuredClone(child), key: "keyboard-parent", resource_key: "keyboard-parent", name: "Coordinator", delegation: { children: [{ key, agent_key: key }] } };
        const grand = { ...structuredClone(child), key: "keyboard-grand", resource_key: "keyboard-grand", name: "Nested worker", delegation: { parent: { key, agent_key: key }, children: [] } };
        state.agents = [parent, child, grand];
        state.agentDetails = Object.fromEntries(state.agents.map(agent => [agent.key, agent]));
        state.activityReadyServerKeys.clear(); state.activityAgents.clear();
        state.switcherDelegationExpanded = false; state.switcherDelegationOverrides.clear();
      }, { key: agentKey, theme });
      await page.keyboard.press("Control+k");
      const keyboardPanel = page.locator("#unread-agents-panel");
      const keyboardSearch = keyboardPanel.locator("[data-unread-agent-search]");
      const keyboardGroup = keyboardPanel.locator('[data-switcher-group="keyboard-parent"]');
      const focused = selector => page.evaluate(selector => document.activeElement?.matches(selector), selector);
      await page.waitForFunction(() => document.activeElement?.matches("[data-unread-agent-search]"));
      assert.equal(await keyboardPanel.locator("[data-open-agent]").count(), 1);
      await page.keyboard.press("Shift+Tab");
      assert.equal(await focused("[data-toggle-switcher-delegation]"), true, "Shift+Tab must reach header from initial search");
      await page.keyboard.press("Enter");
      assert.equal(await keyboardPanel.locator("[data-open-agent]").count(), 3);
      await page.keyboard.press("Tab");
      assert.equal(await focused("[data-unread-agent-search]"), true);
      await page.keyboard.press("Tab");
      assert.equal(await focused('[data-open-agent="keyboard-parent"]'), true);
      await page.keyboard.press("Tab");
      assert.equal(await focused('[data-switcher-group="keyboard-parent"]'), true, "Tab must reach parent control");
      await page.keyboard.press("Space");
      assert.equal(await keyboardPanel.locator("[data-open-agent]").count(), 1);
      await page.evaluate(() => syncUnreadAlert());
      assert.equal(await focused('[data-switcher-group="keyboard-parent"]'), true, "render must retain native control focus");
      await page.keyboard.press("Shift+Tab");
      await page.keyboard.press("Shift+Tab");
      assert.equal(await focused("[data-unread-agent-search]"), true);
      await page.keyboard.press("Alt+ArrowRight");
      assert.equal(await page.evaluate(() => state.unreadPanelLinkedAgentKey), "keyboard-parent");
      await page.keyboard.press("Escape");
      await page.keyboard.press("Control+k");
      await page.waitForFunction(() => document.activeElement?.matches("[data-unread-agent-search]"));
      await page.keyboard.type("Needle child");
      assert.equal(await keyboardPanel.locator("[data-open-agent]").count(), 3);
      assert.equal(await keyboardPanel.locator("[data-open-agent].selected").getAttribute("data-open-agent"), agentKey);
      await page.keyboard.press("ArrowDown");
      assert.equal(await keyboardPanel.locator("[data-open-agent].selected").getAttribute("data-open-agent"), "keyboard-grand");
      await page.keyboard.press("ArrowUp");
      assert.equal(await keyboardPanel.locator("[data-open-agent].selected").getAttribute("data-open-agent"), agentKey);
      const beforeActivityHtml = await keyboardPanel.locator(".unread-panel-list").innerHTML();
      const activitySelection = await page.evaluate(key => {
        const raw = structuredClone(state.agents);
        const child = raw.find(agent => agent.key === key);
        child.updated_at = "2026-11-01T05:00:01Z";
        const sibling = { ...structuredClone(child), key: "activity-sibling", resource_key: "activity-sibling", name: "Other worker", updated_at: "2026-11-01T05:00:02Z", delegation: { parent: { key: "keyboard-parent", agent_key: "keyboard-parent" }, children: [] } };
        raw.push(sibling);
        window.collapseFixtureAgents = raw;
        const accepted = applyAgentActivity({ revision: `fixture-${Date.now()}`, servers: [{ key: "local", name: "Local", local: true, ready: true }] }, state.activityAppliedSequence + 1);
        return { accepted, selected: state.unreadPanelSelectedKey, index: state.unreadPanelSelectedIndex, visible: filterQuickSwitchAgents().map(agent => agent.key) };
      }, agentKey);
      assert.equal(activitySelection.accepted, true, "real activity update must run");
      assert.deepEqual(activitySelection.visible, ["keyboard-parent", "activity-sibling", agentKey, "keyboard-grand"]);
      assert.notEqual(await keyboardPanel.locator(".unread-panel-list").innerHTML(), beforeActivityHtml, "activity must change the actual rendered list");
      assert.equal(await keyboardPanel.locator("[data-open-agent].selected").getAttribute("data-open-agent"), agentKey);
      assert.equal(activitySelection.index, 2);
      if (captureDir) await page.screenshot({ path: path.join(captureDir, `${device}-${theme}-activity-search.png`) });
      await page.keyboard.press("Enter");
      assert.equal(await keyboardPanel.isVisible(), false);
      assert.equal(new URL(page.url()).hash, `#agent/${agentKey}`, "activity insertion must not change the opened child key");
      await page.keyboard.press("Control+k");
      await page.waitForFunction(() => document.activeElement?.matches("[data-unread-agent-search]"));
      await page.keyboard.type("Needle child");
      // A catalog refresh must preserve an intentional nonmatching context selection too.
      await page.keyboard.press("ArrowUp");
      assert.equal(await keyboardPanel.locator("[data-open-agent].selected").getAttribute("data-open-agent"), "activity-sibling");
      await page.evaluate(() => refresh({ force: true }));
      assert.equal(await keyboardPanel.locator("[data-open-agent].selected").getAttribute("data-open-agent"), "activity-sibling");
      // Query changes choose the match again; ordinary rendering preserves arrow intent.
      await keyboardSearch.fill("Needle");
      await keyboardSearch.fill("Needle child");
      await page.evaluate(() => syncUnreadAlert());
      assert.equal(await keyboardPanel.locator("[data-open-agent].selected").getAttribute("data-open-agent"), agentKey);
      if (captureDir) await page.screenshot({ path: path.join(captureDir, `${device}-${theme}-child-search.png`) });
      await page.keyboard.press("Enter");
      assert.equal(await keyboardPanel.isVisible(), false);
      assert.equal(new URL(page.url()).hash, `#agent/${agentKey}`, "Enter must open the matching child key, not its context parent");
      await page.keyboard.press("Control+k");
      await page.waitForFunction(() => document.activeElement?.matches("[data-unread-agent-search]"));
      await page.keyboard.type("Needle child");
      await page.keyboard.press("Escape");
      assert.equal(await keyboardSearch.inputValue(), "");
      assert.equal(await keyboardPanel.locator("[data-open-agent]").count(), 1, "clear must restore manual collapse");
      assert.equal(await keyboardGroup.getAttribute("aria-expanded"), "false");
      await page.keyboard.press("Escape");
      await page.evaluate(theme => { window.installCollapseFixture(); state.activityReadyServerKeys.clear(); state.activityAgents.clear(); window.TychoAppearance.setPreference(theme); state.switcherDelegationExpanded = false; state.switcherDelegationOverrides.clear(); openUnreadPanelFromKeyboard(); }, theme);
      const panel = page.locator("#unread-agents-panel");
      const rows = panel.locator("[data-open-agent]");
      const search = panel.locator("[data-unread-agent-search]");
      const toggle = panel.locator("[data-toggle-switcher-delegation]");
      const keys = () => rows.evaluateAll(nodes => nodes.map(node => node.dataset.openAgent));
      const readsBeforeControls = conversationReads;
      assert.equal((await keys()).length, 4);
      assert.equal(await panel.getByText(/unread agents?/, { exact: false }).count(), 0);
      assert.match(await page.locator("#header-mark").getAttribute("aria-label"), /1 unread agent/);
      assert.equal(await toggle.getAttribute("aria-expanded"), "false");
      assert.match(await toggle.getAttribute("aria-label"), /\(3\)/);
      await page.evaluate(key => {
        const child = structuredClone(state.agents.find(agent => agent.key === "fixture-child"));
        child.key = child.resource_key = "fixture-arriving";
        state.agents.push(child);
        syncUnreadAlert();
      }, agentKey);
      assert.equal((await keys()).length, 4, "new children stay collapsed");
      assert.match(await toggle.getAttribute("aria-label"), /\(4\)/);
      await page.evaluate(() => { state.agents = state.agents.filter(agent => agent.key !== "fixture-arriving"); syncUnreadAlert(); });
      if (captureDir) await page.screenshot({ path: path.join(captureDir, `${device}-${theme}-collapsed.png`) });
      for (const query of ["Nested needle", "Hidden child", "Tree parent", "Peer sibling"]) {
        await search.fill(query);
        const visible = await keys();
        assert(visible.includes("fixture-grandchild"), `${query}: nested result hidden`);
        assert(visible.includes("fixture-peer"), `${query}: peer hidden`);
        assert.equal(await toggle.isDisabled(), true);
      }
      if (captureDir) await page.screenshot({ path: path.join(captureDir, `${device}-${theme}-search.png`) });
      await panel.locator("[data-clear-unread-agent-search]").click();
      assert.equal((await keys()).length, 4);
      await page.waitForFunction(() => document.activeElement?.matches("[data-unread-agent-search]"));
      await toggle.focus();
      await page.keyboard.press("Enter");
      assert.equal((await keys()).length, 7);
      assert.equal(await toggle.evaluate(node => node === document.activeElement), true, await page.evaluate(() => document.activeElement.tagName));
      assert.equal(conversationReads, readsBeforeControls, "menu controls must not fetch conversations");
      await page.evaluate(() => refresh({ force: true }));
      assert.equal((await keys()).length, 7);
      assert.equal(await toggle.evaluate(node => node === document.activeElement), true, await page.evaluate(() => document.activeElement.tagName));
      await search.fill("Nested needle");
      await search.fill("");
      assert.equal((await keys()).length, 7, "explicit expansion lost after search");
      if (device === "mobile") await toggle.tap();
      else await toggle.click();
      const group = panel.locator(`[data-switcher-group="${agentKey}"]`);
      await group.focus();
      await page.keyboard.press("Space");
      assert.equal((await keys()).length, 6, "nested group must stay collapsed");
      await page.evaluate(() => syncUnreadAlert());
      assert.equal(await group.evaluate(node => node === document.activeElement), true);
      await panel.locator('[data-switcher-group="fixture-child"]').click();
      assert.equal((await keys()).length, 7);
      await search.fill("no such agent");
      assert.equal((await keys()).length, 0);
      await search.fill("");
      assert.equal((await keys()).length, 7);
      // Arrow selection must use exactly the visible list.
      if (device === "mobile") await toggle.tap();
      else await toggle.click();
      await search.focus();
      const beforeArrow = await page.evaluate(() => state.unreadPanelSelectedIndex);
      const visibleCount = await rows.count();
      await page.keyboard.press("ArrowDown");
      assert.equal(await page.evaluate(() => state.unreadPanelSelectedIndex), (beforeArrow + 1) % visibleCount);
      const bounds = await panel.boundingBox();
      assert(bounds.x >= 0 && bounds.x + bounds.width <= viewport.width + 1);
      assert.equal(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth), true);
      await page.keyboard.press("Escape");
      await page.evaluate(() => openUnreadPanelFromKeyboard());
      await panel.locator(`[data-open-agent="${agentKey}"]`).click();
      assert.equal(await panel.isVisible(), false);
      assert.equal(new URL(page.url()).hash, `#agent/${agentKey}`);
      results.push({ device, theme, collapsed: 4, expanded: 7, search: "pass", keyboard: "pass", refresh: "pass", nativeTraversal: "pass", exactChildEnter: "pass", linkedShortcut: "Alt+Right", activityIdentity: "pass", catalogArrowIntent: "pass" });
    }
    assert.deepEqual(errors, []);
    await context.close();
  }
  console.log(JSON.stringify({ delegatedCollapse: results }));
  return { delegatedCollapse: results };
};
