const assert = require("node:assert/strict");
const path = require("node:path");

// Generous budgets: the check catches order-of-magnitude regressions, not noise.
const FIRST_PAINT_BUDGET_MS = Number(process.env.TYCHO_REMOTE_UI_LARGE_FIRST_PAINT_BUDGET_MS || 15000);
const INTERACTIVE_BUDGET_MS = Number(process.env.TYCHO_REMOTE_UI_LARGE_INTERACTIVE_BUDGET_MS || 20000);
const MESSAGE_SELECTOR = "[data-agent-conversation-scroll] .message, [data-agent-conversation-scroll] [data-block-id]";

module.exports = async function ({ browser, baseUrl, agentKey, captureDir }) {
  const context = await browser.newContext({ viewport: { width: 430, height: 900 } });
  const page = await context.newPage();
  await page.addInitScript(() => {
    window.__longTasks = [];
    new PerformanceObserver((list) => {
      for (const entry of list.getEntries()) window.__longTasks.push({ start: entry.startTime, duration: entry.duration });
    }).observe({ type: "longtask", buffered: true });
  });
  const conversation = { bytes: 0, count: 0, totalBlocks: 0 };
  page.on("response", async (response) => {
    if (!/\/agents\/[^/]+\/conversation$/.test(new URL(response.url()).pathname)) return;
    const body = await response.body().catch(() => null);
    if (!body) return;
    conversation.bytes += body.length;
    conversation.count += 1;
    conversation.totalBlocks = Math.max(conversation.totalBlocks, JSON.parse(body.toString()).conversation_block_count || 0);
  });

  const startedAt = Date.now();
  await page.goto(`${baseUrl}/ui#agent/${encodeURIComponent(agentKey)}`, { waitUntil: "commit" });
  await page.waitForSelector(MESSAGE_SELECTOR, { state: "visible", timeout: INTERACTIVE_BUDGET_MS });
  const firstPaintMs = Date.now() - startedAt;

  // Interactive: the composer accepts focus and echoes a keystroke.
  await page.focus("#prompt-input", { timeout: INTERACTIVE_BUDGET_MS });
  await page.keyboard.type("x");
  await page.waitForFunction(() => document.querySelector("#prompt-input")?.value === "x", null, { timeout: INTERACTIVE_BUDGET_MS });
  const interactiveMs = Date.now() - startedAt;

  await page.waitForLoadState("networkidle");
  const stats = await page.evaluate((selector) => ({
    domNodes: document.getElementsByTagName("*").length,
    renderedBlocks: document.querySelectorAll(selector).length,
    longTasks: window.__longTasks.length,
    longestTaskMs: Math.round(Math.max(0, ...window.__longTasks.map((task) => task.duration))),
    blockingMs: Math.round(window.__longTasks.reduce((sum, task) => sum + Math.max(0, task.duration - 50), 0))
  }), MESSAGE_SELECTOR);
  const result = { firstPaintMs, interactiveMs, conversationResponses: conversation.count, conversationBytes: conversation.bytes, totalBlocks: conversation.totalBlocks, ...stats };
  console.log(`LARGE_CONVERSATION_RENDER ${JSON.stringify(result)}`);
  if (captureDir) await page.screenshot({ path: path.join(captureDir, "large-conversation.png") });

  assert.ok(firstPaintMs <= FIRST_PAINT_BUDGET_MS, `first paint ${firstPaintMs}ms exceeds ${FIRST_PAINT_BUDGET_MS}ms`);
  assert.ok(interactiveMs <= INTERACTIVE_BUDGET_MS, `interactive ${interactiveMs}ms exceeds ${INTERACTIVE_BUDGET_MS}ms`);
  await context.close();
};
