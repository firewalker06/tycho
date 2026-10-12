const fs = require("fs");
const path = require("path");

module.exports = async function attachmentPreviewSmoke({ browser, baseUrl, agentKey, otherAgentKey, captureDir }) {
  const page = await browser.newPage({ viewport: { width: 1920, height: 1080 } });
  const errors = [];
  const raceResults = [];
  page.on("pageerror", (error) => errors.push(error.message));
  const agent = (await (await page.request.get(`${baseUrl}/agents/${agentKey}`)).json()).agent;
  const attachments = Object.fromEntries(agent.attachments.map((item) => [item.title, item]));
  const summaryUrl = `${baseUrl}/ui#agent/${agentKey}/summary/preview-current`;
  const pane = page.locator(".summary-attachment-preview-pane");
  const previewButton = (title) => page.locator(`.agent-detail-pane [data-preview-summary-attachment="${attachments[title].id}"]`).first();
  async function open(title) {
    await previewButton(title).click();
    await page.waitForFunction(() => document.querySelector(".summary-attachment-preview-scroll")?.getAttribute("aria-busy") === "false");
  }
  async function assert(condition, message) { if (!condition) throw new Error(message); }
  async function capture(name) {
    if (captureDir) await page.screenshot({ path: path.join(captureDir, `${name}.png`), fullPage: false });
  }
  await page.goto(summaryUrl, { waitUntil: "networkidle" });
  await previewButton("Release review").waitFor();
  await previewButton("Release review").focus();
  await page.keyboard.press("Enter");
  await page.waitForFunction(() => document.querySelector(".summary-attachment-preview-scroll")?.getAttribute("aria-busy") === "false");
  await assert(await pane.locator("h1").innerText() === "Release review", "Markdown did not use the existing renderer");
  await assert(await page.evaluate(() => document.activeElement?.hasAttribute("data-close-summary-attachment-preview")), "Opening did not focus the close control");
  const layout = await page.evaluate(() => {
    const box = (selector) => { const r = document.querySelector(selector).getBoundingClientRect(); return { x: r.x, right: r.right, width: r.width, bottom: r.bottom }; };
    return { conversation: box(".agent-conversation-pane"), summary: box(".agent-detail-pane"), preview: box(".summary-attachment-preview-pane"), viewport: innerWidth, overflow: document.documentElement.scrollWidth > innerWidth };
  });
  await assert(layout.conversation.width >= 380 && layout.summary.width >= 440 && layout.preview.width >= 440 &&
    layout.conversation.right <= layout.summary.x && layout.summary.right <= layout.preview.x && !layout.overflow,
    `Three readable panes do not fit: ${JSON.stringify(layout)}`);
  await capture("attachment-preview-wide");
  const independentScroll = await page.evaluate(() => {
    const preview = document.querySelector(".summary-attachment-preview-scroll");
    const summary = document.querySelector(".agent-detail-pane");
    const conversation = document.querySelector(".agent-conversation-scroll");
    const before = [summary.scrollTop, conversation.scrollTop, window.scrollY];
    preview.scrollTop = 380;
    return { before, after: [summary.scrollTop, conversation.scrollTop, window.scrollY], preview: preview.scrollTop };
  });
  await assert(independentScroll.preview > 0 && JSON.stringify(independentScroll.before) === JSON.stringify(independentScroll.after), "Preview does not scroll independently");
  await page.evaluate(async () => { await refresh({ force: true, preserveFocusedWorkspace: true }); });
  await assert(await pane.count() === 1 && await pane.locator("h1").innerText() === "Release review", "Polling lost the selected attachment");
  await page.locator(".summary-attachment-preview-scroll").focus();
  await page.keyboard.press("PageDown");
  await assert(await page.evaluate(() => document.activeElement?.classList.contains("summary-attachment-preview-scroll")), "Preview scroll region is not keyboard accessible");
  await page.keyboard.press("Escape");
  await assert(await pane.count() === 0 && await previewButton("Release review").evaluate((button) => button === document.activeElement), "Escape did not close and restore focus");

  await open("Notes");
  await page.locator("[data-close-summary-attachment-preview]").click();
  await assert(await pane.count() === 0, "Close button did not remove the preview");
  await page.evaluate(() => { state.agentDetailViewMode[`${parseRoute().key}:summary`] = "full"; render(); });
  await open("Notes");
  await assert(await page.locator(".agent-conversation-pane").isVisible(), "Preview from Full view hid the Conversation");
  await assert((await pane.innerText()).includes("Plain text preview"), "Text did not render");
  await open("Diagram");
  await assert(await pane.locator("img").evaluate((image) => image.complete && image.naturalWidth > 0 && image.src.startsWith("blob:")), "Image did not use the authenticated blob renderer");
  await open("Interactive report");
  const sandbox = await pane.locator("iframe").getAttribute("sandbox");
  await assert(!sandbox.includes("allow-same-origin") && !(await pane.locator("iframe").getAttribute("srcdoc")).includes("frame-src https:"), "HTML sandbox was weakened");
  await open("External reference");
  await assert(await pane.locator("iframe").count() === 0 && await pane.getByText("Open link", { exact: true }).getAttribute("target") === "_blank", "External content lacks a safe fallback");
  await assert(page.context().pages().length === 1, "Preview opened an external site without a click");
  await open("Download package");
  await assert(await pane.getByText("Download file", { exact: true }).count() >= 1, "Binary download fallback is absent");
  // Repeat an ID while its first request is held, then release the old response last.
  async function assertRepeatedIdRace(title, image = false) {
    const attachment = attachments[title];
    const payload = (await (await page.request.get(`${baseUrl}/attachments/${attachment.id}`)).json());
    const pattern = image ? `**/attachments/${attachment.id}/blob*` : `**/attachments/${attachment.id}`;
    let held;
    let signalHeld;
    const heldReady = new Promise((resolve) => { signalHeld = resolve; });
    let count = 0;
    const response = (stale) => image
      ? { status: 200, contentType: "image/svg+xml", body: `<svg xmlns="http://www.w3.org/2000/svg" width="${stale ? 17 : 29}" height="20"><rect width="100%" height="100%" fill="${stale ? "red" : "blue"}"/></svg>` }
      : { status: 200, contentType: "application/json", body: JSON.stringify({ ...payload, attachment: { ...payload.attachment, content: stale ? "STALE_RESPONSE_A" : "CURRENT_RESPONSE_A" } }) };
    await page.evaluate(() => {
      window.previewRaceSettled = [];
      window.previewRaceOriginalOpen = openSummaryAttachmentPreview;
      openSummaryAttachmentPreview = async (...args) => {
        try { return await window.previewRaceOriginalOpen(...args); }
        finally { window.previewRaceSettled.push(args[0]); }
      };
      window.previewRaceCreatedUrls = [];
      window.previewRaceOriginalCreateUrl = URL.createObjectURL;
      URL.createObjectURL = (blob) => { const url = window.previewRaceOriginalCreateUrl(blob); window.previewRaceCreatedUrls.push(url); return url; };
    });
    await page.route(pattern, async (route) => {
      count += 1;
      if (count === 1) { held = route; signalHeld(); return; }
      await route.fulfill(response(false));
    });
    await previewButton(title).click();
    // Wait for the actual request to be held; UI loading alone precedes image fetches.
    await Promise.race([heldReady, new Promise((_, reject) => setTimeout(() => reject(new Error("First repeated-ID request was not held")), 10_000))]);
    await open("Release review");
    await open(title);
    if (image) await pane.locator("img").evaluate((image) => image.decode());
    const current = await page.evaluate((id) => ({ content: state.attachmentDetails[id]?.content, url: state.attachmentImageUrls[id] }), attachment.id);
    await held.fulfill(response(true));
    await page.waitForFunction((id) => window.previewRaceSettled.filter((item) => item === id).length === 2, attachment.id);
    await page.evaluate(() => render());
    await page.evaluate(async () => { await refresh({ force: true, preserveFocusedWorkspace: true }); render(); });
    if (image) {
      await pane.locator("img").evaluate((image) => image.decode());
      await assert(await pane.locator("img").evaluate((image) => image.naturalWidth === 29), "Delayed repeated-ID image replaced current preview after render/polling");
      await assert(await page.evaluate((value) => state.attachmentImageUrls[value.id] === value.url && window.previewRaceCreatedUrls.length === 1, { id: attachment.id, url: current.url }), "Stale image response allocated or replaced a blob URL");
    } else {
      await assert((await pane.innerText()).includes("CURRENT_RESPONSE_A") && !(await pane.innerText()).includes("STALE_RESPONSE_A"), "Delayed repeated-ID metadata replaced current preview after render/polling");
      await assert(await page.evaluate((id) => state.attachmentDetails[id].content === "CURRENT_RESPONSE_A", attachment.id), "Stale metadata poisoned the shared cache");
    }
    raceResults.push({ kind: image ? "image" : "metadata", sequence: "A -> B -> A; newest response first, delayed response last", ordinaryRender: "current content preserved", polling: "current content preserved", staleBlobAllocated: false });
    await page.unroute(pattern);
    await page.evaluate(() => { window.previewRaceSettled = []; });
    // A late response after leaving the Summary must not reopen its pane.
    let leaving;
    let signalLeaving;
    const leavingReady = new Promise((resolve) => { signalLeaving = resolve; });
    await page.route(pattern, (route) => { leaving = route; signalLeaving(); });
    await previewButton(title).click();
    await Promise.race([leavingReady, new Promise((_, reject) => setTimeout(() => reject(new Error("Leaving request was not held")), 10_000))]);
    await page.goto(`${baseUrl}/ui#agent/${otherAgentKey}`, { waitUntil: "domcontentloaded" });
    await leaving.fulfill(response(true));
    await page.waitForFunction((id) => window.previewRaceSettled.includes(id), attachment.id);
    await page.unroute(pattern);
    await page.evaluate(() => { openSummaryAttachmentPreview = window.previewRaceOriginalOpen; URL.createObjectURL = window.previewRaceOriginalCreateUrl; });
    await page.evaluate(() => render());
    await assert(await pane.count() === 0, "A late response reopened the preview after agent navigation");
    await page.goto(summaryUrl, { waitUntil: "networkidle" });
  }
  await assertRepeatedIdRace("Notes");
  await assertRepeatedIdRace("Diagram", true);

  fs.unlinkSync(attachments["Missing report"].path);
  await open("Missing report");
  await assert(/not readable|not found/i.test(await pane.innerText()), "Missing file has no useful error");

  // A failed metadata request must replace old content, not retain the old preview.
  await page.route(`**/attachments/${attachments.Notes.id}`, (route) => route.fulfill({ status: 500, contentType: "application/json", body: JSON.stringify({ error: "Preview service unavailable" }) }));
  await open("Notes");
  await assert((await pane.innerText()).includes("Attachment unavailable") && !(await pane.innerText()).includes("Release review"), "Failed load retained old content");
  await page.unroute(`**/attachments/${attachments.Notes.id}`);

  await open("Release review");
  await page.goto(`${baseUrl}/ui#agent/${agentKey}/summary/preview-prior`, { waitUntil: "networkidle" });
  await assert(await pane.count() === 0, "Run selection retained a preview");
  await page.goto(summaryUrl, { waitUntil: "networkidle" });
  await open("Release review");
  await page.goto(`${baseUrl}/ui#agent/${otherAgentKey}`, { waitUntil: "networkidle" });
  await assert(await pane.count() === 0, "Agent selection retained a preview");

  await page.goto(summaryUrl, { waitUntil: "networkidle" });
  await open("Release review");
  await page.evaluate(() => { findAgent(parseRoute().key).run_count += 1; syncFocusedSummaryFreshness(findAgent(parseRoute().key)); });
  await assert(await pane.count() === 0, "New run retained stale preview during focused polling");

  // Verify the exact boundary and resize into the existing detail view.
  await page.goto(summaryUrl, { waitUntil: "networkidle" });
  await page.setViewportSize({ width: 1760, height: 1000 });
  await open("Release review");
  await assert(await pane.count() === 1 && !(await page.evaluate(() => document.documentElement.scrollWidth > innerWidth)), "Breakpoint has horizontal overflow");
  await page.setViewportSize({ width: 1759, height: 1000 });
  await page.waitForURL(/\/attachment\//);
  await assert(await pane.count() === 0, "Resize did not open the detail fallback");

  for (const [name, width, height] of [["normal", 1440, 900], ["mobile", 390, 844]]) {
    await page.setViewportSize({ width, height });
    await page.goto(summaryUrl, { waitUntil: "networkidle" });
    await previewButton("Release review").scrollIntoViewIfNeeded();
    await assert(!(await page.evaluate(() => document.documentElement.scrollWidth > innerWidth)), `${name} Summary has horizontal overflow`);
    await capture(`attachment-summary-${name}`);
    const originalOpen = page.locator(".agent-detail-pane .summary-attachment-row").filter({ hasText: "Release review" });
    await assert((await originalOpen.getAttribute("href")).includes(`/attachment/${attachments["Release review"].id}`), "Existing open action changed");
    await assert(await page.locator(`.agent-detail-pane [data-download-attachment="${attachments["Release review"].id}"]`).count() === 1, "Existing download action is absent");
    await previewButton("Release review").click();
    await page.waitForURL(/\/attachment\//);
    await page.locator(".agent-attachment-viewer h1").waitFor();
    await assert(await pane.count() === 0 && !(await page.evaluate(() => document.documentElement.scrollWidth > innerWidth)), `${name} detail fallback has layout errors`);
    await capture(`attachment-detail-${name}`);
  }
  await assert(errors.length === 0, `Browser errors: ${errors.join("; ")}`);
  if (captureDir) fs.writeFileSync(path.join(captureDir, "attachment-preview-results.json"), JSON.stringify({ layout, independentScroll, raceResults, errors, tested: ["1920", "1760", "1759", "1440", "390", "keyboard", "polling", "run/agent lifecycle", "secure renderers", "missing file", "metadata failure", "repeated-ID metadata/image races after render/polling", "delayed response after navigation"] }, null, 2));
  console.log(`attachment-preview-smoke: ok ${JSON.stringify(layout)}`);
  await page.close();
};
