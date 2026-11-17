const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");

module.exports = async ({ browser, baseUrl, agentKey, captureDir, metadataFixture }) => {
  const api = await browser.newContext();
  const longTitle = "Long attachment label " + "long_label_without_spaces_".repeat(9);
  const png = Buffer.from("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jRZkAAAAASUVORK5CYII=", "base64");
  const files = [
    { filename: "original report 日本語.md", content_type: "text/markdown", bytes: Buffer.from("# Focus attachment\n\nKeep the source beside this file.\n") },
    { filename: "diagram.png", content_type: "image/png", bytes: png },
    { filename: "figures.csv", content_type: "text/csv", bytes: Buffer.from("name,value\nalpha,3\n") },
    { filename: "notes.txt", content_type: "text/plain", bytes: Buffer.from("Review notes\n") },
    { filename: "report.html", content_type: "text/html", bytes: Buffer.from("<h1>Report</h1>") },
    { filename: "package.bin", content_type: "application/octet-stream", bytes: Buffer.from([0, 1, 2, 3]) },
    { filename: "removed.md", content_type: "text/markdown", bytes: Buffer.from("Removed fixture") },
  ];
  for (let offset = 0; offset < files.length; offset += 4) {
    const added = await api.request.post(`${baseUrl}/agents/${agentKey}/messages`, { data: {
      prompt: "Synthetic Focus attachment grid", start: false,
      attachments: files.slice(offset, offset + 4).map(file => ({ filename: file.filename, title: file === files[0] ? longTitle : file.filename, content_type: file.content_type, content_base64: file.bytes.toString("base64") })),
    } });
    assert(added.ok(), await added.text());
  }
  const agent = (await (await api.request.get(`${baseUrl}/agents/${agentKey}`)).json()).agent;
  const records = files.map(file => agent.attachments.find(a => a.filename === file.filename || a.title === file.filename));
  assert(records.every(Boolean));
  const link = { type: "link", title: "External reference with a long descriptive label", url: "https://example.test/focus-reference" };
  const focus = (await (await api.request.get(`${baseUrl}/agents/${agentKey}/focus`)).json()).focus;
  const saved = await api.request.put(`${baseUrl}/agents/${agentKey}/focus`, { data: { revision: focus.revision, sections: [
    { title: "Attachment review", subtitle: "Synthetic files and an ordinary external link", items: [{ title: "Review these files", attachments: [...records.map((file, i) => ({ type: "file", title: i === 0 ? longTitle : files[i].filename, path: file.path })), link] }] },
    { title: "Later", items: [{ title: "Retain this section choice" }] },
  ] } });
  assert(saved.ok(), await saved.text());
  const removed = await api.request.delete(`${baseUrl}/attachments/${records[6].id}`);
  assert(removed.ok(), await removed.text());
  const stored = JSON.parse(fs.readFileSync(path.join(metadataFixture.logsDir, "managed_agents.json"))).find(a => a.key === agentKey);
  fs.appendFileSync(stored.log_path.replace(/\.raw\.log$/, ".memory.jsonl"), JSON.stringify({ type: "run_summary", content: "Review the Focus grid and standard attachment actions.", status: "success", created_at: new Date().toISOString(), metadata: { summary_id: "focus-grid", run_number: 1, attachments: [...records.slice(0, 6), link] } }) + "\n");
  const results = [];
  for (const width of [3200, 2200, 2100, 1800, 390, 320]) for (const theme of ["dark", "light"]) {
    const context = await browser.newContext({ viewport: { width, height: 1000 }, isMobile: width < 900, hasTouch: width < 900 });
    await context.route("https://example.test/**", route => route.fulfill({ contentType: "text/html", body: "<h1>External reference</h1>" }));
    const page = await context.newPage();
    const errors = [];
    page.on("pageerror", error => errors.push(error.message));
    await page.goto(`${baseUrl}/ui#agent/${agentKey}/summary`, { waitUntil: "networkidle" });
    await page.evaluate(theme => window.TychoAppearance.setPreference(theme), theme);
    await page.locator("[data-side-workspace]").waitFor();
    const titleFacts = async selector => {
      const facts = await page.locator(selector).first().evaluate(e => {
        const title = e.querySelector(".attachment-copy strong");
        const style = getComputedStyle(title);
        const row = e.getBoundingClientRect();
        const text = title.getBoundingClientRect();
        return { fullTitle: title.textContent, disclosure: e.title, name: e.getAttribute("aria-label"),
          whiteSpace: style.whiteSpace, overflow: style.overflow, ellipsis: style.textOverflow,
          clipped: title.scrollWidth > title.clientWidth, height: text.height, lineHeight: parseFloat(style.lineHeight),
          fits: text.right <= row.right + 1 && e.scrollWidth <= e.clientWidth + 1 };
      });
      assert.equal(facts.fullTitle, longTitle);
      assert.equal(facts.disclosure, longTitle);
      assert(facts.name.includes(longTitle));
      assert.equal(facts.whiteSpace, "nowrap");
      assert.equal(facts.overflow, "hidden");
      assert.equal(facts.ellipsis, "ellipsis");
      assert(facts.clipped && facts.fits, JSON.stringify(facts));
      if (Number.isFinite(facts.lineHeight)) assert(facts.height <= facts.lineHeight + 1);
      return facts;
    };
    await titleFacts('[data-side-kind="summary"] .summary-attachment-row');
    if (captureDir) {
      fs.mkdirSync(captureDir, { recursive: true });
      await page.screenshot({ path: path.join(captureDir, `summary-title-${width}-${theme}.png`) });
    }
    const summaryIcons = await page.locator('[data-side-kind="summary"] .summary-attachment-row .attachment-icon').evaluateAll(es => es.map(e => e.innerHTML));
    const toggle = kind => page.locator(`.side-conversation-controls [data-side-conversation="${kind}"]`);
    await page.locator("#prompt-input").fill("Keep this grid draft");
    await toggle("focus").click();
    await toggle("summary").click();
    await page.locator("[data-agent-focus]").waitFor({ state: "visible" });
    const grid = page.locator(".agent-focus-attachments");
    const cards = grid.locator(":scope > li");
    assert.equal(await cards.count(), 8);
    const capture = async name => {
      if (!captureDir) return;
      fs.mkdirSync(captureDir, { recursive: true });
      await page.locator(".agent-focus-scroll").evaluate(e => { e.scrollTop = 0; });
      await page.evaluate(() => document.fonts.ready);
      await page.screenshot({ path: path.join(captureDir, `focus-grid-${name}-${width}-${theme}.png`) });
    };
    const measure = async expected => {
      await page.evaluate(() => new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve))));
      await page.waitForFunction(expected => {
        const grid = document.querySelector(".agent-focus-attachments");
        return grid?.getBoundingClientRect().width > 0;
      }, expected);
      const facts = await grid.evaluate(e => {
        const rect = e.getBoundingClientRect();
        const panel = e.closest("[data-agent-focus]").getBoundingClientRect();
        return { viewport: innerWidth, panelWidth: panel.width, columns: getComputedStyle(e).gridTemplateColumns.split(/\s+/).length,
          gridOverflow: e.scrollWidth > e.clientWidth + 1, pageOverflow: document.documentElement.scrollWidth > innerWidth,
          documentHeight: document.documentElement.scrollHeight, height: innerHeight,
          cardsFit: [...e.children].every(card => card.getBoundingClientRect().left >= rect.left - 1 && card.getBoundingClientRect().right <= rect.right + 1),
          actionsFit: [...e.querySelectorAll(".ui-icon-button")].every(button => {
            const b = button.getBoundingClientRect(); return b.width >= 40 && b.height >= 40 && b.left >= rect.left - 1 && b.right <= rect.right + 1;
          }) };
      });
      assert.equal(facts.columns, expected, JSON.stringify(facts));
      assert(!facts.gridOverflow && !facts.pageOverflow && facts.cardsFit && facts.actionsFit && facts.documentHeight <= facts.height + 1, JSON.stringify(facts));
      await titleFacts(".agent-focus-attachments .summary-attachment-row");
      results.push({ theme, ...facts });
      return facts;
    };
    const wide = await measure(width === 3200 ? 3 : width >= 2100 ? 2 : 1);
    assert.deepEqual(await cards.nth(0).locator(".attachment-icon").evaluate(e => e.innerHTML), summaryIcons[0]);
    assert.deepEqual(await cards.nth(1).locator(".attachment-icon").evaluate(e => e.innerHTML), summaryIcons[1]);
    assert.deepEqual(await cards.nth(7).locator(".attachment-icon").evaluate(e => e.innerHTML), summaryIcons[6]);
    assert.equal(await cards.nth(0).locator("a").getAttribute("title"), longTitle);
    assert((await cards.nth(0).locator("a").getAttribute("aria-label")).includes(longTitle));
    for (let i = 0; i < 6; i++) {
      assert.equal(await cards.nth(i).locator("button[data-preview-summary-attachment]").count(), 1);
      assert.equal(await cards.nth(i).locator("[data-download-attachment]").count(), 1);
      assert((await cards.nth(i).locator("button[data-preview-summary-attachment]").getAttribute("aria-label")).includes("in new panel"));
    }
    assert.equal(await cards.nth(6).locator("button[disabled]").count(), 1);
    assert.equal(await cards.nth(6).locator("[data-download-attachment], [data-preview-summary-attachment]").count(), 0);
    assert.equal(await cards.nth(7).locator("button").count(), 0, "ordinary links must not gain unsupported actions");
    assert.equal(await cards.nth(7).locator("a").getAttribute("target"), "_blank");
    const parentUrl = page.url();
    const popupPromise = page.waitForEvent("popup");
    await cards.nth(7).locator("a").click();
    const popup = await popupPromise;
    await popup.waitForLoadState("domcontentloaded");
    assert.equal(popup.url(), link.url);
    assert.equal(page.url(), parentUrl);
    await popup.close();
    await page.bringToFront();
    const downloadPromise = page.waitForEvent("download");
    await cards.nth(0).locator("[data-download-attachment]").focus();
    await cards.nth(0).locator("[data-download-attachment]").press("Enter");
    const download = await downloadPromise;
    assert.equal(download.suggestedFilename(), files[0].filename);
    assert.deepEqual(fs.readFileSync(await download.path()), files[0].bytes);
    // Download remains supported for a binary file with no inline text renderer.
    const binaryPromise = page.waitForEvent("download");
    await cards.nth(5).locator("[data-download-attachment]").click();
    assert.deepEqual(fs.readFileSync(await (await binaryPromise).path()), files[5].bytes);
    await capture(`wide-${wide.columns}-columns`);
    if (width >= 1800) {
      await toggle("summary").click();
      const narrow = await measure(wide.columns);
      assert.equal(wide.viewport, narrow.viewport);
      assert(Math.abs(wide.panelWidth - narrow.panelWidth) < 1.1 && wide.columns === narrow.columns, "open count does not change the fixed panel slot or its grid");
      if (width === 2100) {
        await page.evaluate(() => { document.querySelector(".app-shell").style.gridTemplateColumns = "144px minmax(0, 1fr)"; syncAgentDockLayout(); });
        const expandedRail = await measure(1);
        assert(expandedRail.panelWidth < wide.panelWidth, "the grid still responds to actual panel width after sidebar changes at the same viewport");
        await capture("expanded-sidebar-1-column");
        await page.evaluate(() => { document.querySelector(".app-shell").style.removeProperty("grid-template-columns"); syncAgentDockLayout(); });
        await measure(2);
      }
      await capture(`narrow-${narrow.columns}-columns`);
    }
    const headings = page.locator("[data-focus-section]");
    assert.equal(await headings.count(), 2);
    await headings.nth(1).click();
    await page.evaluate(() => refresh({ force: true }));
    assert.equal(await headings.nth(1).getAttribute("aria-expanded"), "false");
    await cards.nth(0).locator("button[data-preview-summary-attachment]").press("Space");
    await page.locator('.summary-attachment-preview-scroll[aria-busy="false"]').waitFor({ state: "visible" });
    assert.deepEqual(await page.locator("[data-side-kind]").evaluateAll(es => es.map(e => e.dataset.sideKind)), ["focus", "attachment"]);
    assert.equal(await headings.nth(1).getAttribute("aria-expanded"), "false");
    assert.equal(await page.locator("#prompt-input").inputValue(), "Keep this grid draft");
    await page.evaluate(() => refresh({ force: true }));
    assert.equal(await page.locator('.summary-attachment-preview-pane').count(), 1);
    assert.equal(await headings.nth(1).getAttribute("aria-expanded"), "false");
    if (captureDir) await page.screenshot({ path: path.join(captureDir, `focus-grid-attachment-${width}-${theme}.png`) });
    assert.deepEqual(errors, []);
    await context.close();
  }
  if (captureDir) fs.writeFileSync(path.join(captureDir, "focus-grid-geometry.json"), JSON.stringify(results, null, 2));
  await api.close();
};
