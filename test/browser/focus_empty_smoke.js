const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");

module.exports = async ({ browser, baseUrl, agentKey, captureDir }) => {
  const api = await browser.newContext();
  const url = `${baseUrl}/agents/${agentKey}/focus`;
  const read = async () => (await (await api.request.get(url)).json()).focus;
  const write = async sections => {
    const current = await read();
    const response = await api.request.put(url, { data: { revision: current.revision, sections } });
    assert(response.ok(), await response.text());
  };
  await write([]);
  const image = await api.request.get(`${baseUrl}/focus-zen.png`);
  assert.equal(image.status(), 200);
  assert.match(image.headers()["content-type"], /image\/png/);
  const results = [];
  for (const width of [1440, 390]) for (const theme of ["dark", "light"]) {
    const context = await browser.newContext({ viewport: { width, height: 900 }, isMobile: width < 500, hasTouch: width < 500 });
    const page = await context.newPage();
    const errors = [];
    page.on("pageerror", error => errors.push(error.message));
    await page.goto(`${baseUrl}/ui#settings`, { waitUntil: "networkidle" });
    await page.locator("[data-appearance-preference]").selectOption(theme);
    await page.goto(`${baseUrl}/ui#agent/${agentKey}`, { waitUntil: "networkidle" });
    await page.locator('.side-conversation-controls [data-side-conversation="focus"]').click();
    const empty = page.locator(".agent-focus-empty-state");
    await empty.waitFor({ state: "visible" });
    await page.waitForFunction(() => document.querySelector(".agent-focus-empty-state img")?.naturalWidth === 384);
    assert.equal(await empty.innerText(), "Nothing in the Focus board");
    const geometry = await empty.evaluate(e => {
      const box = e.getBoundingClientRect(), body = e.parentElement.getBoundingClientRect();
      const image = e.querySelector("img").getBoundingClientRect();
      return { width: box.width, bodyWidth: body.width, height: box.height, bodyHeight: body.height,
        centerError: Math.abs((image.left + image.width / 2) - (box.left + box.width / 2)),
        bottom: box.bottom, dockTop: document.querySelector("[data-agent-dock]").getBoundingClientRect().top,
        overflow: document.documentElement.scrollWidth > innerWidth };
    });
    assert(Math.abs(geometry.width - geometry.bodyWidth) <= 2, JSON.stringify(geometry));
    assert(Math.abs(geometry.height - geometry.bodyHeight) <= 2, JSON.stringify(geometry));
    assert(geometry.centerError <= 1 && !geometry.overflow, JSON.stringify(geometry));
    if (width < 500) assert(geometry.bottom <= geometry.dockTop + 1, JSON.stringify(geometry));
    await page.locator("#prompt-input").fill("Keep the draft.");
    await page.evaluate(() => refresh({ force: true }));
    await empty.waitFor({ state: "visible" });
    assert.equal(await page.locator("#prompt-input").inputValue(), "Keep the draft.");
    if (captureDir) {
      fs.mkdirSync(captureDir, { recursive: true });
      await page.evaluate(() => document.fonts.ready);
      await page.screenshot({ path: path.join(captureDir, `focus-empty-${width}-${theme}.png`), animations: "disabled" });
    }
    await write([{ title: "Work", items: [{ title: "Real Focus item" }] }]);
    await page.evaluate(key => refreshAgentFocus(key), agentKey);
    await page.getByText("Real Focus item", { exact: true }).waitFor();
    assert.equal(await empty.count(), 0);
    await write([]);
    await page.evaluate(key => refreshAgentFocus(key), agentKey);
    await empty.waitFor({ state: "visible" });
    assert.deepEqual(errors, []);
    results.push({ width, theme, geometry });
    await context.close();
  }
  if (captureDir) fs.writeFileSync(path.join(captureDir, "focus-empty-results.json"), JSON.stringify(results, null, 2));
  console.log(JSON.stringify(results));
  await api.close();
};
