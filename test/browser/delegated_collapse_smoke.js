const assert = require("node:assert/strict");
const path = require("node:path");

module.exports = async ({ browser, baseUrl, agentKey, captureDir }) => {
  const results = [];
  const integratedFacts = button => button.evaluate(toggle => {
    const row = toggle.parentElement;
    const main = row.querySelector(":scope > [data-open-agent]");
    const rect = node => { const r = node.getBoundingClientRect(); return { x: r.x, y: r.y, right: r.right, bottom: r.bottom, width: r.width, height: r.height }; };
    const style = getComputedStyle(toggle);
    return { row: rect(row), main: rect(main), toggle: rect(toggle), divider: Number.parseFloat(style.borderLeftWidth), dividerStyle: style.borderLeftStyle, dividerColor: style.borderLeftColor, outerRight: Number.parseFloat(getComputedStyle(row).borderRightWidth), outerTop: Number.parseFloat(getComputedStyle(row).borderTopWidth), outerBottom: Number.parseFloat(getComputedStyle(row).borderBottomWidth), role: row.getAttribute("role"), siblings: main.parentElement === toggle.parentElement, nested: row.querySelectorAll("button button").length, controlled: document.getElementById(toggle.getAttribute("aria-controls"))?.contains(row) === true };
  });
  const assertIntegrated = facts => {
    assert.equal(facts.siblings, true);
    assert.equal(facts.role, "group");
    assert.equal(facts.nested, 0);
    assert.equal(facts.controlled, true);
    assert(Math.abs(facts.main.right - facts.toggle.x) <= 1, "actions must meet without a floating gap");
    assert(Math.abs(facts.main.y - facts.toggle.y) <= 1);
    assert(Math.abs(facts.main.height - facts.toggle.height) <= 1, "disclosure hit area must fill the row height");
    assert(Math.abs(facts.toggle.right + facts.outerRight - facts.row.right) <= 1);
    assert(Math.abs(facts.toggle.y - facts.row.y - facts.outerTop) <= 1);
    assert(Math.abs(facts.toggle.height + facts.outerTop + facts.outerBottom - facts.row.height) <= 1);
    assert(facts.toggle.width >= 44 && facts.toggle.height >= 44);
    assert(facts.divider >= 1 && facts.dividerStyle === "solid" && facts.dividerColor !== "rgba(0, 0, 0, 0)");
  };
  const assertVisibleFocus = async page => {
    const focus = await page.evaluate(() => { const element = document.activeElement; const s = getComputedStyle(element); return { visible: element.matches(":focus-visible"), width: Number.parseFloat(s.outlineWidth), style: s.outlineStyle }; });
    assert(focus.visible && focus.width >= 2 && focus.style !== "none", "each native action needs visible keyboard focus");
  };
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
      await assertVisibleFocus(page);
      await page.keyboard.press("Tab");
      assert.equal(await focused('[data-switcher-group="keyboard-parent"]'), true, "Tab must reach parent control");
      await assertVisibleFocus(page);
      assertIntegrated(await integratedFacts(keyboardGroup));
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
      const rowGroup = panel.locator(`[data-switcher-group="${agentKey}"]`);
      const layout = await integratedFacts(rowGroup);
      assertIntegrated(layout);
      assert.equal(await panel.locator("button button").count(), 0);
      assert.match(await rowGroup.getAttribute("aria-label"), /Tree parent \(3\)/);
      await page.evaluate(key => {
        const template = state.agents.find(agent => agent.key === "fixture-child");
        for (let i = 0; i < 100; i++) state.agents.push({ ...structuredClone(template), key: `fixture-count-${i}`, resource_key: `fixture-count-${i}`, delegation: { parent: { key, agent_key: key }, children: [] } });
        syncUnreadAlert();
      }, agentKey);
      assert.match(await rowGroup.getAttribute("aria-label"), /\(103\)/);
      assertIntegrated(await integratedFacts(rowGroup));
      const countFits = await rowGroup.evaluate(button => {
        const outer = button.getBoundingClientRect();
        return [...button.children].every(child => { const r = child.getBoundingClientRect(); return r.x >= outer.x && r.right <= outer.right; });
      });
      assert.equal(countFits, true, "chevron and a larger count must stay inside the segment");
      await page.evaluate(() => { state.agents = state.agents.filter(agent => !agent.key.startsWith("fixture-count-")); syncUnreadAlert(); });
      const routeBeforeToggle = page.url();
      // The top and bottom of the segment must both toggle, without opening the agent.
      await rowGroup[device === "mobile" ? "tap" : "click"]({ position: { x: layout.toggle.width / 2, y: 2 } });
      assert.equal(await rowGroup.getAttribute("aria-expanded"), "true");
      assert.equal((await keys()).length, 6);
      assert.equal(page.url(), routeBeforeToggle);
      assert.equal(await panel.isVisible(), true);
      const openedLayout = await integratedFacts(rowGroup);
      assertIntegrated(openedLayout);
      await rowGroup[device === "mobile" ? "tap" : "click"]({ position: { x: openedLayout.toggle.width / 2, y: openedLayout.toggle.height - 2 } });
      assert.equal(await rowGroup.getAttribute("aria-expanded"), "false");
      assert.equal((await keys()).length, 4);
      assert.equal(page.url(), routeBeforeToggle);
      await page.mouse.move(0, 0);
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
      assertIntegrated(await integratedFacts(rowGroup));
      if (captureDir) await page.screenshot({ path: path.join(captureDir, `${device}-${theme}-expanded.png`) });
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
      const mainAction = panel.locator(`[data-open-agent="${agentKey}"]`);
      const mainBounds = await mainAction.boundingBox();
      await mainAction.click({ position: { x: mainBounds.width - 2, y: mainBounds.height / 2 } });
      assert.equal(await panel.isVisible(), false);
      assert.equal(new URL(page.url()).hash, `#agent/${agentKey}`);
      results.push({ device, theme, collapsed: 4, expanded: 7, search: "pass", keyboard: "pass", refresh: "pass", nativeTraversal: "pass", exactChildEnter: "pass", linkedShortcut: "Alt+Right", activityIdentity: "pass", catalogArrowIntent: "pass", integratedRow: layout, segmentHitAreas: "pass" });
    }
    assert.deepEqual(errors, []);
    await context.close();
  }
  console.log(JSON.stringify({ delegatedCollapse: results }));
  return { delegatedCollapse: results };
};
