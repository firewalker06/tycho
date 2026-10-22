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
    const name = page.locator("#quick-agent-name");
    const prompt = page.locator("#quick-agent-prompt");
    const toggle = page.locator("[data-quick-agent-toggle]");
    const checkLayout = async () => {
      const layout = await page.locator("#quick-agent-dialog").evaluate(el => {
        const box = el.getBoundingClientRect();
        return { left: box.left, right: box.right, width: innerWidth, scroll: document.documentElement.scrollWidth };
      });
      assert(layout.left >= 0 && layout.right <= viewport.width + 1 && layout.scroll <= viewport.width + 1);
    };
    const capture = async state => {
      await checkLayout();
      if (captureDir) await page.screenshot({ path: path.join(captureDir, `auto-name-${state}-${viewport.width}.png`) });
    };
    const checkCollapsed = async () => {
      assert.equal(await toggle.getAttribute("aria-expanded"), "false");
      assert.equal(await name.isVisible(), false);
      assert.equal(await page.locator("#quick-agent-harness").isVisible(), false);
      assert.equal(await prompt.evaluate(el => document.activeElement === el), true);
      await checkLayout();
    };
    await page.goto(`${baseUrl}/ui#agents`, { waitUntil: "networkidle" });
    await page.locator("#quick-agent-fab").click();
    await prompt.waitFor({ state: "visible" });
    await checkCollapsed();
    await prompt.fill("Check the export output.");
    await capture("collapsed");
    await toggle.click();
    await name.waitFor({ state: "visible" });
    assert.equal(await name.inputValue(), "");
    assert.equal(await name.getAttribute("required"), null);
    const position = await page.evaluate(() => {
      const name = document.querySelector("#quick-agent-name");
      const section = document.querySelector("#quick-agent-options");
      const harness = document.querySelector("#quick-agent-harness");
      return { inside: section.contains(name), first: section.firstElementChild.contains(name),
        toggleBottom: document.querySelector(".quick-agent-options-row").getBoundingClientRect().bottom,
        nameTop: name.getBoundingClientRect().top, nameBottom: name.getBoundingClientRect().bottom,
        harnessTop: harness.getBoundingClientRect().top };
    });
    assert(position.inside && position.first && position.nameTop >= position.toggleBottom && position.nameBottom <= position.harnessTop);
    await capture("expanded");
    // A blank field still auto-names when creation happens with Options closed.
    await toggle.click();
    await checkCollapsed();
    await page.evaluate(() => refresh({ force: true }));
    await checkCollapsed();
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
    await capture("result");
    await page.goto(`${baseUrl}/ui#agents`, { waitUntil: "networkidle" });
    await page.locator("#quick-agent-fab").click();
    await prompt.waitFor({ state: "visible" });
    await checkCollapsed();
    await prompt.fill("Keep this name.");
    await toggle.click();
    await name.fill("Manual Export");
    await toggle.click();
    await checkCollapsed();
    await page.evaluate(() => refresh({ force: true }));
    await checkCollapsed();
    await toggle.click();
    assert.equal(await name.inputValue(), "Manual Export");
    assert.equal(await prompt.inputValue(), "Keep this name.");
    await toggle.click();
    await checkCollapsed();
    const explicitResponse = page.waitForResponse(response => response.url() === `${baseUrl}/agents` && response.request().method() === "POST");
    await page.locator("#quick-agent-form button[type=submit]").click();
    const explicitResult = await explicitResponse;
    assert(explicitResult.ok());
    assert.equal(explicitResult.request().postDataJSON().name, "Manual Export");
    const explicit = await explicitResult.json();
    await page.waitForFunction(async ({baseUrl, key}) => {
      const data = await (await fetch(`${baseUrl}/agents/${key}`)).json();
      return data.agent.status === "success" && data.agent.name === "Manual Export";
    }, { baseUrl, key: explicit.agent.key });
    assert.deepEqual(errors, []);
    results.push({ viewport: viewport.width, hiddenByDefault: true, promptFocus: true, nameFirstInOptions: true,
      collapseReopenValue: true, collapsedBlankAutoName: "Export Check", collapsedExplicitName: "Manual Export", overflow: false });
    await context.close();
  }
  if (captureDir) fs.writeFileSync(path.join(captureDir, "browser-results.json"), JSON.stringify(results, null, 2));
  console.log("agent-auto-name-smoke: ok", JSON.stringify(results));
};
