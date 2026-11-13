const assert = require("node:assert/strict");

// Two agent pairs exercise the real API/native-start path. No saved agent
// archive, live harness, or injected STARTED event is used.
module.exports = async function ({ browser, baseUrl, agentKey, metadataFixture }) {
  const page = await browser.newPage({ viewport: { width: 1440, height: 900 } });
  try {
    await page.goto(`${baseUrl}/ui#agent/${encodeURIComponent(agentKey)}`, { waitUntil: "networkidle" });
    await page.locator(".delegation-callback-result .markdown-viewer").waitFor();
    const evidence = await page.evaluate(async ({ idleParentKey, childKey, parentKey }) => {
      const conversation = async key => (await (await fetch(`/agents/${encodeURIComponent(key)}/conversation`)).json()).conversation;
      const idle = await conversation(idleParentKey);
      const active = await conversation(parentKey);
      const callback = document.querySelector(".message-list > .delegation-callback-event");
      const started = [...document.querySelectorAll(".delegation-started-event .delegation-event-header")]
        .find(header => header.querySelector(".delegation-event-brand")?.textContent === "STARTED");
      const list = document.querySelector(".message-list");
      const children = [...list.children];
      return {
        idleEvents: idle.map(block => block.metadata?.event).filter(Boolean),
        activeEvents: active.map(block => block.metadata?.event).filter(Boolean),
        startedChild: active.find(block => block.metadata?.event === "agent_started")?.metadata.agent_reference.agent_key,
        expectedChild: childKey,
        startedHeader: started?.innerText || "",
        firstHeader: document.querySelector(".delegation-event-header")?.innerText || "",
        startedIndex: children.indexOf(started?.closest(".delegation-started-event")),
        callbackIndex: children.indexOf(callback),
        callbackLabel: callback?.querySelector(".delegation-event-brand")?.textContent,
        result: callback?.querySelector(".delegation-callback-result")?.innerText || "",
        rightDelta: Math.abs(callback.getBoundingClientRect().right - list.getBoundingClientRect().right),
      };
    }, { idleParentKey: metadataFixture.idle_parent_key, childKey: metadataFixture.child_key, parentKey: agentKey });
    assert(evidence.idleEvents.includes("agent_message_sent"), "idle parent must retain its accepted send");
    assert(!evidence.idleEvents.includes("agent_started"), "idle parent must not claim an active-run start");
    assert(evidence.activeEvents.includes("agent_started"), "running parent must retain its child's native start");
    assert.equal(evidence.startedChild, evidence.expectedChild);
    assert(evidence.firstHeader.startsWith("SENT"), "fixture must retain the send before STARTED");
    assert(evidence.startedHeader.includes("STARTED"));
    assert(!evidence.startedHeader.includes("Started agent") && !evidence.startedHeader.includes("TYCHO"));
    assert(evidence.startedIndex >= 0 && evidence.callbackIndex > evidence.startedIndex);
    assert.equal(evidence.callbackLabel, "DELEGATED AGENT");
    assert(evidence.result.includes("Completed the focused review") && evidence.result.includes("Preserved safe Markdown rendering."));
    assert(evidence.rightDelta <= 1, "callback must keep user-message alignment");
    console.log("delegation start evidence: " + JSON.stringify(evidence));

    await page.setViewportSize({ width: 390, height: 844 });
    for (const align of ["start", "center"]) {
      const box = await page.evaluate(align => {
        const callback = document.querySelector(".message-list > .delegation-callback-event");
        const pane = document.querySelector("[data-agent-conversation-scroll]");
        callback.scrollIntoView({ block: align });
        if (align === "start") pane.scrollTop = Math.max(0, pane.scrollTop - 12);
        const rect = callback.getBoundingClientRect();
        const header = document.querySelector(".app-header").getBoundingClientRect();
        const dock = document.querySelector("[data-agent-dock]").getBoundingClientRect();
        return { align, left: rect.left, right: rect.right, top: rect.top, bottom: rect.bottom,
          viewportWidth: innerWidth, headerBottom: header.bottom, dockTop: dock.top,
          documentScroll: document.scrollingElement.scrollTop, paneScroll: pane.scrollTop,
          paneOverflow: getComputedStyle(pane).overflowY };
      }, align);
      console.log("delegation mobile evidence: " + JSON.stringify(box));
      // Start alignment reproduces the old setup error. The real clearance
      // contract is unchanged after placing the card in the visible viewport.
      if (align === "center") {
        assert(box.left > 0 && box.right <= box.viewportWidth, "callback must fit mobile width");
        assert(box.top >= box.headerBottom && box.bottom <= box.dockTop, "callback must clear header and composer");
      }
    }
    console.log("delegation_fixture_smoke: ok");
    if (process.env.TYCHO_REMOTE_UI_GROUP_GEOMETRY_PROBE === "1") {
      await page.goto(`${baseUrl}/ui#agents`, { waitUntil: "networkidle" });
      const geometry = await page.evaluate(() => {
        state.agentSort = "project_asc";
        state.filters.agents = "";
        render();
        return [...document.querySelectorAll(".agent-ledger .agent-row")].map(row => ({
          height: row.getBoundingClientRect().height,
          borderBottom: getComputedStyle(row).borderBottomWidth,
        }));
      });
      console.log("grouped row geometry evidence: " + JSON.stringify(geometry));
      assert(geometry.length > 1, "geometry probe needs at least two synthetic rows");
      assert(geometry.every(row => row.height <= 58.5), "Grouped Agents rows exceed the existing 58.5 px contract");
    }
  } finally {
    await page.close();
  }
};
