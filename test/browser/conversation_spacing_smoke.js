const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const { execFileSync } = require("node:child_process");

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
        { id: "first-user", kind: "message", role: "user", content: "First user: no extra top gap." },
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
    state.conversations[key].blocks.push(
      { id: "parent", kind: "message", role: "user", content: "Please check the trial.", metadata: { message_author: { type: "agent", agent_key: "synthetic-parent", name: "Parent agent" } } },
      { id: "answers", kind: "message", role: "user", content: '{"placement":"before"}', metadata: { inquiry_response: true } },
      { id: "tool-before-user", kind: "tool_call", tool_name: "exec", content: "Checked the boundaries." },
      { id: "callback", kind: "message", role: "user", content: "Delegated result", metadata: { delegation_callback: true, delegation_report: { summary: "The synthetic check passed.", child: { name: "Fixture agent" } } } },
      { id: "pending", kind: "message", role: "user", content: "Pending user prompt.", pending: true },
      { id: "reply", kind: "message", role: "assistant", content: "Reply after pending status." },
      { id: "reply-2", kind: "message", role: "assistant", content: "Adjacent assistant reply." },
      { id: "read", kind: "message", role: "user", content: "Read queue fixture", metadata: { queue_read: true } },
      { id: "last-user", kind: "message", role: "user", content: "User after Read queue." }
    );
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
      firstOffset: rect(children[0]).top - rect(list).top,
      classes: children.map(element => element.className),
      expected: children.slice(1).map((element, index) => element.matches(".message-send-status") ? 4 : element.matches(".message.user") ? 64 : element.matches(".message") && children[index].matches(".message") ? 24 : 8),
      boundaries: children.slice(1).map((element, index) => rect(element).top - rect(children[index]).bottom),
      headers: children.filter(element => element.matches(".message")).map(element => rect(element.querySelector(".message-content")).top - rect(element.querySelector(".message-header")).bottom),
      activity: [...list.querySelectorAll(".message-group")].map(group => ({
        queueRead: group.classList.contains("queue-read-block"),
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

async function captureBoundary(page, captureDir, label) {
  if (!captureDir) return;
  await page.locator('[data-run-summary-id="summary-18"]').scrollIntoViewIfNeeded();
  await page.evaluate(() => {
    const summary = document.querySelector('[data-run-summary-id="summary-18"]');
    const pane = document.querySelector('[data-agent-conversation-scroll]');
    if (pane.scrollHeight > pane.clientHeight) {
      pane.scrollTop += summary.getBoundingClientRect().top - pane.getBoundingClientRect().top - 90;
    } else {
      window.scrollBy(0, summary.getBoundingClientRect().top - 100);
    }
  });
  await page.screenshot({ path: path.join(captureDir, `${label}-context.png`) });
  const clip = await page.evaluate(() => {
    const summary = document.querySelector('[data-run-summary-id="summary-18"]');
    const user = summary.nextElementSibling;
    const a = summary.getBoundingClientRect(), b = user.getBoundingClientRect();
    const y = Math.max(0, a.bottom - 70);
    return { x: Math.max(0, a.x), y, width: Math.min(Math.max(a.right, b.right), innerWidth) - Math.max(0, Math.min(a.x, b.x)), height: Math.min(innerHeight - y, b.bottom - y) };
  });
  await page.screenshot({ path: path.join(captureDir, `${label}-boundary.png`), clip });
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
      assert.deepEqual(selected.boundaries, selected.expected);
      assert.equal(selected.firstOffset, 0);
      assert(selected.headers.every(gap => gap === 8));
      for (const name of ["parent-agent-message", "inquiry-response", "delegation-callback-event", "pending", "queue-read-block", "message-send-status"]) assert(selected.classes.some(value => value.split(" ").includes(name)), name);
      assert.equal(selected.padding, "64px");
      assert.equal(selected.dockGap, "8px");
      assert.equal(selected.overflow, false);
      assert.equal(selected.fontLoaded, true);
      if (open) {
        for (const group of selected.activity) {
          assert.equal(group.summaryPadding, "9px 12px");
          assert.equal(group.summaryGap, viewport.width === 390 ? "2px" : "10px");
          assert.equal(group.bodyPadding, group.queueRead ? "10px 12px 12px" : "4px 0px 0px");
          assert(group.boundaries.every(gap => gap === 0));
          group.entries.forEach((entry, index) => {
            assert.equal(entry.padding, "8px 12px");
            assert.equal(entry.margin, "0px");
            assert.equal(entry.gap, "5px");
            assert.equal(entry.headerGap, 5);
            assert.equal(entry.border, index === 0 ? "0px" : "1px");
          });
        }
      }
      // Serve the actual committed base stylesheet, with the same fixture and fonts.
      const baselineCss = execFileSync("git", ["show", "1f20166:lib/hq/remote_ui/assets/design_system.css"], { cwd: path.resolve(__dirname, "../.."), encoding: "utf8" }) + "\n" + execFileSync("git", ["show", "1f20166:lib/hq/remote_ui/assets/app.css"], { cwd: path.resolve(__dirname, "../.."), encoding: "utf8" });
      await page.evaluate(() => { document.querySelectorAll('link[rel="stylesheet"]').forEach(link => { link.disabled = true; }); });
      const baselineStyle = await page.addStyleTag({ content: baselineCss });
      const baseline = await measure(page);
      assert.deepEqual(selected.activity, baseline.activity);
      baseline.boundaries.forEach((gap, index) => assert.equal(gap, selected.classes[index + 1] === "message-send-status" ? 4 : selected.classes[index + 1].split(" ").includes("message") && selected.classes[index].split(" ").includes("message") ? 24 : 8));
      assert.equal(selected.height - baseline.height, selected.boundaries.reduce((sum, gap, index) => sum + gap - baseline.boundaries[index], 0));
      await page.evaluate(() => { document.querySelector("[data-agent-conversation-scroll]").scrollTop = 0; window.scrollTo(0, 0); });
      await captureBoundary(page, captureDir, `before-${viewport.width}-${open ? "expanded" : "collapsed"}`);
      await baselineStyle.evaluate(element => element.remove());
      await page.evaluate(() => { document.querySelectorAll('link[rel="stylesheet"]').forEach(link => { link.disabled = false; }); });
      await page.evaluate(() => { document.querySelector("[data-agent-conversation-scroll]").scrollTop = 0; window.scrollTo(0, 0); });
      await captureBoundary(page, captureDir, `after-${viewport.width}-${open ? "expanded" : "collapsed"}`);
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
    await page.locator("#prompt-input").fill("Keep this draft during polling.");
    const pollBefore = await page.evaluate(() => ({ scroll: document.querySelector("[data-agent-conversation-scroll]").scrollTop, windowScroll: scrollY, open: [...document.querySelectorAll(".message-group")].map(group => group.open) }));
    await page.evaluate(async () => { await refresh({ force: true }); });
    const pollAfter = await page.evaluate(() => ({ scroll: document.querySelector("[data-agent-conversation-scroll]").scrollTop, windowScroll: scrollY, open: [...document.querySelectorAll(".message-group")].map(group => group.open) }));
    assert.deepEqual(pollAfter, pollBefore);
    assert.equal(await page.locator("#prompt-input").evaluate(element => element === document.activeElement), true);
    assert.equal(await page.locator("#prompt-input").inputValue(), "Keep this draft during polling.");
    const settled = await page.evaluate(key => {
      const pending = state.conversations[key].blocks.find(block => block.id === "pending");
      if (!pending) return null;
      const list = document.querySelector(".message-list");
      const before = list.querySelector(".message.pending").offsetTop;
      pending.pending = false;
      state.renderedViewHtml = "";
      render({ preserveLiveEditor: true });
      const messages = [...document.querySelectorAll(".message-list > .message.user")];
      const message = messages.find(element => element.textContent.includes("Pending user prompt."));
      return { before, after: message.offsetTop, status: Boolean(document.querySelector(".message-send-status")) };
    }, agentKey);
    assert(settled, "fixture must survive polling");
    assert.equal(settled.before, settled.after);
    assert.equal(settled.status, false);
    const finalGeometry = await measure(page);
    assert.deepEqual(finalGeometry.boundaries, finalGeometry.expected);
    assert.deepEqual(errors, []);
    results.push({ viewport, modes });
    await page.close();
  }
  if (captureDir) fs.writeFileSync(path.join(captureDir, "geometry.json"), JSON.stringify(results, null, 2));
  console.log("conversation spacing: passed desktop/mobile collapsed/expanded geometry, activity invariants, polling/draft/focus/scroll preservation, pending settlement, overflow, end scroll, and control hit checks");
};
