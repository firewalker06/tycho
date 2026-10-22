const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");

module.exports = async ({ browser, baseUrl, captureDir }) => {
  const results = [];
  for (const viewport of [{ width: 1440, height: 900 }, { width: 390, height: 844 }]) {
    const context = await browser.newContext({ viewport, isMobile: viewport.width < 500, hasTouch: viewport.width < 500 });
    const page = await context.newPage();
    const errors = [];
    page.on("pageerror", error => errors.push(error.message));
    await page.goto(`${baseUrl}/ui#agents`, { waitUntil: "networkidle" });
    await page.locator("#quick-agent-fab").click();
    const name = page.locator("#quick-agent-name");
    await name.waitFor({ state: "visible" });
    assert.equal(await name.inputValue(), "");
    assert.equal(await name.getAttribute("required"), null);
    await page.locator("#quick-agent-prompt").fill("Check the export output.");
    // Options and polling must not lose either input.
    await name.fill("Manual Export");
    await page.locator("[data-quick-agent-toggle]").click();
    assert.equal(await name.inputValue(), "Manual Export");
    assert.equal(await page.locator("#quick-agent-prompt").inputValue(), "Check the export output.");
    await name.fill("");
    await page.evaluate(() => refresh({ force: true }));
    assert.equal(await name.inputValue(), "");
    const layout = await page.locator("#quick-agent-dialog").evaluate(el => {
      const box = el.getBoundingClientRect();
      return { left: box.left, right: box.right, width: innerWidth, scroll: document.documentElement.scrollWidth };
    });
    assert(layout.left >= 0 && layout.right <= viewport.width + 1 && layout.scroll <= viewport.width + 1);
    if (captureDir) await page.screenshot({ path: path.join(captureDir, `auto-name-form-${viewport.width}.png`) });
    const responsePromise = page.waitForResponse(response => response.url() === `${baseUrl}/agents` && response.request().method() === "POST");
    await page.locator("#quick-agent-form button[type=submit]").click();
    const response = await responsePromise;
    assert(response.ok());
    assert(!Object.hasOwn(response.request().postDataJSON(), "name"));
    const { agent } = await response.json();
    assert.match(agent.name, /^Web custom \d+$/);
    await page.waitForFunction(async ({baseUrl, key}) => {
      const data = await (await fetch(`${baseUrl}/agents/${key}`)).json();
      return data.agent.name === "Export Check" && data.agent.status === "success";
    }, { baseUrl, key: agent.key });
    await page.evaluate(() => refresh({ force: true }));
    await page.getByRole("heading", { name: "Export Check", exact: true }).waitFor({ state: "visible" });
    if (captureDir) await page.screenshot({ path: path.join(captureDir, `auto-name-result-${viewport.width}.png`) });
    await page.goto(`${baseUrl}/ui#agents`, { waitUntil: "networkidle" });
    await page.locator("#quick-agent-fab").click();
    await page.locator("#quick-agent-name").fill("Manual Export");
    await page.locator("#quick-agent-prompt").fill("Keep this name.");
    const explicitResponse = page.waitForResponse(response => response.url() === `${baseUrl}/agents` && response.request().method() === "POST");
    await page.locator("#quick-agent-form button[type=submit]").click();
    const explicit = await (await explicitResponse).json();
    await page.waitForFunction(async ({baseUrl, key}) => {
      const data = await (await fetch(`${baseUrl}/agents/${key}`)).json();
      return data.agent.status === "success" && data.agent.name === "Manual Export";
    }, { baseUrl, key: explicit.agent.key });
    assert.deepEqual(errors, []);
    results.push({ viewport: viewport.width, optionalName: true, autoName: "Export Check", manualName: "Manual Export", overflow: false });
    await context.close();
  }
  if (captureDir) fs.writeFileSync(path.join(captureDir, "browser-results.json"), JSON.stringify(results, null, 2));
  console.log("agent-auto-name-smoke: ok", JSON.stringify(results));
};
