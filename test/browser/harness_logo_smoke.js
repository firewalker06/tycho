const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");

module.exports = async function harnessLogoSmoke({ page, baseUrl, captureDir, agentKey }) {
  const created = await page.request.post(`${baseUrl}/agents`, { data: { project_key: "web", template_key: "custom", name: "Antigravity logo fixture", prompt: "Synthetic display only", agent: "agy", start: false } });
  assert.equal(created.status(), 201);
  agentKey = (await created.json()).agent.key;
  const fixture = await (await page.request.get(`${baseUrl}/setup`)).json();
  fixture.setup.harnesses = [{ name: "agy", ready: true, detail: "Antigravity fixture", commands: ["agy"], auth_snapshot: { state: "authenticated" }, model_suggestions: [] }];
  fixture.setup.skill_installation = { harnesses: [{ harness: "agy", status: "installed", target_path: "fixture/skills", skills: [{ name: "tycho" }], actions: {} }] };
  await page.route("**/setup", route => route.fulfill({ json: fixture }));
  const asset = await page.request.get(`${baseUrl}/harness-logos/antigravity-icon-one-color.svg`);
  assert.equal(asset.status(), 200);
  assert.match(asset.headers()["content-type"], /image\/svg\+xml/);
  const capture = async name => {
    if (captureDir) { fs.mkdirSync(captureDir, { recursive: true }); await page.screenshot({ path: path.join(captureDir, `${name}.png`) }); }
  };
  for (const width of [1440, 390]) {
    await page.setViewportSize({ width, height: width === 390 ? 844 : 900 });
    for (const mode of ["dark", "light", "system"]) {
      await page.emulateMedia({ colorScheme: "light", reducedMotion: "reduce" });
      await page.goto(`${baseUrl}/ui#settings`, { waitUntil: "networkidle" });
      await page.evaluate(mode => { localStorage.setItem("hq.remote.appearance", mode); }, mode);
      await page.reload({ waitUntil: "networkidle" });
      await page.locator('[data-harness-name="agy"]').waitFor({ state: "attached" });
      await page.locator('[aria-controls="settings-panel-automation"]').click();
      if (await page.locator(".automation-ready-details").getAttribute("open") === null) await page.locator(".automation-ready-details > summary").click();
      const mark = page.locator('[data-harness-name="agy"] > summary .harness-mark');
      await mark.scrollIntoViewIfNeeded();
      assert(await mark.isVisible());
      assert.equal(await mark.getAttribute("aria-hidden"), "true");
      assert.match(await mark.evaluate(el => getComputedStyle(el).maskImage), /antigravity-icon-one-color.svg/);
      const color = await mark.evaluate(el => getComputedStyle(el).color);
      assert.equal(color, mode === "dark" ? "rgb(255, 255, 255)" : "rgb(76, 86, 106)");
      assert.match(await mark.locator("..").innerText(), /agy/);
      await capture(`antigravity-${width}-${mode}-catalog`);
      await page.locator('[aria-controls="settings-panel-skills"]').click();
      if (await page.locator('[data-state-key="skill-installation-details"]').getAttribute("open") === null) await page.locator('[data-state-key="skill-installation-details"] > summary').click();
      assert(await page.locator('.skill-installation-row .harness-mark').first().isVisible());
      await capture(`antigravity-${width}-${mode}-skills`);
      await page.goto(`${baseUrl}/ui#agent/${agentKey}`, { waitUntil: "networkidle" });
      await page.locator("#prompt-input").waitFor({ state: "visible" });
      await page.locator("#header-more-button").click();
      await page.locator("[data-toggle-agent-settings]").click();
      const settingsMark = page.locator('#agent-settings-panel .harness-mark');
      await settingsMark.waitFor({ state: "visible" });
      await settingsMark.evaluate(el => el.scrollIntoView({ block: "center", behavior: "instant" }));
      await capture(`antigravity-${width}-${mode}-agent-settings`);
      await page.evaluate(agentKey => navigate({ type: "agentArchive", key: agentKey }), agentKey);
      await page.locator('.archive-dialog .harness-mark').waitFor({ state: "visible" });
      await capture(`antigravity-${width}-${mode}-archive`);
      await page.goto(`${baseUrl}/ui#agents`, { waitUntil: "networkidle" });
      const row = page.locator(`[data-open-agent="${agentKey}"]`).filter({ has: page.locator('.harness-mark') }).first();
      await row.waitFor({ state: "visible" });
      await row.scrollIntoViewIfNeeded();
      await capture(`antigravity-${width}-${mode}-agent-list`);
      const checks = await page.evaluate(agentKey => {
        const agent = findAgent(agentKey);
        const meta = document.createElement("div"); meta.innerHTML = agentListSubtextHtml(agent);
        const archive = document.createElement("div"); archive.innerHTML = harnessLabelHtml(agent.agent);
        return { metaMark: !!meta.querySelector('.harness-mark'), archiveLabel: archive.textContent,
          unknown: harnessMarkHtml("custom-agy"), overflow: document.documentElement.scrollWidth > innerWidth };
      }, agentKey);
      assert(checks.metaMark); assert.equal(checks.archiveLabel, "agy"); assert.equal(checks.unknown, ""); assert(!checks.overflow);
      await page.evaluate(() => navigate({ type: "agentForm", mode: "create", projectKey: "web" }));
      await page.locator('select option[value="agy"]').first().waitFor({ state: "attached" });
      // Native selectors retain their accessible option text and no image markup.
      const options = page.locator('select option[value="agy"]');
      assert(await options.count() > 0);
      assert.equal(await options.first().textContent(), "agy");
      assert.equal(await options.first().locator('.harness-mark').count(), 0);
      await capture(`antigravity-${width}-${mode}-new-agent`);
    }
  }
  console.log("harness_logo_smoke: desktop/mobile Dark/Light/System shared marks and native selectors passed");
};
