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
        const ref = (key, name, extra = {}) => ({ key, agent_key: key, name, server_key: "local", project_key: "web", state: "active", connected: true, status: "succeeded", ...extra });
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
        window.linkedFixtureAgents = refs.filter(ref => ref.state === "active").map(reference => ({ ...reference, archived: false, running: reference.status === "running", delegation: { parent: { key: owner.key, owner: reference.owner } } }));
        state.agents.push(...structuredClone(window.linkedFixtureAgents));
        state.agentDetails[key] = owner;
        window.linkedFixtureDelegation = owner.delegation;
        window.updateLinkedFixtureReference = (childKey, changes) => {
          const delegation = structuredClone(window.linkedFixtureDelegation);
          const reference = delegation.children.find(candidate => candidate.key === childKey);
          Object.assign(reference, changes);
          window.linkedFixtureDelegation = delegation;
          const agent = window.linkedFixtureAgents.find(candidate => candidate.key === childKey);
          if (agent && Object.prototype.hasOwnProperty.call(changes, "archived")) agent.archived = changes.archived;
        };
        state.renderedViewHtml = "";
        render();
      };
      window.installLongLinkedFixture = () => {
        const owner = structuredClone(window.linkedFixtureOwner);
        const refs = Array.from({ length: 12 }, (_, index) => ({
          key: `fixture-long-${index}`,
          agent_key: `fixture-long-${index}`,
          name: `Long list child ${index + 1}`,
          server_key: "local",
          state: "active",
          connected: true,
          status: "idle",
        }));
        owner.delegation = { children: refs };
        window.linkedFixtureDelegation = owner.delegation;
        window.linkedFixtureAgents = refs.map(reference => ({
          ...reference,
          archived: false,
          delegation: { parent: { key: owner.key, owner: "agent" } },
        }));
        state.agents = state.agents.filter(agent => !agent.key.startsWith("fixture-"));
        state.agents.push(...structuredClone(window.linkedFixtureAgents));
        state.agentDetails[owner.key] = owner;
        state.renderedViewHtml = "";
        render();
      };
      window.installLinkedFixture();
      const originalFindAgent = findAgent;
      findAgent = lookupKey => originalFindAgent(lookupKey) || window.linkedFixtureAgents.find(agent => agent.key === lookupKey) || null;
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
        window.currentLinkedToggleRenderer = renderLinkedAgentsToggle;
        const start = source.indexOf("function renderLinkedAgentsFlyout(");
        const end = source.indexOf("\nfunction renderLinkedAgentsToggle", start);
        renderLinkedAgentsFlyout = new Function(`return (${source.slice(start, end)})`)();
        const toggleStart = source.indexOf("function renderLinkedAgentsToggle(");
        const toggleEnd = source.indexOf("\nfunction renderAttachmentToggle", toggleStart);
        renderLinkedAgentsToggle = new Function(`return (${source.slice(toggleStart, toggleEnd)})`)();
        window.TychoAppearance.setPreference("dark");
        state.renderedViewHtml = ""; render();
      }, baselineSource);
      await page.locator("[data-toggle-linked-agents]").click();
      assert.equal(await page.locator(".linked-agents-count").innerText(), "6", "baseline badge counts every linked agent");
      await page.screenshot({ path: path.join(captureDir, `${device}-before.png`) });
      await page.keyboard.press("Escape");
      await page.evaluate(() => {
        renderLinkedAgentsFlyout = window.currentLinkedRenderer;
        renderLinkedAgentsToggle = window.currentLinkedToggleRenderer;
        state.renderedViewHtml = ""; render();
      });
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
      assert.equal(await page.locator(".linked-agents-count").innerText(), "4", "badge counts active linked agents only");
      assert.equal(await flyout.locator(".attachment-panel-header span").innerText(), "6 agents", "popover shows all linked agents");
      const summary = flyout.locator(".linked-agent-history > summary");
      assert.equal(await summary.innerText(), "Archived or disconnected (2)");
      for (const key of ["idle", "input", "running"]) assert(await flyout.locator(`[data-open-agent='fixture-${key}']`).isVisible(), `linked ${key} stays visible`);
      const selectionModeRow = await page.evaluate(() => {
        state.bulkArchiveMode = true;
        const owner = state.agentDetails[window.linkedFixtureOwner.key];
        const reference = owner.delegation.children.find(item => item.key === "fixture-idle");
        const row = renderAgentRelationshipRow(owner, reference, reference.key);
        state.bulkArchiveMode = false;
        return { row, hasNavigation: row.includes('data-open-agent="fixture-idle"') && row.includes('href="#agent/fixture-idle"'), hasCheckbox: row.includes("data-select-agent") };
      });
      assert(selectionModeRow.hasNavigation, "selection mode keeps linked-agent navigation");
      assert(!selectionModeRow.hasCheckbox, "selection mode does not replace linked-agent navigation with a checkbox");
      assert(await flyout.getByText("Unknown catalog entry", { exact: true }).isVisible());
      assert(!await flyout.getByText("Archived review", { exact: true }).isVisible());
      assert(!await flyout.getByText("Disconnected reports", { exact: true }).isVisible());
      const capture = async suffix => { if (captureDir) await page.screenshot({ path: path.join(captureDir, `${device}-${preference}-${suffix}.png`) }); };
      await summary.scrollIntoViewIfNeeded();
      await capture("closed");
      assert(await flyout.getByText("Host - Web - Online", { exact: true }).first().isVisible(), "delegated agent meta line includes host, project, and server status");
      const archivedPeerMeta = await page.evaluate(() => {
        const peer = { key: "review-peer", name: "Review Peer", local: false, status: "online" };
        state.servers = [...state.servers.filter(server => server.key !== peer.key), peer];
        const peerProject = { key: "review-peer/web", resource_key: "web", name: "Peer Project", server_key: peer.key };
        state.projects = [...state.projects.filter(project => project.key !== peerProject.key), peerProject];
        state.projectDetails[peerProject.key] = peerProject;
        const owner = state.agentDetails[window.linkedFixtureOwner.key];
        const reference = normalizeAgentReferenceResource({
          agent_key: "peer-archived",
          name: "Archived peer",
          project_key: "web",
          state: "archived",
          status: "succeeded",
          connected: true,
        }, peer);
        const row = renderAgentRelationshipRow(owner, reference, reference.key, { archived: true });
        return { projectKey: reference.project_key, correctProject: row.includes("Review Peer - Peer Project - Online"), hostProject: row.includes("Review Peer - Web - Online") };
      });
      assert.equal(archivedPeerMeta.projectKey, "review-peer/web", "peer project keys include their owning server");
      assert(archivedPeerMeta.correctProject, "archived peer rows show the peer project name");
      assert(!archivedPeerMeta.hostProject, "archived peer rows do not use the Host project name");
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
    await page.evaluate(() => window.installLinkedFixture());
    await page.locator("#prompt-input").fill("Keep this live refresh draft");
    await page.locator("[data-toggle-linked-agents]").click();
    const liveFlyout = page.locator("[data-linked-agents-flyout]");
    const liveHistory = liveFlyout.locator(".linked-agent-history > summary");
    await page.evaluate(() => { document.querySelector(".linked-agent-history").open = false; });
    const disconnectAction = liveFlyout.locator("[data-set-delegation-connection='fixture-idle']");
    await disconnectAction.focus();
    assert(await disconnectAction.evaluate(element => element === document.activeElement), "disconnect action has focus before refresh");
    await page.evaluate(() => window.updateLinkedFixtureReference("fixture-idle", { connected: false }));
    await page.evaluate(() => refresh({ force: true }));
    await page.waitForFunction(() => document.querySelector(".linked-agents-count")?.textContent === "3");
    assert.equal(await liveHistory.innerText(), "Archived or disconnected (3)", "disconnect moves the link to history during refresh");
    assert(!await liveFlyout.locator("details").evaluate(element => element.open), "disconnect keeps history closed");
    assert(!await liveFlyout.evaluate(element => element.classList.contains("hidden")), "disconnect keeps the popover open");
    assert(await liveHistory.evaluate(element => element === document.activeElement), "focus moves to visible history summary after disconnect");
    assert.equal(await page.locator("#prompt-input").inputValue(), "Keep this live refresh draft", "draft survives relationship refresh");
    const archiveAction = liveFlyout.locator("[data-set-delegation-connection='fixture-input']");
    assert.equal(await archiveAction.count(), 1, "active fixture retains its connection action in the current group");
    await archiveAction.focus();
    assert(await archiveAction.evaluate(element => element === document.activeElement), "archive action has focus before refresh");
    await page.evaluate(() => window.updateLinkedFixtureReference("fixture-input", { state: "archived", archived: true }));
    await page.evaluate(() => refresh({ force: true }));
    await page.waitForFunction(() => document.querySelector(".linked-agents-count")?.textContent === "2");
    assert.equal(await liveHistory.innerText(), "Archived or disconnected (4)", "archive moves another link to history during refresh");
    assert(!await liveFlyout.locator("details").evaluate(element => element.open), "archive keeps history closed");
    assert(!await liveFlyout.evaluate(element => element.classList.contains("hidden")), "archive keeps the popover open");
    assert.equal(await liveFlyout.locator("[data-set-delegation-connection='fixture-input']").count(), 0, "archived row has no connection action");
    assert(await liveHistory.evaluate(element => element === document.activeElement), "focus moves to visible history summary after archive");
    assert.equal(await page.locator("#prompt-input").inputValue(), "Keep this live refresh draft", "draft survives archive refresh");

    const longToggle = page.locator("[data-toggle-linked-agents]");
    await page.evaluate(() => window.installLongLinkedFixture());
    await page.locator("#prompt-input").fill("Keep the long list draft");
    await longToggle.click();
    const longFlyout = page.locator("[data-linked-agents-flyout]");
    const longHistory = longFlyout.locator(".linked-agent-history > summary");
    await longFlyout.locator(".linked-agents-flyout-list").evaluate(element => { element.scrollTop = 0; });
    const firstDisconnect = longFlyout.locator("[data-set-delegation-connection='fixture-long-0']");
    await firstDisconnect.focus();
    assert(await firstDisconnect.evaluate(element => element === document.activeElement), "long-list disconnect action starts focused");
    const disconnectPageScroll = await page.evaluate(() => window.scrollY);
    await page.evaluate(() => window.updateLinkedFixtureReference("fixture-long-0", { connected: false }));
    await page.evaluate(() => refresh({ force: true }));
    await page.waitForFunction(() => document.querySelector(".linked-agents-count")?.textContent === "11");
    assert(await longHistory.evaluate(element => element === document.activeElement), "long-list disconnect focuses the history summary");
    assert(!await longFlyout.locator("details").evaluate(element => element.open), "long-list disconnect keeps history closed");
    const disconnectGeometry = await page.evaluate(() => {
      const list = document.querySelector(".linked-agents-flyout-list");
      const summary = document.querySelector(".linked-agent-history > summary");
      const listRect = list.getBoundingClientRect();
      const summaryRect = summary.getBoundingClientRect();
      const top = listRect.top + list.clientTop;
      const bottom = top + list.clientHeight;
      return { top, bottom, summaryTop: summaryRect.top, summaryBottom: summaryRect.bottom, scrollTop: list.scrollTop, pageScroll: window.scrollY, viewportHeight: innerHeight };
    });
    assert(disconnectGeometry.summaryTop >= disconnectGeometry.top - 1 && disconnectGeometry.summaryBottom <= disconnectGeometry.bottom + 1, `disconnect fallback is inside the popover scroll area: ${JSON.stringify(disconnectGeometry)}`);
    assert(disconnectGeometry.summaryTop >= 0 && disconnectGeometry.summaryBottom <= disconnectGeometry.viewportHeight, `disconnect fallback is inside the viewport: ${JSON.stringify(disconnectGeometry)}`);
    assert(disconnectGeometry.scrollTop > 0, "disconnect scrolls the popover list to its focused fallback");
    assert.equal(disconnectGeometry.pageScroll, disconnectPageScroll, "disconnect does not scroll the page behind the popover");
    assert.equal(await page.locator("#prompt-input").inputValue(), "Keep the long list draft", "long-list disconnect keeps the draft");

    await page.evaluate(() => window.installLongLinkedFixture());
    if (await page.locator("[data-linked-agents-flyout]").evaluate(element => element.classList.contains("hidden"))) await longToggle.click();
    await longFlyout.locator(".linked-agents-flyout-list").evaluate(element => { element.scrollTop = 0; });
    const firstArchive = longFlyout.locator("[data-set-delegation-connection='fixture-long-0']");
    await firstArchive.focus();
    assert(await firstArchive.evaluate(element => element === document.activeElement), "long-list archive action starts focused");
    const archivePageScroll = await page.evaluate(() => window.scrollY);
    await page.evaluate(() => window.updateLinkedFixtureReference("fixture-long-0", { state: "archived", archived: true }));
    await page.evaluate(() => refresh({ force: true }));
    await page.waitForFunction(() => document.querySelector(".linked-agents-count")?.textContent === "11");
    assert(await longHistory.evaluate(element => element === document.activeElement), "long-list archive focuses the history summary");
    assert.equal(await longFlyout.locator("[data-set-delegation-connection='fixture-long-0']").count(), 0, "long-list archived row loses its action");
    assert(!await longFlyout.locator("details").evaluate(element => element.open), "long-list archive keeps history closed");
    const archiveGeometry = await page.evaluate(() => {
      const list = document.querySelector(".linked-agents-flyout-list");
      const summary = document.querySelector(".linked-agent-history > summary");
      const listRect = list.getBoundingClientRect();
      const summaryRect = summary.getBoundingClientRect();
      const top = listRect.top + list.clientTop;
      const bottom = top + list.clientHeight;
      return { top, bottom, summaryTop: summaryRect.top, summaryBottom: summaryRect.bottom, scrollTop: list.scrollTop, pageScroll: window.scrollY, viewportHeight: innerHeight };
    });
    assert(archiveGeometry.summaryTop >= archiveGeometry.top - 1 && archiveGeometry.summaryBottom <= archiveGeometry.bottom + 1, `archive fallback is inside the popover scroll area: ${JSON.stringify(archiveGeometry)}`);
    assert(archiveGeometry.summaryTop >= 0 && archiveGeometry.summaryBottom <= archiveGeometry.viewportHeight, `archive fallback is inside the viewport: ${JSON.stringify(archiveGeometry)}`);
    assert(archiveGeometry.scrollTop > 0, "archive scrolls the popover list to its focused fallback");
    assert.equal(archiveGeometry.pageScroll, archivePageScroll, "archive does not scroll the page behind the popover");

    await page.evaluate(() => window.installLinkedFixture("old"));
    if (await page.locator("[data-linked-agents-flyout]").evaluate(element => element.classList.contains("hidden"))) {
      await page.locator("[data-toggle-linked-agents]").click();
    }
    assert.equal(await page.locator(".linked-agents-count").innerText(), "0", "inactive-only links retain a zero-count badge control");
    const inactiveHistory = page.locator(".linked-agent-history > summary");
    assert.equal(await inactiveHistory.innerText(), "Archived or disconnected (2)");
    assert.equal(await page.locator("[data-linked-agents-flyout] .agent-relationship-row:visible .agent-row:visible").count(), 0, "inactive history starts collapsed");
    await inactiveHistory.click();
    assert.equal(await page.locator("[data-linked-agents-flyout] .agent-relationship-row:visible .agent-row:visible").count(), 2, "inactive linked agents remain visible in the expanded history");
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
