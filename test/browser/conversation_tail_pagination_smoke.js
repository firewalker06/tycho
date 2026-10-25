const assert = require("node:assert/strict");
const path = require("node:path");

const FIRST_PAINT_BLOCKS = 50;
const SEEDED_MESSAGES = 180;

function messageNumbers(texts) {
  return texts.map((text) => Number(/Tail message (\d+)\./.exec(text)?.[1])).filter(Number.isFinite);
}

async function renderedMessageNumbers(page) {
  const texts = await page.$$eval("[data-agent-conversation-scroll] .message, [data-agent-conversation-scroll] [data-block-id]",
    (nodes) => nodes.map((node) => node.textContent || ""));
  return [...new Set(messageNumbers(texts))].sort((a, b) => a - b);
}

async function scrollToTop(page) {
  await page.evaluate(() => {
    const root = conversationScrollRoot();
    if (root === document.scrollingElement || root === document.documentElement) window.scrollTo(0, 0);
    else root.scrollTop = 0;
  });
}

module.exports = async function ({ browser, baseUrl, agentKey, captureDir }) {
  const context = await browser.newContext({ viewport: { width: 430, height: 900 } });
  const page = await context.newPage();
  const conversationRequests = [];
  const responses = [];
  page.on("request", (request) => {
    const url = new URL(request.url());
    if (/\/agents\/[^/]+\/conversation$/.test(url.pathname)) conversationRequests.push(url.searchParams);
  });
  page.on("response", async (response) => {
    const url = new URL(response.url());
    if (!/\/agents\/[^/]+\/conversation$/.test(url.pathname)) return;
    const body = await response.json().catch(() => null);
    if (body) responses.push({ before: url.searchParams.get("before"), blocks: body.conversation.length, total: body.conversation_block_count, hasOlder: body.conversation_has_older });
  });

  await page.goto(`${baseUrl}/ui#agent/${encodeURIComponent(agentKey)}`, { waitUntil: "networkidle" });
  await page.waitForSelector("[data-agent-conversation-scroll]", { timeout: 10000 });
  await page.waitForSelector("[data-load-older-conversation]", { timeout: 10000 });
  await page.waitForTimeout(500);

  // First paint: only the newest window is fetched and rendered.
  const first = responses[0];
  assert.ok(first, "expected a conversation response");
  assert.equal(first.before, null, "first paint must not use before paging");
  assert.equal(first.blocks, FIRST_PAINT_BLOCKS, "first paint returns the last 50 blocks");
  assert.ok(first.total >= SEEDED_MESSAGES, `expected total >= ${SEEDED_MESSAGES}, got ${first.total}`);
  assert.equal(first.hasOlder, true);
  assert.equal(conversationRequests.filter((params) => params.has("before")).length, 0, "no older page before scrolling");
  const initial = await renderedMessageNumbers(page);
  assert.ok(initial.length > 0 && initial.length <= FIRST_PAINT_BLOCKS, `rendered ${initial.length} seeded messages`);
  assert.equal(initial[initial.length - 1], SEEDED_MESSAGES - 1, "newest message is rendered");
  const oldestInitial = initial[0];
  assert.ok(oldestInitial > SEEDED_MESSAGES - FIRST_PAINT_BLOCKS - 5, `oldest rendered ${oldestInitial} should be in the tail`);
  if (captureDir) await page.screenshot({ path: path.join(captureDir, "after-first-paint.png") });

  // Scrolling to the top loads exactly one older page and keeps the reader in place.
  const anchorText = `Tail message ${oldestInitial}.`;
  const older = page.waitForResponse((response) => /conversation\?/.test(response.url()) && response.url().includes("before=50"));
  await scrollToTop(page);
  await older;
  await page.waitForFunction((count) => document.body.textContent.includes(`Tail message ${count}.`), oldestInitial - 1, { timeout: 10000 });
  await page.waitForTimeout(500);
  const beforeParams = conversationRequests.filter((params) => params.has("before"));
  assert.equal(beforeParams.length, 1, `expected one older-page request, saw ${beforeParams.length}`);
  assert.equal(beforeParams[0].get("before"), String(FIRST_PAINT_BLOCKS));
  assert.equal(beforeParams[0].get("limit"), String(FIRST_PAINT_BLOCKS));

  const expanded = await renderedMessageNumbers(page);
  assert.ok(expanded[0] < oldestInitial, "older messages were prepended");
  assert.equal(new Set(expanded).size, expanded.length, "no duplicated messages");
  assert.equal(expanded.every((value, index) => index === 0 || value === expanded[index - 1] + 1), true, "pages join without a gap");
  const anchorVisible = await page.evaluate((text) => {
    const node = [...document.querySelectorAll("[data-agent-conversation-scroll] *")]
      .find((element) => element.children.length === 0 && (element.textContent || "").includes(text)) ||
      [...document.querySelectorAll("*")].find((element) => element.children.length === 0 && (element.textContent || "").includes(text));
    if (!node) return false;
    const rect = node.getBoundingClientRect();
    return rect.bottom > 0 && rect.top < window.innerHeight;
  }, anchorText);
  assert.equal(anchorVisible, true, "the message the reader was viewing stays in view after prepending");
  if (captureDir) await page.screenshot({ path: path.join(captureDir, "after-older-page.png") });

  await context.close();
};
