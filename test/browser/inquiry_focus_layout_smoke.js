const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");

module.exports = async ({ browser, baseUrl, captureDir }) => {
  const agentKey = "web-inquiry-recovery-0";
  const api = await browser.newContext();
  const inquiryResponse = await api.request.get(`${baseUrl}/agents/${agentKey}`);
  const inquiryDocument = await inquiryResponse.json();
  assert(inquiryDocument.agent, `fixture agent read failed: status ${inquiryResponse.status()} error ${inquiryDocument.error || "none"}`);
  const inquiry = inquiryDocument.agent.latest_inquiry;
  assert.deepEqual(inquiry.fields.map(field => field.input_type), ["select", "select", "select", "select", "select", "select", "multiline"]);
  assert.deepEqual(inquiry.fields.map(field => field.options?.length || 0), [3, 3, 3, 3, 2, 2, 0]);
  const focusUrl = `${baseUrl}/agents/${agentKey}/focus`;
  const currentFocus = (await (await api.request.get(focusUrl)).json()).focus;
  const saved = await api.request.put(focusUrl, { data: { revision: currentFocus.revision, sections: [
    { title: "Synthetic review", items: Array.from({ length: 12 }, (_, index) => ({ title: `Synthetic Focus item ${index + 1}`, subtitle: "Layout test content." })) },
  ] } });
  assert(saved.ok(), await saved.text());

  const baseline = process.env.TYCHO_REMOTE_UI_INQUIRY_FOCUS_BASELINE === "1";
  const context = await browser.newContext({ viewport: { width: 1180, height: 820 }, deviceScaleFactor: 2, hasTouch: true });
  const page = await context.newPage();
  if (baseline) {
    await page.route("**/ui.css?*", async route => {
      const response = await route.fetch();
      const body = await response.text();
      const headCss = fs.readFileSync(path.join(__dirname, "../../lib/hq/remote_ui/assets/app.css"), "utf8");
      const baselineCssPath = process.env.TYCHO_REMOTE_UI_INQUIRY_FOCUS_BASELINE_CSS;
      assert(baselineCssPath, "baseline CSS path is set for the comparison run");
      const baseCss = fs.readFileSync(baselineCssPath, "utf8");
      assert(body.includes(headCss), "baseline uses this branch's stylesheet response");
      await route.fulfill({ response, body: body.replace(headCss, baseCss) });
    });
  }
  await page.goto(`${baseUrl}/ui#agent/${agentKey}/summary`, { waitUntil: "networkidle" });
  await page.locator("#inquiry-form").waitFor({ state: "visible" });
  await page.locator('[data-side-kind="summary"]').waitFor({ state: "visible" });

  const frames = () => page.evaluate(() => new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve))));
  const toggle = kind => page.locator(`.side-conversation-controls [data-side-conversation="${kind}"]`);
  const measure = async label => page.evaluate(label => {
    const box = selector => {
      const element = document.querySelector(selector);
      if (!element) return null;
      const rect = element.getBoundingClientRect();
      const style = getComputedStyle(element);
      return { x: rect.x, y: rect.y, width: rect.width, height: rect.height, right: rect.right, bottom: rect.bottom,
        display: style.display, visibility: style.visibility, overflowX: style.overflowX, overflowY: style.overflowY,
        scrollHeight: element.scrollHeight, clientHeight: element.clientHeight, scrollTop: element.scrollTop };
    };
    const root = document.querySelector("[data-agent-workspace]");
    const focus = document.querySelector('[data-side-kind="focus"]');
    const summary = document.querySelector('[data-side-kind="summary"]');
    const dock = document.querySelector("[data-agent-dock]");
    const form = document.querySelector("#inquiry-form");
    return { label, viewport: { width: innerWidth, height: innerHeight, dpr: devicePixelRatio },
      root: { ...box("[data-agent-workspace]"), classes: [...root.classList], sideCount: root.dataset.sideCount,
        slotCount: getComputedStyle(root).getPropertyValue("--agent-panel-slot-count").trim(),
        visiblePanels: root.dataset.visiblePanels || null, collapsedPanels: root.dataset.collapsedPanels || null,
        columns: getComputedStyle(root).gridTemplateColumns, rows: getComputedStyle(root).gridTemplateRows },
      toggles: Object.fromEntries(["focus", "summary"].map(kind => [kind, document.querySelector(`[data-side-conversation="${kind}"]`)?.getAttribute("aria-pressed")])),
      focus: { ...box('[data-side-kind="focus"]'), visibleTextPresent: Boolean(focus?.innerText.includes("Synthetic Focus item")),
        hidden: focus?.classList.contains("side-conversation-hidden") ?? null },
      summary: { ...box('[data-side-kind="summary"]'), hidden: summary?.classList.contains("side-conversation-hidden") ?? null },
      conversation: box(".agent-conversation-pane"), dock: { ...box("[data-agent-dock]"), hidden: dock?.classList.contains("content-panel-hidden") ?? null,
        gridColumn: getComputedStyle(dock).gridColumn, gridRow: getComputedStyle(dock).gridRow },
      form: { ...box("#inquiry-form"), classes: form ? [...form.classList] : [] },
      fields: [...document.querySelectorAll("#inquiry-form .inquiry-field")].map(field => ({
        tag: field.querySelector("[data-inquiry-control]")?.tagName || null,
        type: field.querySelector("[data-inquiry-control]")?.getAttribute("type") || null,
      })),
      controlsAtTop: [...document.querySelectorAll('#inquiry-form [data-inquiry-control], #inquiry-feedback, #inquiry-form button[type="submit"]')].map(element => {
        const rect = element.getBoundingClientRect();
        const inViewport = rect.top >= 0 && rect.bottom <= innerHeight;
        return { tag: element.tagName, visible: Boolean(element.getClientRects().length) && getComputedStyle(element).visibility === "visible",
          inViewport, hit: inViewport && element.contains(document.elementFromPoint(rect.x + rect.width / 2, rect.y + rect.height / 2)), top: rect.top, bottom: rect.bottom };
      }),
      feedback: box("#inquiry-feedback"), submit: box("#inquiry-form button[type=submit]"),
      documentOverflow: document.documentElement.scrollWidth > innerWidth || document.documentElement.scrollHeight > innerHeight,
    };
  }, label);
  const controlsReachable = async () => {
    const results = [];
    for (const selector of ['#inquiry-form [data-inquiry-control]', "#inquiry-feedback", '#inquiry-form button[type="submit"]']) {
      const element = page.locator(selector).first();
      await element.scrollIntoViewIfNeeded();
      results.push(await element.evaluate(item => {
        const rect = item.getBoundingClientRect();
        return { tag: item.tagName, hit: item.contains(document.elementFromPoint(rect.x + rect.width / 2, rect.y + rect.height / 2)),
          inViewport: rect.top >= 0 && rect.bottom <= innerHeight, top: rect.top, bottom: rect.bottom };
      }));
    }
    return results;
  };
  const results = [];
  results.push(await measure("summary-open-focus-closed"));
  assert.deepEqual(results[0].fields.map(field => field.tag), ["SELECT", "SELECT", "SELECT", "SELECT", "SELECT", "SELECT", "TEXTAREA", null]);
  assert.equal(results[0].controlsAtTop.length, 9, "six select fields, one answer area, feedback, and Send answer render");

  await page.locator("[data-toggle-inquiry-full-screen]").click();
  await frames();
  results.push(await measure("summary-open-focus-closed-expanded"));
  if (captureDir) await page.screenshot({ path: path.join(captureDir, `${baseline ? "base" : "head"}-focus-closed-expanded.png`), animations: "disabled" });
  results[results.length - 1].controlsAfterScroll = await controlsReachable();
  await page.locator("[data-toggle-inquiry-full-screen]").click();
  await frames();

  // The inquiry is already loaded. Open Focus after that load, while Summary stays requested.
  await toggle("focus").click();
  await page.locator('[data-side-kind="focus"]').waitFor({ state: "visible" });
  await frames();
  results.push(await measure("summary-open-focus-open"));
  if (captureDir) {
    fs.mkdirSync(captureDir, { recursive: true });
    await page.screenshot({ path: path.join(captureDir, `${baseline ? "base" : "head"}-focus-summary-open.png`), animations: "disabled" });
  }
  await page.locator("[data-toggle-inquiry-full-screen]").click();
  await frames();
  results.push(await measure("summary-open-focus-open-expanded"));
  if (captureDir) await page.screenshot({ path: path.join(captureDir, `${baseline ? "base" : "head"}-focus-summary-open-expanded.png`), animations: "disabled" });
  results[results.length - 1].controlsAfterScroll = await controlsReachable();
  await page.locator("[data-toggle-inquiry-full-screen]").click();
  await frames();

  if (await toggle("summary").getAttribute("aria-pressed") === "true") await toggle("summary").click();
  await page.locator('[data-side-conversation="summary"][aria-pressed="false"]').waitFor();
  await page.locator('[data-side-kind="focus"]').waitFor({ state: "visible" });
  await frames();
  results.push(await measure("summary-closed-focus-open"));
  if (captureDir) await page.screenshot({ path: path.join(captureDir, `${baseline ? "base" : "head"}-focus-summary-closed.png`), animations: "disabled" });
  await page.locator("[data-toggle-inquiry-full-screen]").click();
  await frames();
  results.push(await measure("summary-closed-focus-open-expanded"));
  if (captureDir) await page.screenshot({ path: path.join(captureDir, `${baseline ? "base" : "head"}-focus-summary-closed-expanded.png`), animations: "disabled" });
  results[results.length - 1].controlsAfterScroll = await controlsReachable();
  await page.locator("[data-toggle-inquiry-full-screen]").click();
  await frames();

  await toggle("focus").click();
  await page.locator('[data-side-conversation="focus"][aria-pressed="false"]').waitFor();
  await frames();
  results.push(await measure("summary-closed-focus-closed"));

  await page.setViewportSize({ width: 1440, height: 820 });
  await frames();
  await page.goto(`${baseUrl}/ui#agent/${agentKey}/summary`, { waitUntil: "networkidle" });
  await page.locator('[data-side-kind="summary"]').waitFor({ state: "visible" });
  await toggle("focus").click();
  await page.locator('[data-side-kind="focus"]').waitFor({ state: "visible" });
  await frames();
  for (const width of [1440, 1439, 900]) {
    await page.setViewportSize({ width, height: 820 });
    await frames();
    const label = `width-${width}-focus-summary-open-expanded`;
    await page.locator("[data-toggle-inquiry-full-screen]").click();
    await frames();
    results.push(await measure(label));
    if (captureDir && [1439, 1440].includes(width)) {
      await page.screenshot({ path: path.join(captureDir, `${baseline ? "base" : "head"}-focus-summary-open-${width}.png`), animations: "disabled" });
    }
    results[results.length - 1].controlsAfterScroll = await controlsReachable();
    await page.locator("[data-toggle-inquiry-full-screen]").click();
    await frames();
  }
  const evidencePath = path.join(captureDir || "/tmp", `inquiry-focus-${baseline ? "base" : "head"}.json`);
  fs.writeFileSync(evidencePath, JSON.stringify(results, null, 2));
  console.log(JSON.stringify({ evidencePath, cases: results.map(item => ({ label: item.label, visiblePanels: item.root.visiblePanels,
    sideCount: item.root.sideCount, toggles: item.toggles, focusVisible: item.focus.visibleTextPresent,
    conversation: item.conversation, form: item.form, controlsAtTop: item.controlsAtTop, controlsAfterScroll: item.controlsAfterScroll })) }));
  for (const item of results.filter(result => result.label.includes("focus-open-expanded"))) {
    assert(item.focus.visibleTextPresent && item.focus.display !== "none", `${item.label}: populated Focus must be visible`);
    assert.equal(item.toggles.focus, "true", `${item.label}: Focus must remain selected`);
    assert(item.conversation.visibility === "visible" && item.conversation.height > 0,
      `${item.label}: Conversation must have visible height: ${JSON.stringify(item.conversation)}`);
    assert(item.dock.overflowY === "auto" && item.dock.scrollHeight > item.dock.clientHeight,
      `${item.label}: the dock must scroll the long answer form: ${JSON.stringify(item.dock)}`);
    assert(item.controlsAfterScroll?.every(control => control.hit && control.inViewport),
      `${item.label}: answer controls must remain reachable: ${JSON.stringify(item.controlsAfterScroll)}`);
  }
  assert.equal(results.find(result => result.label === "summary-open-focus-open-expanded").toggles.summary, "true");
  assert.equal(results.find(result => result.label === "summary-open-focus-open-expanded").summary.hidden, true,
    "at 1180 pixels, Focus is the visible side panel and Summary stays requested in the single side slot");
  assert.equal(results.find(result => result.label === "summary-closed-focus-open-expanded").toggles.summary, "false");
  assert.equal(results.find(result => result.label === "summary-open-focus-closed-expanded").focus.visibleTextPresent, false,
    "the Focus-closed control keeps the populated Focus pane closed");
  const at1440 = results.find(result => result.label === "width-1440-focus-summary-open-expanded");
  assert(at1440.focus.visibleTextPresent && at1440.summary.display !== "none", "1440 pixels gives Focus and Summary separate visible slots");
  for (const width of [1439, 900]) {
    const item = results.find(result => result.label === `width-${width}-focus-summary-open-expanded`);
    assert(item.focus.visibleTextPresent && item.summary.hidden, `${width} pixels keeps Focus visible in one side slot`);
  }
  await context.close();
  await api.close();
};
