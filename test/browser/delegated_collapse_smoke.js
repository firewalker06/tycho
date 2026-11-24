const assert = require("node:assert/strict");
const path = require("node:path");

module.exports = async ({ browser, baseUrl, agentKey, captureDir }) => {
  const results = [];
  const integratedFacts = button => button.evaluate(toggle => {
    const row = toggle.parentElement;
    const tree = toggle.closest("[data-agent-tree], .switcher-tree-row");
    const main = row.querySelector(":scope > [data-open-agent], :scope > .selectable-agent-row");
    const rect = node => { const r = node.getBoundingClientRect(); return { x: r.x, y: r.y, right: r.right, bottom: r.bottom, width: r.width, height: r.height }; };
    const style = getComputedStyle(toggle);
    const controlled = document.getElementById(toggle.getAttribute("aria-controls"));
    return { row: rect(row), tree: rect(tree), main: rect(main), toggle: rect(toggle), divider: Number.parseFloat(style.borderLeftWidth), dividerStyle: style.borderLeftStyle, dividerColor: style.borderLeftColor, outerRight: Number.parseFloat(getComputedStyle(tree).borderRightWidth), outerTop: Number.parseFloat(getComputedStyle(tree).borderTopWidth), role: tree.getAttribute("role"), siblings: main.parentElement === toggle.parentElement, nested: row.querySelectorAll("button button").length, controlled: Boolean(controlled && (tree.contains(controlled) || controlled.contains(tree))) };
  });
  const assertIntegrated = facts => {
    assert.equal(facts.siblings, true);
    assert.equal(facts.role, "group");
    assert.equal(facts.nested, 0);
    assert.equal(facts.controlled, true);
    assert(Math.abs(facts.main.right - facts.toggle.x) <= 1, "actions must meet without a floating gap");
    assert(Math.abs(facts.main.y - facts.toggle.y) <= 1);
    assert(Math.abs(facts.main.height - facts.toggle.height) <= 1, "disclosure hit area must fill the row height");
    assert(Math.abs(facts.toggle.right + facts.outerRight - facts.tree.right) <= 1);
    assert(Math.abs(facts.toggle.y - facts.tree.y - facts.outerTop) <= 1);
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
          child("fixture-child", "Hidden child", key, { running: true, status: "running" }),
          child("fixture-grandchild", "Nested needle", "fixture-child"),
          child("fixture-peer", "Peer sibling", key, { server_key: "peer" }),
          child("fixture-orphan", "Unknown parent", "missing", { running: true, status: "running" }),
          child("fixture-disconnected", "Disconnected root", "absent"),
          child("fixture-same", "Tree parent", "missing"),
        ];
        state.agentDetails = { [key]: parent };
        window.collapseFixtureAgents = structuredClone(state.agents);
      };
      window.installCollapseFixture();
      window.renderDelegatedListFixtures = () => {
        state.agents = window.collapseFixtureAgents;
        state.servers = [{ key: "local", name: "Local", local: true, ready: true, status: "ready" }];
        state.filters.agents = "";
        state.route = { type: "tab", tab: "agents" };
        for (const sort of ["agent_name_asc", "agent_name_desc", "agent_updated_asc", "agent_updated_desc", "project_asc", "project_desc"]) {
          state.agentSort = sort;
          renderAgents({ focusFilter: false });
          const sortedTree = document.querySelector(`[data-agent-tree="${CSS.escape(key)}"]`);
          const sortedChild = sortedTree?.querySelector('[data-open-agent="fixture-child"]');
          const sortedCount = sortedTree?.querySelector(".delegated-running-count");
          if (!sortedTree || !sortedChild || !sortedCount || !sortedChild.closest(".agent-delegation-children").hidden) {
            throw new Error(`Agents sort ${sort} did not group and collapse the running child`);
          }
          if (sortedCount.textContent.trim() !== "1") throw new Error(`Agents sort ${sort} running count was ${sortedCount.textContent}`);
        }
        state.agentSort = "agent_name_asc";
        state.filters.agents = "Hidden child";
        renderAgents({ focusFilter: false });
        if (!document.querySelector('[data-open-agent="fixture-child"]') || document.querySelector(`[data-agent-tree="${CSS.escape(key)}"]`)) {
          throw new Error("Agent search must keep a matching delegated child directly reachable");
        }
        state.filters.agents = "";
        state.agentSort = "relevancy";
        renderAgents({ focusFilter: false });
        let agentsTree = document.querySelector(`[data-agent-tree="${CSS.escape(key)}"]`);
        let agentsChild = agentsTree?.querySelector('[data-open-agent="fixture-child"]');
        let badge = agentsTree?.querySelector(".delegated-running-count");
        let status = agentsTree?.querySelector(".agent-status-icon.running");
        if (!agentsTree || !agentsChild || !badge || !status) throw new Error("Agents list did not show collapsed parent with running count");
        if (!agentsChild.closest(".agent-delegation-children").hidden) throw new Error("Agents list child row was not collapsed");
        if (badge.textContent.trim() !== "1") throw new Error(`Agents list running count was ${badge.textContent}`);
        const toggle = agentsTree.querySelector("[data-toggle-agent-tree]");
        const mainRow = agentsTree.querySelector(":scope > .agent-delegation-parent-row > [data-open-agent]");
        if (mainRow.parentElement !== toggle.parentElement || mainRow.contains(toggle) || mainRow.querySelector("button button")) {
          throw new Error("Agent row and delegation disclosure must be sibling buttons");
        }
        const rowFacts = (() => {
          const parentRow = toggle.parentElement;
          const rect = node => { const bounds = node.getBoundingClientRect(); return { x: bounds.x, y: bounds.y, right: bounds.right, width: bounds.width, height: bounds.height }; };
          const toggleStyle = getComputedStyle(toggle);
          const treeStyle = getComputedStyle(agentsTree);
          const statusIcon = mainRow.querySelector(".agent-status-icon.running");
          const countBadge = mainRow.querySelector(".delegated-running-count");
          if (!statusIcon || !countBadge) throw new Error("Running count must appear with the parent status icon");
          const iconBounds = rect(statusIcon);
          const badgeBounds = rect(countBadge);
          return { parent: rect(parentRow), main: rect(mainRow), toggle: rect(toggle), tree: rect(agentsTree),
            divider: Number.parseFloat(toggleStyle.borderLeftWidth), outerRight: Number.parseFloat(treeStyle.borderRightWidth),
            outerTop: Number.parseFloat(treeStyle.borderTopWidth), icon: iconBounds, badge: badgeBounds };
        })();
        if (Math.abs(rowFacts.main.right - rowFacts.toggle.x) > 1 || Math.abs(rowFacts.main.y - rowFacts.toggle.y) > 1 ||
            Math.abs(rowFacts.main.height - rowFacts.toggle.height) > 1 || Math.abs(rowFacts.toggle.right + rowFacts.outerRight - rowFacts.tree.right) > 1 ||
            Math.abs(rowFacts.toggle.y - rowFacts.tree.y - rowFacts.outerTop) > 1 || rowFacts.toggle.height < 44 || rowFacts.toggle.width < 44 ||
            rowFacts.divider < 1 || !(rowFacts.badge.x < rowFacts.icon.x + rowFacts.icon.width && rowFacts.badge.right > rowFacts.icon.x)) {
          throw new Error(`Delegated parent actions or running badge are misaligned: ${JSON.stringify(rowFacts)}`);
        }
        toggle.click();
        toggle.focus();
        const renamedFixture = structuredClone(window.collapseFixtureAgents);
        renamedFixture.find(agent => agent.key === "fixture-child").name = "Renamed child";
        window.collapseFixtureAgents = renamedFixture;
        state.agents = renamedFixture;
        renderAgents({ focusFilter: false });
        agentsTree = document.querySelector(`[data-agent-tree="${CSS.escape(key)}"]`);
        const restoredToggle = agentsTree?.querySelector("[data-toggle-agent-tree]");
        if (!restoredToggle || restoredToggle.getAttribute("aria-expanded") !== "true" || agentsTree.querySelector(".agent-delegation-children").hidden) {
          throw new Error("Changed agent data must not collapse an expanded delegation tree");
        }
        if (document.activeElement !== restoredToggle) throw new Error("Changed agent data must restore focus to the disclosure");
        if (!agentsTree.querySelector('[data-open-agent="fixture-child"] .row-title strong')?.textContent.includes("Renamed child")) {
          throw new Error("Changed child data must appear after the tree rerender");
        }
        state.agentSort = "project_asc";
        state.bulkArchiveMode = true;
        state.bulkArchiveSelection.clear();
        renderAgents({ focusFilter: false });
        let bulkTree = document.querySelector(`[data-agent-tree="${CSS.escape(key)}"]`);
        const bulkToggle = bulkTree?.querySelector("[data-toggle-agent-tree]");
        if (bulkTree?.querySelectorAll("[data-select-agent]").length < 2 || !bulkToggle) {
          throw new Error("Project ascending bulk mode must keep parent and child selection controls");
        }
        const originalRender = render;
        render = () => renderAgents({ focusFilter: false });
        try {
          bulkToggle.click();
          bulkTree.querySelector('[data-select-agent="fixture-child"]').click();
          document.querySelector(`[data-agent-tree="${CSS.escape(key)}"] [data-select-agent="${CSS.escape(key)}"]`).click();
        } finally {
          render = originalRender;
        }
        bulkTree = document.querySelector(`[data-agent-tree="${CSS.escape(key)}"]`);
        if (!state.bulkArchiveSelection.has(key) || !state.bulkArchiveSelection.has("fixture-child") ||
            !bulkTree.querySelector('[data-select-agent="fixture-child"]').checked ||
            !bulkTree.querySelector(`[data-select-agent="${CSS.escape(key)}"]`).checked) {
          throw new Error("Bulk parent and delegated child selections must persist across rerender");
        }
        state.bulkArchiveMode = false;
        state.bulkArchiveSelection.clear();
        state.expandedAgentTreeKeys.delete(key);
        state.agentSort = "relevancy";
        state.route = { type: "tab", tab: "agents" };
        renderAgents({ focusFilter: false });
        agentsTree = document.querySelector(`[data-agent-tree="${CSS.escape(key)}"]`);
        const agentsScreenshot = agentsTree.outerHTML;
        state.route = { type: "tab", tab: "now" };
        renderNow();
        const nowTree = document.querySelector(`[data-agent-tree="${CSS.escape(key)}"]`);
        if (!nowTree || !nowTree.querySelector(".agent-status-icon.running") || nowTree.querySelector(".delegated-running-count")?.textContent.trim() !== "1") {
          throw new Error(`Now list did not show delegated running parent and count: root=${key}, root delegation=${JSON.stringify(findAgent(key)?.delegation)}, child=${JSON.stringify(findAgent("fixture-child")?.delegation)}, html=${document.querySelector("#view")?.innerHTML.slice(0, 1800)}`);
        }
        const orphanRow = document.querySelector('[data-open-agent="fixture-orphan"]');
        if (!orphanRow) throw new Error("Now must show a running delegated agent when its parent is missing");
        return { agentsScreenshot, nowScreenshot: nowTree.outerHTML };
      };
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
    const listFixture = await page.evaluate(() => window.renderDelegatedListFixtures());
    if (captureDir) {
      await page.evaluate(() => { state.route = { type: "tab", tab: "agents" }; renderAgents({ focusFilter: false }); });
      await page.screenshot({ path: path.join(captureDir, `${device}-delegated-parent-agents.png`), fullPage: true });
      await page.evaluate(() => { state.route = { type: "tab", tab: "now" }; renderNow(); });
      await page.screenshot({ path: path.join(captureDir, `${device}-delegated-parent-now.png`), fullPage: true });
    }
    await page.evaluate(key => {
      const original = structuredClone(findAgent(key));
      state.agents = [original];
      state.agentDetails = { [key]: original };
      state.filters.agents = "";
      state.agentSort = "relevancy";
      closeUnreadPanel();
      renderNow();
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
      const searchFocus = () => keyboardSearch.evaluate(input => {
        const box = input.closest(".search-box");
        const outer = getComputedStyle(box);
        const inner = getComputedStyle(input);
        const bounds = box.getBoundingClientRect();
        const icon = box.querySelector(".nav-mark").getBoundingClientRect();
        return { width: parseFloat(outer.outlineWidth), style: outer.outlineStyle,
          color: outer.outlineColor, innerWidth: parseFloat(inner.outlineWidth),
          bounds: { x: bounds.x, y: bounds.y, width: bounds.width, height: bounds.height },
          includesIcon: icon.left >= bounds.left && icon.right <= bounds.right,
          overflow: document.documentElement.scrollWidth > innerWidth };
      });
      const assertSearchFocus = async () => {
        const facts = await searchFocus();
        assert(facts.width >= 2 && facts.style === "solid" && facts.color !== "rgba(0, 0, 0, 0)", "search container needs one visible focus cue");
        assert.equal(facts.innerWidth, 0, "search input must not have a duplicate outline");
        assert.equal(facts.includesIcon, true, "outer focus cue must include search icon");
        assert.equal(facts.overflow, false);
        return facts;
      };
      const keyboardFocus = await assertSearchFocus();
      if (captureDir) await page.screenshot({ path: path.join(captureDir, `${device}-${theme}-search-focus.png`) });
      await page.keyboard.press("Shift+Tab");
      const blurred = await searchFocus();
      assert(blurred.width === 0 || blurred.style === "none", `container cue must disappear after focus leaves: ${JSON.stringify(blurred)}`);
      assert.equal(blurred.bounds.x, keyboardFocus.bounds.x, "focus must not change horizontal layout");
      assert.equal(blurred.bounds.width, keyboardFocus.bounds.width, "focus must not change search width");
      assert.equal(blurred.bounds.height, keyboardFocus.bounds.height, "focus must not change search height");
      await keyboardSearch.click();
      await assertSearchFocus();
      await page.mouse.move(0, 0);
      await page.keyboard.press("Escape");
      await page.keyboard.press("Control+k");
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
