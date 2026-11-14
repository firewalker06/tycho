const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");

module.exports = async ({ browser, baseUrl, agentKey, captureDir }) => {
  const request = await browser.newContext();
  const api = `${baseUrl}/agents/${agentKey}/focus`;
  const uploaded = await request.request.post(`${baseUrl}/agents/${agentKey}/messages`, { data: {
    prompt: "Keep these synthetic review notes.", start: false,
    attachments: [{ filename: "review-notes.md", title: "Review notes", content_type: "text/markdown", content_base64: Buffer.from("# Review notes\n\nSynthetic evidence.").toString("base64") }],
  } });
  assert(uploaded.ok(), await uploaded.text());
  const detail = await (await request.request.get(`${baseUrl}/agents/${agentKey}`)).json();
  const file = detail.agent.attachments.find(item => item.title === "Review notes");
  assert(file);
  const sections = [
    { title: "Ready for Review", subtitle: "Your next actions", icon: "todo_done", items: [
      { title: "Fix user registration", subtitle: "PR #12 is ready", attachments: [{ type: "link", title: "Review PR #12", url: "https://github.com/example/web/pull/12" }, { type: "file", title: "Read review notes", path: file.path }] },
      { title: "Add content celebrations", subtitle: "PR #13 is ready" }
    ] },
    { title: "In Progress", subtitle: "Work continues", icon: "todo_working", items: [
      { title: "Update the date library", subtitle: "Update 23 call sites" },
      { title: "Add rate limiting to checkout", subtitle: "Draft the limiter" }
    ] },
    { title: "Next actions", icon: "todo_pending", items: Array.from({ length: 20 }, (_, i) => ({ title: `Action ${i + 1}`, subtitle: "Synthetic work list for independent scrolling" })) }
  ];
  let revision = (await (await request.request.get(api)).json()).focus.revision;
  const save = async content => {
    const response = await request.request.put(api, { data: { revision, sections: content } });
    assert.equal(response.status(), 200, await response.text());
    revision = (await response.json()).focus.revision;
  };
  await save(sections);
  const results = [];
  for (const width of [1440, 1024, 390]) for (const theme of ["dark", "light"]) {
    await save(sections);
    const context = await browser.newContext({ viewport: { width, height: 900 }, isMobile: width < 500, hasTouch: width < 500 });
    const page = await context.newPage();
    const errors = [];
    page.on("pageerror", error => errors.push(error.message));
    const frames = () => page.evaluate(() => new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve))));
    const refresh = async () => { await page.evaluate(() => refresh({ force: true })); await frames(); };
    const visible = () => page.locator(".agent-workspace").getAttribute("data-visible-panels");
    const focus = page.locator("[data-agent-focus]");
    const close = page.getByRole("button", { name: "Close Focus panel", exact: true });
    const open = page.locator("[data-show-agent-focus]");
    const composer = page.locator("#prompt-input");
    const capture = async name => {
      if (!captureDir) return;
      fs.mkdirSync(captureDir, { recursive: true });
      await page.screenshot({ path: path.join(captureDir, `focus-panel-${name}-${theme}-${width}.png`) });
    };
    await page.goto(`${baseUrl}/ui#settings`, { waitUntil: "networkidle" });
    await page.locator("[data-appearance-preference]").selectOption(theme);
    await page.goto(`${baseUrl}/ui#agent/${agentKey}`, { waitUntil: "networkidle" });
    await composer.waitFor();
    await page.evaluate(async key => { await ensureConversation(findAgent(key), true); syncAgentDockLayout(); }, agentKey);
    await page.getByText(/Tail message 79/).waitFor({ state: "attached" });
    await frames();
    assert.equal((await visible()).includes("focus"), width === 1440, "default must depend on panel fit");
    const nesting = await focus.evaluate(el => ({ inMessage: !!el.closest(".message-list, article.message"), inConversation: !!el.closest("[data-agent-conversation-pane]"), pane: el.closest(".agent-detail-pane")?.parentElement === document.querySelector(".agent-conversation-pane")?.parentElement }));
    assert.deepEqual(nesting, { inMessage: false, inConversation: false, pane: true });
    await composer.fill("Keep this draft near the conversation bottom");
    await page.evaluate(async () => { await document.fonts.ready; syncAgentDockLayout(); });
    await frames();
    await page.waitForFunction(() => {
      const el = document.querySelector("[data-agent-conversation-scroll]");
      el.scrollTop = el.scrollHeight;
      return el.scrollHeight - el.scrollTop - el.clientHeight < 4;
    });
    await frames();
    const scroll = await page.locator("[data-agent-conversation-scroll]").evaluate(el => ({ top: el.scrollTop, height: el.clientHeight, total: el.scrollHeight, width: el.clientWidth }));
    assert(scroll.top > 500, JSON.stringify(scroll));
    assert(scroll.total - scroll.top - scroll.height < 4, "fixture must be near the long conversation bottom: " + JSON.stringify({width, theme, scroll}));
    await capture("default");
    if (width === 1440) {
      await page.setViewportSize({ width: 390, height: 900 }); await frames();
      assert.equal(await visible(), "conversation", "wide default must not auto-open mobile");
      await page.setViewportSize({ width, height: 900 }); await frames();
      assert((await visible()).includes("focus"), "fit restores default wide panel");
    }
    if (!(await visible()).includes("focus")) { await open.focus(); await page.keyboard.press("Enter"); await frames(); }
    await focus.waitFor({ state: "visible" });
    assert.equal(await close.isVisible(), true);
    const closeStyle = () => close.evaluate(el => {
      const style = getComputedStyle(el), rect = el.getBoundingClientRect();
      return { borders: [style.borderTopWidth, style.borderRightWidth, style.borderBottomWidth, style.borderLeftWidth], width: rect.width, height: rect.height, name: el.getAttribute("aria-label"), outline: style.outlineStyle, outlineWidth: style.outlineWidth, focusVisible: el.matches(":focus-visible") };
    });
    const closeNormal = await closeStyle();
    assert.deepEqual(closeNormal.borders, ["0px", "0px", "0px", "0px"]);
    assert(closeNormal.width >= 44 && closeNormal.height >= 44, JSON.stringify(closeNormal));
    assert.equal(closeNormal.name, "Close Focus panel");
    await close.hover();
    assert.deepEqual((await closeStyle()).borders, ["0px", "0px", "0px", "0px"], "hover must remain borderless");
    assert.equal(await focus.locator(".agent-focus-section").count(), 3);
    assert.equal(await focus.locator(".agent-focus-icon svg").count(), 3);
    assert.equal(await focus.getByRole("link", { name: "Review PR #12" }).getAttribute("href"), "https://github.com/example/web/pull/12");
    const beforeIndependent = await page.locator("[data-agent-conversation-scroll]").evaluate(el => el.scrollTop);
    const focusScroll = focus.locator(".agent-focus-scroll");
    await focusScroll.hover(); await page.mouse.wheel(0, 300); await frames();
    assert((await focusScroll.evaluate(el => el.scrollTop)) > 0, "Focus must scroll independently");
    assert(Math.abs((await page.locator("[data-agent-conversation-scroll]").evaluate(el => el.scrollTop)) - beforeIndependent) < 4, "Focus scroll moved Conversation");
    await refresh();
    assert((await visible()).includes("focus"), "polling lost explicit open");
    assert.equal(await composer.inputValue(), "Keep this draft near the conversation bottom");
    await focusScroll.evaluate(el => { el.scrollTop = 0; });
    await composer.focus();
    await capture("open");
    await close.focus();
    await page.keyboard.press("Shift+Tab"); await page.keyboard.press("Tab");
    assert(await close.evaluate(el => document.activeElement === el));
    const closeKeyboard = await closeStyle();
    assert(closeKeyboard.focusVisible && closeKeyboard.outline !== "none" && parseFloat(closeKeyboard.outlineWidth) >= 2, JSON.stringify(closeKeyboard));
    assert.deepEqual(closeKeyboard.borders, ["0px", "0px", "0px", "0px"]);
    await capture("keyboard-focus");
    await page.keyboard.press("Enter"); await frames();
    assert((await visible()).includes("conversation"));
    assert(!(await visible()).includes("focus"));
    const closedScroll = await page.locator("[data-agent-conversation-scroll]").evaluate(el => ({ top: el.scrollTop, height: el.clientHeight, total: el.scrollHeight, width: el.clientWidth }));
    assert(closedScroll.width === scroll.width ? Math.abs(closedScroll.top - scroll.top) < 4 : closedScroll.total - closedScroll.top - closedScroll.height < 4, "closing Focus lost Conversation position: " + JSON.stringify({ width, scroll, closedScroll }));
    const updated = structuredClone(sections); updated[1].items[0].subtitle = "Completed 12 of 23 call sites";
    await save(updated); await refresh();
    assert(!(await visible()).includes("focus"), "changed polling must preserve intentional close");
    await page.setViewportSize({ width: width === 390 ? 1440 : 390, height: 900 }); await frames();
    assert(!(await visible()).includes("focus"), "resize reopened an intentionally closed panel");
    await page.setViewportSize({ width, height: 900 }); await frames();
    assert(!(await visible()).includes("focus"));
    await page.goto(`${baseUrl}/ui#settings`, { waitUntil: "networkidle" });
    await page.goto(`${baseUrl}/ui#agent/${agentKey}`, { waitUntil: "networkidle" }); await frames();
    assert(!(await visible()).includes("focus"), "navigation lost intentional close");
    await open.click(); await frames();
    await focus.getByText(updated[1].items[0].subtitle).waitFor();
    if (width === 1440) {
      await page.setViewportSize({ width: 390, height: 900 }); await frames();
      assert.equal(await visible(), "conversation", "A desktop open must not request the mobile panel");
      await page.setViewportSize({ width, height: 900 }); await frames();
      assert((await visible()).includes("focus"));
    }
    const geometry = await page.evaluate(() => ({ viewport: innerWidth, width: document.documentElement.scrollWidth, focus: document.querySelector("[data-agent-focus]").getBoundingClientRect().toJSON(), dock: document.querySelector(".agent-dock").getBoundingClientRect().toJSON() }));
    assert(geometry.width <= geometry.viewport + 1, JSON.stringify(geometry));
    assert(geometry.focus.right <= geometry.viewport + 1 && geometry.focus.y >= 60 && geometry.focus.bottom <= 901, JSON.stringify(geometry));
    assert(geometry.dock.height > 0 && geometry.dock.bottom <= 901 && geometry.dock.x >= 0 && geometry.dock.right <= geometry.viewport + 1, JSON.stringify(geometry));
    // Existing Summary/attachment panels remain separate from Focus state.
    await page.goto(`${baseUrl}/ui#agent/${agentKey}/summary`, { waitUntil: "networkidle" });
    assert.equal(await page.locator("[data-agent-focus]").count(), 0);
    if (width === 1440) {
      await page.evaluate(({ id, key }) => openSummaryAttachmentPreview(id, key), { id: file.id, key: agentKey });
      await page.getByRole("heading", { name: "Review notes", exact: true }).waitFor();
      assert.equal(await page.locator("[data-content-panel-heading]").count(), 3);
    }
    await page.goto(`${baseUrl}/ui#agent/${agentKey}`, { waitUntil: "networkidle" }); await frames();
    assert((await visible()).includes("focus"), "navigation lost explicit open");
    await focus.getByRole("link", { name: "Read review notes" }).click();
    await page.getByRole("heading", { name: "Review notes", exact: true }).waitFor();
    assert.deepEqual(errors, []);
    results.push({ width, theme, nesting, geometry, scroll, closeNormal, closeKeyboard, checks: "long bottom, defaults, user open/close, independent scroll, polling, late update, resize, navigation, draft, Summary and attachment" });
    await context.close();
  }
  // A document first created by polling must not steal a previously empty Conversation.
  await save([]);
  const page = await request.newPage({ viewport: { width: 1440, height: 900 } });
  await page.goto(`${baseUrl}/ui#agent/${agentKey}`, { waitUntil: "networkidle" });
  await page.locator("#prompt-input").waitFor();
  assert.equal(await page.locator("[data-agent-focus]").count(), 0);
  await save(sections);
  await page.evaluate(() => refresh({ force: true }));
  assert.equal(await page.locator(".agent-workspace").getAttribute("data-visible-panels"), "conversation");
  await page.locator("[data-show-agent-focus]").click();
  await page.locator("[data-agent-focus]").waitFor({ state: "visible" });
  const unsafe = await request.request.put(api, { data: { revision, sections: [{ title: "Unsafe", items: [{ title: "Bad", attachments: [{ type: "link", title: "Bad", url: "javascript:alert(1)" }] }] }] } });
  assert.equal(unsafe.status(), 422);
  const stale = await request.request.put(api, { data: { revision: 0, sections: [] } }); assert.equal(stale.status(), 409);
  await save([]); await page.evaluate(() => refresh({ force: true }));
  assert.equal(await page.locator("[data-agent-focus]").count(), 0);
  if (captureDir) fs.writeFileSync(path.join(captureDir, "focus-panel-results.json"), JSON.stringify(results, null, 2));
  await request.close();
  console.log("focus_smoke: ok (peer panel, long bottom, fit defaults, mobile closed/open, polling, resize, navigation, independent scroll, composer, Summary/attachment, empty/late Focus)");
};
