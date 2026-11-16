const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");

module.exports = async ({ browser, baseUrl, agentKey, captureDir }) => {
  const request = await browser.newContext();
  const focusUrl = `${baseUrl}/agents/${agentKey}/focus`;
  const current = await (await request.request.get(focusUrl)).json();
  const saved = await request.request.put(focusUrl, { data: { revision: current.focus.revision,
    sections: [{ title: "Review work", items: [{ title: "Review the Side Conversation layout", subtitle: "Synthetic browser evidence" }] }] } });
  assert(saved.ok(), await saved.text());
  const upload = await request.request.post(`${baseUrl}/agents/${agentKey}/messages`, { data: {
    prompt: "Keep this synthetic attachment for panel checks.", start: false,
    attachments: [{ filename: "side-panel-notes.md", title: "Panel notes", content_type: "text/markdown", content_base64: Buffer.from("# Panel notes\n\nAttachment preview remains available.").toString("base64") }],
  } });
  assert(upload.ok(), await upload.text());
  const detail = await (await request.request.get(`${baseUrl}/agents/${agentKey}`)).json();
  const attachment = detail.agent.attachments.find(item => item.title === "Panel notes");
  assert(attachment);
  for (const width of [1800, 1440, 1024, 390]) for (const theme of ["dark", "light"]) {
    const context = await browser.newContext({ viewport: { width, height: 900 }, isMobile: width < 500, hasTouch: width < 500 });
    const page = await context.newPage();
    const errors = [];
    page.on("pageerror", error => errors.push(error.message));
    const frames = () => page.evaluate(() => new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve))));
    const toggle = kind => page.locator(`.side-conversation-controls [data-side-conversation="${kind}"]`);
    const active = async kinds => {
      await page.waitForFunction(open => ["focus", "summary", "pull-requests"].every(kind =>
        document.querySelector(`.side-conversation-controls [data-side-conversation="${kind}"]`)?.getAttribute("aria-pressed") === String(open.includes(kind))), kinds);
      for (const kind of ["focus", "summary", "pull-requests"]) {
        assert.equal(await toggle(kind).isVisible(), true, `${kind} toggle visible at ${width}`);
        assert.equal(await toggle(kind).getAttribute("aria-pressed"), String(kinds.includes(kind)), `${kind} active state`);
      }
    };
    const capture = async name => {
      if (!captureDir) return;
      fs.mkdirSync(captureDir, { recursive: true });
      await page.screenshot({ path: path.join(captureDir, `side-conversations-${name}-${theme}-${width}.png`) });
    };
    await page.goto(`${baseUrl}/ui#settings`, { waitUntil: "networkidle" });
    await page.locator("[data-appearance-preference]").selectOption(theme);
    await page.goto(`${baseUrl}/ui#agent/${agentKey}/summary`, { waitUntil: "networkidle" });
    await page.locator("[data-side-workspace]").waitFor();
    await active(["summary"]);
    if (width >= 1440) {
      const initialWidth = await page.locator('[data-side-kind="summary"]').evaluate(e => e.clientWidth);
      await page.evaluate(key => setAgentDetailViewMode(`${key}:summary`, "wide"), agentKey);
      await frames();
      assert(await page.locator('[data-side-kind="summary"]').evaluate(e => e.clientWidth) > initialWidth, "Wide detail view must increase the Summary width");
      await page.evaluate(key => setAgentDetailViewMode(`${key}:summary`, "full"), agentKey);
      assert.equal(await page.locator(".agent-conversation-pane").isVisible(), false, "Full view hides Conversation");
      await page.evaluate(key => setAgentDetailViewMode(`${key}:summary`, "balanced"), agentKey);
      assert.equal(await page.locator(".agent-conversation-pane").isVisible(), true);
    }
    await toggle("focus").click();
    await frames();
    await active(["summary", "focus"]);
    await page.locator('[data-side-kind="focus"]').waitFor({ state: "visible" });
    const geometry = await page.evaluate(() => {
      const box = selector => { const e = document.querySelector(selector); const r = e.getBoundingClientRect(); return { x: r.x, right: r.right, top: r.top, bottom: r.bottom, width: r.width, visible: !!e.getClientRects().length && getComputedStyle(e).display !== "none" }; };
      return { conversation: box(".agent-conversation-pane"), summary: box('[data-side-kind="summary"]'), focus: box('[data-side-kind="focus"]'), overflow: document.documentElement.scrollWidth > innerWidth };
    });
    assert.equal(geometry.overflow, false, JSON.stringify(geometry));
    if (width >= 1440) {
      assert(geometry.conversation.visible && geometry.summary.visible && geometry.focus.visible, JSON.stringify(geometry));
      assert(geometry.conversation.right <= geometry.summary.x && geometry.summary.right <= geometry.focus.x, JSON.stringify(geometry));
    } else assert.equal(geometry.summary.visible, false, "newest side stays visible at narrow widths");
    await capture("summary-focus");
    if (width >= 1440) {
      await page.evaluate(({ id, key }) => openSummaryAttachmentPreview(id, key), { id: attachment.id, key: agentKey });
      await page.locator(".summary-attachment-preview-pane").waitFor({ state: "visible" });
      await active(["summary", "focus"]);
      await page.locator("[data-close-summary-attachment-preview]").click();
      await page.locator("[data-side-workspace]").waitFor();
      await active(["summary", "focus"]);
      await toggle("focus").focus();
      await page.setViewportSize({ width: 390, height: 900 });
      await frames();
      await active(["summary", "focus"]);
      assert.equal(await page.evaluate(() => document.activeElement?.dataset.sideConversation), "focus", "switcher focus must survive responsive relocation");
      await page.setViewportSize({ width, height: 900 });
      await frames();
    }
    await page.evaluate(() => refresh({ force: true }));
    await frames();
    await active(["summary", "focus"]);
    await toggle("pull-requests").click();
    await page.locator('[data-side-kind="pull-requests"]').waitFor({ state: "visible" });
    await active(["focus", "pull-requests"]);
    await capture("focus-pr");
    await toggle("focus").click();
    await active(["pull-requests"]);
    await toggle("summary").click();
    await active(["summary", "pull-requests"]);
    await page.evaluate(() => refresh({ force: true }));
    await frames();
    await active(["summary", "pull-requests"]);
    await page.evaluate(() => refresh({ force: true, preserveFocusedWorkspace: true }));
    await active(["summary", "pull-requests"]);
    assert.equal(await page.locator(".agent-floating-actions [data-open-agent-summary]").count(), 0, "polling must keep the shared switcher");
    await capture("pr-summary");
    if (width === 390) {
      await toggle("conversation").click();
      await page.locator("#prompt-input").waitFor({ state: "visible" });
      await page.locator("#prompt-input").fill("Keep the mobile draft");
      await toggle("summary").click();
      await toggle("summary").click();
      await toggle("conversation").click();
      assert.equal(await page.locator("#prompt-input").inputValue(), "Keep the mobile draft");
    }
    await toggle("pull-requests").click();
    await toggle("summary").click();
    await active([]);
    await page.locator("#prompt-input").waitFor({ state: "visible" });
    await toggle("summary").focus();
    await page.keyboard.press("Enter");
    await active(["summary"]);
    await page.evaluate(() => navigate({ type: "tab", tab: "settings" }));
    await page.locator("[data-appearance-preference]").waitFor();
    await page.evaluate(key => navigate({ type: "agent", key }), agentKey);
    await page.locator("[data-side-workspace]").waitFor();
    await active(["summary"]);
    assert.deepEqual(errors, []);
    await context.close();
  }
  await request.close();
  console.log("Side Conversations: desktop/mobile Dark/Light, shared toggles, two panels, third selection, polling and drafts passed");
};
