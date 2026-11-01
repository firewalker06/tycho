const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");

module.exports = async ({ browser, baseUrl, captureDir }) => {
  const agents = [];
  for (let i = 0; i < 2; i++) {
    const response = await browser.newContext();
    const created = await response.request.post(`${baseUrl}/agents`, { data: {
      project_key: "web", template_key: "custom", agent: "codex", name: "Duplicate title", prompt: "Synthetic copy fixture."
    } });
    assert(created.ok());
    agents.push((await created.json()).agent);
    await response.close();
  }
  assert.notEqual(agents[0].key, agents[1].key);
  const results = [];
  for (const [preference, os] of [["light", "light"], ["dark", "light"], ["system", "light"], ["system", "dark"]]) {
    for (const width of [1440, 390]) {
      const context = await browser.newContext({ viewport: { width, height: 900 }, colorScheme: os, hasTouch: width === 390, serviceWorkers: "block" });
      await context.addInitScript(preference => localStorage.setItem("hq.remote.appearance", preference), preference);
      const page = await context.newPage();
      for (const [index, agent] of agents.entries()) {
        await page.goto(`${baseUrl}/ui#agent/${encodeURIComponent(agent.key)}`, { waitUntil: "networkidle" });
        await page.locator("#prompt-input").waitFor({ state: "visible" });
        // Native IDs are deliberately distinct from each Tycho key.
        await page.evaluate(({ key, index }) => {
          state.agents.find(a => a.key === key).session_id = `native-provider-${index}`;
          Object.defineProperty(navigator, "clipboard", { configurable: true, value: { writeText: async value => { window.copiedValue = value; } } });
        }, { key: agent.key, index });
        const button = page.getByRole("button", { name: "Copy Session ID", exact: true });
        assert.equal(await button.getAttribute("data-copy"), agent.key);
        assert.equal(await button.getAttribute("title"), "Copy Session ID");
        await page.locator("#prompt-input").fill("Retained draft");
        const title = await page.locator("#screen-title").textContent();
        const route = page.url();
        await button.focus();
        assert(await button.evaluate(el => el === document.activeElement && getComputedStyle(el).outlineStyle !== "none"));
        if (width === 390) await button.tap(); else await button.press("Enter");
        await page.waitForFunction(() => document.querySelector(".growl.done")?.textContent === "Session ID copied");
        assert.equal(await page.evaluate(() => window.copiedValue), agent.key);
        assert.equal(await page.locator("#prompt-input").inputValue(), "Retained draft");
        assert.equal(await page.locator("#screen-title").textContent(), title);
        assert.equal(page.url(), route);
        assert.equal(await page.evaluate(() => document.documentElement.scrollWidth > innerWidth), false);
        if (captureDir && index === 0) {
          fs.mkdirSync(captureDir, { recursive: true });
          await page.screenshot({ path: path.join(captureDir, `session-id-${preference}-${os}-${width}.png`) });
        }
        await page.evaluate(() => { navigator.clipboard.writeText = async () => { throw new Error("blocked"); }; });
        await button.click();
        await page.waitForFunction(() => document.querySelector(".growl.fail")?.textContent === "Copy failed");
        await page.evaluate(() => Object.defineProperty(navigator, "clipboard", { configurable: true, value: undefined }));
        await button.click();
        await page.waitForFunction(() => document.querySelector(".growl.need")?.textContent === "Copy unavailable in this browser");
        const missing = await page.evaluate(() => {
          setHeaderTitleCopy(undefined);
          const button = document.getElementById("header-title-copy");
          return { hidden: button.classList.contains("hidden"), value: button.getAttribute("data-copy") };
        });
        assert.deepEqual(missing, { hidden: true, value: null });
      }
      await page.goto(`${baseUrl}/ui#agents`, { waitUntil: "networkidle" });
      assert.equal(await page.locator("#header-title-copy").getAttribute("data-copy"), null);
      results.push({ preference, os, width, keys: agents.map(a => a.key), passed: true });
      await context.close();
    }
  }
  console.log(JSON.stringify(results));
};
