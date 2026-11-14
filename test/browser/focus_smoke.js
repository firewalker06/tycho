const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");

module.exports = async ({ browser, baseUrl, agentKey, captureDir }) => {
  const api = `${baseUrl}/agents/${agentKey}/focus`;
  const request = await browser.newContext();
  const uploaded = await request.request.post(`${baseUrl}/agents/${agentKey}/messages`, { data: {
    prompt: "Keep this synthetic Focus report.", start: false,
    attachments: [{ filename: "focus-report.md", title: "Focus report", content_type: "text/markdown", content_base64: Buffer.from("# Focus report\n\nSynthetic review evidence.").toString("base64") }],
  } });
  assert(uploaded.ok(), await uploaded.text());
  const detail = await (await request.request.get(`${baseUrl}/agents/${agentKey}`)).json();
  const file = detail.agent.attachments.find(item => item.title === "Focus report");
  assert(file, "fixture file must be registered");
  const doc = await (await request.request.get(api)).json();
  const sections = [
    { title: "Ready for Review", subtitle: "Your next actions", icon: "todo_done", items: [
      { title: "Fix user registration", subtitle: "PR #12 is ready", attachments: [{ type: "link", title: "Review PR #12", url: "https://github.com/example/web/pull/12" }, { type: "file", title: "Read Focus report", path: file.path }] },
      { title: "Add content celebrations", subtitle: "PR #13 is ready", attachments: [] }
    ] },
    { title: "In Progress", subtitle: "Work continues", icon: "todo_working", items: [
      { title: "Update the date library", subtitle: "Update 23 call sites", attachments: [] },
      { title: "Add rate limiting to checkout", subtitle: "Draft the limiter", attachments: [] }
    ] }
  ];
  const response = await request.request.put(api, { data: { revision: doc.focus.revision, sections } });
  assert.equal(response.status(), 200);
  let revision = (await response.json()).focus.revision;
  const results = [];
  for (const width of [1440, 390]) for (const theme of ["dark", "light"]) {
    const context = await browser.newContext({ viewport: { width, height: 900 }, isMobile: width < 500, hasTouch: width < 500 });
    const page = await context.newPage();
    const errors = [];
    page.on("pageerror", error => errors.push(error.message));
    await page.goto(`${baseUrl}/ui#settings`, { waitUntil: "networkidle" });
    await page.locator("[data-appearance-preference]").selectOption(theme);
    await page.goto(`${baseUrl}/ui#agent/${agentKey}`, { waitUntil: "networkidle" });
    const focus = page.locator("[data-agent-focus]");
    await focus.waitFor({ state: "visible" });
    await page.evaluate(async key => { await ensureConversation(findAgent(key), true); }, agentKey);
    await focus.evaluate(el => el.scrollIntoView());
    assert.equal(await focus.locator(".agent-focus-section").count(), 2);
    assert.equal(await focus.locator(".agent-focus-icon svg").count(), 2);
    assert.equal(await focus.getByRole("link", { name: "Review PR #12" }).getAttribute("href"), "https://github.com/example/web/pull/12");
    const fileLink = focus.getByRole("link", { name: "Read Focus report" });
    const fileHref = await fileLink.getAttribute("href");
    assert(fileHref.includes("attachment"), fileHref);
    // Peer resources must keep the owner on nested file links.
    const peer = await page.evaluate(({ key, file }) => {
      const owner = { key: "focus-peer", name: "Peer", local: false };
      const normalized = normalizeAgentResource({ key, focus: { sections: [{ items: [{ attachments: [file] }] }] } }, owner);
      return normalized.focus.sections[0].items[0].attachments[0];
    }, { key: agentKey, file });
    assert.equal(peer.agent_key, `focus-peer/${agentKey}`);
    assert(peer.blob_path.includes("focus-peer"), peer.blob_path);
    const summary = focus.locator(":scope > summary");
    await summary.focus();
    await page.keyboard.press("Enter");
    assert.equal(await focus.evaluate(el => el.open), false);
    await page.evaluate(() => refresh({ force: true }));
    assert.equal(await focus.evaluate(el => el.open), false, "polling must preserve collapse");
    await summary.focus();
    await page.keyboard.press("Enter");
    assert.equal(await focus.evaluate(el => el.open), true);
    const composer = page.locator("#prompt-input");
    await composer.fill("Keep this draft");
    const updated = structuredClone(sections);
    updated[1].items[0].subtitle = "Completed 12 of 23 call sites";
    const saved = await request.request.put(api, { data: { revision, sections: updated } });
    assert.equal(saved.status(), 200);
    revision = (await saved.json()).focus.revision;
    await page.evaluate(() => refresh({ force: true }));
    await focus.getByText("Completed 12 of 23 call sites").waitFor();
    assert.equal(await composer.inputValue(), "Keep this draft");
    // The dock shortcut must open a collapsed Focus and clear the fixed header.
    await focus.locator(":scope > summary").click();
    assert.equal(await focus.evaluate(el => el.open), false);
    await page.getByRole("button", { name: "Focus", exact: true }).click();
    assert.equal(await focus.evaluate(el => el.open), true);
    assert.equal(await focus.locator(":scope > summary").evaluate(el => document.activeElement === el), true);
    const geometry = await page.evaluate(() => ({ viewport: innerWidth, width: document.documentElement.scrollWidth, focus: document.querySelector("[data-agent-focus]").getBoundingClientRect().toJSON() }));
    assert(geometry.width <= geometry.viewport + 1, JSON.stringify(geometry));
    const contentFits = await focus.evaluate(el => ({ height: el.clientHeight, scrollHeight: el.scrollHeight }));
    assert(contentFits.scrollHeight <= contentFits.height + 1, "Focus must not clip its items: " + JSON.stringify(contentFits));
    assert(geometry.focus.y >= 70, "Focus shortcut must clear the header: " + JSON.stringify(geometry));
    assert(geometry.focus.x >= 0 && geometry.focus.right <= geometry.viewport + 1, JSON.stringify(geometry));
    if (captureDir) {
      fs.mkdirSync(captureDir, { recursive: true });
      await page.screenshot({ path: path.join(captureDir, `focus-${theme}-${width}.png`) });
    }
    await focus.getByRole("link", { name: "Read Focus report" }).click();
    await page.getByRole("heading", { name: "Focus report", exact: true }).waitFor();
    await page.goto(`${baseUrl}/ui#agent/${agentKey}`, { waitUntil: "networkidle" });
    await page.reload({ waitUntil: "networkidle" });
    await focus.getByText("Completed 12 of 23 call sites").waitFor();
    assert.deepEqual(errors, []);
    results.push({ width, theme, geometry, revision, checks: "sections, icons, link, keyboard, polling, update, draft, reload, overflow" });
    await context.close();
  }
  const unsafe = await request.request.put(api, { data: { revision, sections: [{ title: "Unsafe", items: [{ title: "Bad", attachments: [{ type: "link", title: "Bad", url: "javascript:alert(1)" }] }] }] } });
  assert.equal(unsafe.status(), 422);
  const stale = await request.request.put(api, { data: { revision: 0, sections: [] } });
  assert.equal(stale.status(), 409);
  const cleared = await request.request.put(api, { data: { revision, sections: [] } });
  assert.equal(cleared.status(), 200);
  const page = await request.newPage();
  await page.goto(`${baseUrl}/ui#agent/${agentKey}`, { waitUntil: "networkidle" });
  assert.equal(await page.locator("[data-agent-focus]").count(), 0, "cleared Focus must disappear");
  if (captureDir) fs.writeFileSync(path.join(captureDir, "focus-results.json"), JSON.stringify(results, null, 2));
  await request.close();
  console.log("focus_smoke: ok (desktop/mobile Dark/Light, keyboard, polling, reload, updates, links, unsafe URL, conflict, clear)");
};
