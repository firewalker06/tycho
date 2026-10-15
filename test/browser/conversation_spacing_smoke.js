const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");

// Same synthetic conversation used for the approved card 319 comparison.
async function installFixture(page, baseUrl, agentKey) {
  await page.goto(`${baseUrl}/ui#agent/${encodeURIComponent(agentKey)}`, { waitUntil: "networkidle" });
  await page.waitForSelector("#prompt-input", { state: "visible", timeout: 10000 });
  await page.evaluate((key) => {
    const agent = findAgent(key);
    agent.run_count = 18;
    agent.status = "idle";
    agent.running = false;
    agent.summary = "Public synthetic spacing fixture";
    state.conversations[key] = {
      loaded: true,
      loading: false,
      revision: "card-319-spacing-fixture",
      blocks: [
        {
          id: "assistant-1",
          kind: "message",
          role: "assistant",
          created_at: "2026-10-15T01:00:00Z",
          content: "Cleanup is complete. Alpha, Beta, and Charlie are clean on `main` and match `origin/main`. All completed task and cleanup agents are archived.\n\n[Card #317: Push notifications opening an empty conversation](https://example.test/cards/317) remains in the backlog. Implementation has not started.",
        },
        { id: "tool-1", kind: "tool_call", tool_name: "exec", content: "Checked workspace status.", created_at: "2026-10-15T01:00:01Z" },
        { id: "tool-2", kind: "tool_result", tool_name: "exec", content: "All workspaces are clean.", created_at: "2026-10-15T01:00:02Z" },
        {
          id: "summary-18",
          kind: "run_summary",
          created_at: "2026-10-15T01:00:03Z",
          content: "Cleanup is complete. Alpha, Beta, and Charlie are clean on `main` and match `origin/main`. All completed task and cleanup agents are archived. Card #317 remains in the backlog.",
          metadata: { summary_id: "summary-18", run_number: 18, status: "success" },
        },
        { id: "user-1", kind: "message", role: "user", created_at: "2026-10-15T01:20:00Z", content: "Start fixing that." },
        {
          id: "assistant-2",
          kind: "message",
          role: "assistant",
          created_at: "2026-10-15T01:20:01Z",
          content: "I will start card #317 in Alpha. I will use the Tycho and Fizzy skills to assign the task. The implementation agent will reproduce the notification-click fault and follow the Diagnose skill before making a fix.",
        },
        { id: "tool-3", kind: "tool_call", tool_name: "exec", content: "Started the isolated check.", created_at: "2026-10-15T01:20:02Z" },
        { id: "tool-4", kind: "tool_result", tool_name: "exec", content: "The isolated fixture is ready.", created_at: "2026-10-15T01:20:03Z" },
        {
          id: "assistant-3",
          kind: "message",
          role: "assistant",
          created_at: "2026-10-15T01:20:04Z",
          content: "Which browser or installed PWA shows the empty conversation, and which Tycho server does the notification come from? I will continue the local reproduction while you reply.",
        },
      ],
    };
    history.replaceState(null, "", routeHash({ type: "agent", key }));
    state.renderedRouteKey = null;
    state.renderedViewHtml = "";
    render();
  }, agentKey);
  await page.waitForSelector(".message-list > .message", { state: "visible", timeout: 10000 });
  await page.evaluate(async () => {
    if (markdownParser.promise) await markdownParser.promise;
    await Promise.all([
      document.fonts.load('400 16px "Plus Jakarta Sans"'),
      document.fonts.load('600 16px "Plus Jakarta Sans"'),
      document.fonts.load('750 16px "Plus Jakarta Sans"'),
    ]);
    await document.fonts.ready;
    state.renderedRouteKey = null;
    state.renderedViewHtml = "";
    render();
  });
  await page.waitForSelector(".message-list > .message-markdown-viewer, .message-list .message-markdown-viewer", { state: "visible", timeout: 10000 });
}

async function measure(page) {
  return page.evaluate(() => {
    const list = document.querySelector(".message-list");
    const children = [...list.children];
    const rect = (element) => element.getBoundingClientRect();
    const style = (element) => getComputedStyle(element);
    const pane = document.querySelector("[data-agent-conversation-scroll]");
    const dock = document.querySelector("[data-agent-dock]");
    return {
      height: rect(list).height,
      boundaries: children.slice(1).map((element, index) => rect(element).top - rect(children[index]).bottom),
      headers: children.filter(element => element.matches(".message")).map(element => rect(element.querySelector(".message-content")).top - rect(element.querySelector(".message-header")).bottom),
      activity: [...list.querySelectorAll(".message-group")].map(group => ({
        summaryPadding: style(group.querySelector("summary")).padding,
        summaryGap: style(group.querySelector("summary")).gap,
        bodyPadding: style(group.querySelector(".message-group-body")).padding,
        entries: [...group.querySelectorAll(".message")].map(element => ({
          padding: style(element).padding, border: style(element).borderTopWidth,
          margin: style(element).margin, gap: style(element).gap,
          headerGap: rect(element.querySelector(".message-content")).top - rect(element.querySelector(".message-header")).bottom,
        })),
        boundaries: [...group.querySelectorAll(".message")].slice(1).map((element, index) => rect(element).top - rect(group.querySelectorAll(".message")[index]).bottom),
      })),
      padding: style(pane).paddingBottom,
      dockGap: style(dock).gap,
      overflow: [document.documentElement, pane, list, ...list.querySelectorAll(".message-content")].some(element => element.scrollWidth > element.clientWidth),
      fontLoaded: document.fonts.check('400 16px "Plus Jakarta Sans"'),
    };
  });
}

module.exports = async function ({ browser, baseUrl, agentKey, captureDir }) {
  const results = [];
  for (const viewport of [{ width: 1060, height: 737 }, { width: 390, height: 844 }]) {
    const page = await browser.newPage({ viewport, deviceScaleFactor: 1 });
    const errors = [];
    page.on("pageerror", error => errors.push(error.message));
    page.on("console", message => { if (message.type() === "error") errors.push(message.text()); });
    await installFixture(page, baseUrl, agentKey);
    // Stop polling and animation equally for stable geometry, not a polling test.
    await page.evaluate(() => { const last = setInterval(() => {}, 999999); for (let id = 1; id <= last; id++) clearInterval(id); });
    await page.addStyleTag({ content: "* { scroll-behavior:auto!important; animation:none!important; transition:none!important; }" });
    const modes = [];
    for (const open of [false, true]) {
      await page.evaluate(open => document.querySelectorAll(".message-group").forEach(group => { group.open = open; }), open);
      const selected = await measure(page);
      assert.deepEqual(selected.boundaries, [8, 8, 24, 24, 8, 8]);
      assert.deepEqual(selected.headers, [8, 8, 8, 8, 8]);
      assert.equal(selected.padding, "64px");
      assert.equal(selected.dockGap, "8px");
      assert.equal(selected.overflow, false);
      assert.equal(selected.fontLoaded, true);
      if (open) {
        for (const group of selected.activity) {
          assert.equal(group.summaryPadding, "9px 12px");
          assert.equal(group.summaryGap, viewport.width === 390 ? "2px" : "10px");
          assert.equal(group.bodyPadding, "4px 0px 0px");
          assert.deepEqual(group.boundaries, [0]);
          group.entries.forEach((entry, index) => {
            assert.equal(entry.padding, "8px 12px");
            assert.equal(entry.margin, "0px");
            assert.equal(entry.gap, "5px");
            assert.equal(entry.headerGap, 5);
            assert.equal(entry.border, index === 0 ? "0px" : "1px");
          });
        }
      }
      // Recreate only the old two spacing rules to compare all activity styles.
      const baselineStyle = await page.addStyleTag({ content: ".message-list > .message { gap:5px!important; } .message-list > .message + .message { margin-top:0!important; }" });
      const baseline = await measure(page);
      assert.deepEqual(selected.activity, baseline.activity);
      assert.equal(selected.height - baseline.height, 47);
      await baselineStyle.evaluate(element => element.remove());
      await page.evaluate(() => { document.querySelector("[data-agent-conversation-scroll]").scrollTop = 0; window.scrollTo(0, 0); });
      if (captureDir) await page.screenshot({ path: path.join(captureDir, `selected-${viewport.width}-${open ? "expanded" : "collapsed"}.png`) });
      await page.evaluate(() => {
        const pane = document.querySelector("[data-agent-conversation-scroll]");
        pane.scrollTop = pane.scrollHeight;
        window.scrollTo(0, document.documentElement.scrollHeight);
      });
      await page.evaluate(() => new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve))));
      const end = await page.evaluate(() => {
        const last = document.querySelector(".message-list").lastElementChild.getBoundingClientRect();
        const dock = document.querySelector("[data-agent-dock]");
        const pane = document.querySelector("[data-agent-conversation-scroll]");
        return {
          lastTop: last.top, lastBottom: last.bottom, dockTop: dock.getBoundingClientRect().top,
          scrollY, paneScrollTop: pane.scrollTop,
          controls: [...dock.querySelectorAll("button,textarea")].filter(element => element.offsetParent).map(element => {
            const box = element.getBoundingClientRect();
            const target = document.elementFromPoint(box.x + box.width / 2, box.y + box.height / 2);
            return { width: box.width, height: box.height, inside: box.x >= 0 && box.y >= 0 && box.right <= innerWidth && box.bottom <= innerHeight, hit: target === element || element.contains(target) };
          }),
        };
      });
      assert(end.lastTop >= 0 && end.lastBottom <= end.dockTop, "last turn must fit above the dock after pane and document scroll");
      assert(end.controls.length > 0 && end.controls.every(control => control.inside && control.hit));
      if (captureDir) await page.screenshot({ path: path.join(captureDir, `selected-${viewport.width}-${open ? "expanded" : "collapsed"}-end.png`) });
      modes.push({ open, selected, baseline, end });
    }
    assert.deepEqual(errors, []);
    results.push({ viewport, modes });
    await page.close();
  }
  if (captureDir) fs.writeFileSync(path.join(captureDir, "geometry.json"), JSON.stringify(results, null, 2));
  console.log("conversation spacing: passed desktop/mobile collapsed/expanded geometry, activity invariants, overflow, end scroll, and control hit checks");
};
