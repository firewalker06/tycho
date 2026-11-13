// Run from the repository root. All server files and projects use a temp home.
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const net = require("node:net");
const { spawn } = require("node:child_process");
const assert = require("node:assert/strict");
const { chromium } = require(process.env.TYCHO_PLAYWRIGHT_PATH || "playwright");

async function assertProjectKeyOwnership(page, label, capture) {
  const name = page.getByLabel("Name", { exact: true });
  const key = page.getByLabel("Project key", { exact: true });
  const destination = page.locator("[data-project-destination]");
  const options = page.locator("#new-project-options");
  const openOptions = async () => { if (!await options.evaluate(el => el.open)) await options.locator("summary").click(); };
  const reload = async () => {
    await page.reload();
    await name.waitFor();
    await page.waitForFunction(() => state.projectCreation && !state.refreshInFlight && document.getElementById("tycho-boot-shell").hidden);
  };
  await name.fill("Atlas second");
  assert.equal(await key.inputValue(), "atlas-second", "untouched key must follow Name");
  await openOptions();
  await key.fill("custom");
  await name.fill("Custom");
  await name.fill("Other");
  assert.equal(await key.inputValue(), "custom", "matching Name must not reclaim a custom key");
  await options.locator("summary").click();
  await name.fill("Custom");
  await name.fill("Other");
  await name.focus();
  await page.evaluate(() => refresh({ force: true }));
  assert.equal(await page.evaluate(() => document.activeElement.id), "new-project-name");
  assert.equal(await key.inputValue(), "custom", "closed options and polling must preserve manual mode");
  assert.equal(await destination.textContent(), "~/tycho-projects/custom");
  // Force a real DOM replacement without a stored draft: same-route memory
  // must preserve ownership too, even when draft storage is unavailable.
  assert.equal(await page.evaluate(() => {
    const before = document.getElementById("new-project-form");
    safeLocalStorageRemove(formDraftStorageKey(before));
    state.renderedViewHtml = "";
    render();
    return before !== document.getElementById("new-project-form");
  }), true);
  await name.fill("Custom");
  await name.fill("Other");
  assert.equal(await key.inputValue(), "custom", "rerender must preserve manual ownership");
  await reload();
  await name.fill("Custom");
  await name.fill("Other");
  assert.equal(await key.inputValue(), "custom", "modern draft reload must retain manual mode");
  // A draft from the previous release has values but no ownership metadata.
  await name.fill("Custom");
  await name.blur();
  await page.evaluate(() => {
    const storageKey = formDraftStorageKey(document.getElementById("new-project-form"));
    const draft = JSON.parse(safeLocalStorageGet(storageKey));
    delete draft.projectKeyMode;
    safeLocalStorageSet(storageKey, JSON.stringify(draft));
  });
  await reload();
  assert.equal(await page.evaluate(() => {
    const draft = JSON.parse(safeLocalStorageGet(formDraftStorageKey(document.getElementById("new-project-form"))));
    return Object.hasOwn(draft, "projectKeyMode");
  }), false, "legacy regression must actually load a draft without mode metadata");
  await name.fill("Other");
  assert.equal(await key.inputValue(), "custom", "legacy matching draft must be kept manual");
  await openOptions();
  await page.evaluate(() => window.scrollTo(0, 0));
  await page.screenshot({ path: path.join(capture, `${label}-manual-key.png`), fullPage: false });
  await key.fill("");
  await name.fill("");
  await reload();
  await name.fill("After reload");
  assert.equal(await key.inputValue(), "", "an entirely cleared manual draft must not resume automatic mode");
  await openOptions();
  await page.getByRole("button", { name: "Use name", exact: true }).click();
  assert.equal(await key.inputValue(), "after-reload", "explicit reset must derive the current Name");
  await reload();
  await name.fill("Automatic again");
  assert.equal(await key.inputValue(), "automatic-again", "automatic reset must survive reload");
  await openOptions();
  await page.locator("#new-project-folder-options > summary").click();
  const folder = page.getByLabel("Folder path", { exact: true });
  const explicitFolder = `~/code/kept-${label}`;
  await folder.fill(explicitFolder);
  await name.fill("Custom");
  await key.fill("custom"); // Intentional edit even when it equals the generated key.
  await name.fill("Other");
  assert.equal(await key.inputValue(), "custom", "editing to the same value still transfers ownership");
  assert.equal(await folder.inputValue(), explicitFolder);
  assert.equal(await destination.textContent(), explicitFolder);
  await page.getByRole("button", { name: "Use name", exact: true }).click();
  await name.fill("Atlas");
  assert.equal(await key.inputValue(), "atlas");
  assert.equal(await destination.textContent(), explicitFolder, "key reset and Name changes must not alter a custom folder");
  await folder.fill("");
  assert.equal(await destination.textContent(), "~/tycho-projects/atlas", "only clearing the folder restores its default");
  await page.locator("#new-project-folder-options > summary").click();
  await options.locator("summary").click();
}

(async () => {
  const root = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), "tycho-project-create-")));
  const home = path.join(root, "home");
  const capture = process.env.TYCHO_REMOTE_UI_CAPTURE_DIR || path.join(root, "captures");
  fs.mkdirSync(home);
  fs.mkdirSync(capture, { recursive: true });
  const tychoHome = path.join(home, ".tycho");
  fs.mkdirSync(tychoHome);
  const config = path.join(root, "hq.yml");
  const prompts = path.join(root, "prompts.yml");
  fs.writeFileSync(config, "projects: []\n");
  fs.writeFileSync(prompts, 'custom: "Inspect this workspace."\n');
  const socket = net.createServer();
  await new Promise(resolve => socket.listen(0, "127.0.0.1", resolve));
  const port = socket.address().port;
  await new Promise(resolve => socket.close(resolve));
  const base = `http://127.0.0.1:${port}`;
  const log = fs.openSync(path.join(capture, "server.log"), "w");
  const server = spawn("bundle", ["exec", "ruby", "test/browser/project_creation_server.rb", "serve", "--host", "127.0.0.1", "--port", String(port)], {
    cwd: path.resolve(__dirname, "../.."),
    env: { ...process.env, TYCHO_PROJECT_TEST_HOME: home, TYCHO_HOME: tychoHome,
      TYCHO_CONFIG_PATH: config, TYCHO_SYSTEM_PROMPTS_PATH: prompts, TYCHO_LOGS_ROOT: path.join(root, "logs"),
      TYCHO_SCHEDULES_PATH: path.join(root, "schedules.yml"), TYCHO_REMOTE_TOKEN: "", TYCHO_GITHUB_TOKEN: "" },
    stdio: ["ignore", log, log],
  });
  let browser;
  try {
    for (let i = 0; ; i++) {
      try { if ((await fetch(`${base}/projects`)).ok) break; } catch {}
      if (i >= 120 || server.exitCode !== null) throw new Error("Fixture server did not start");
      await new Promise(resolve => setTimeout(resolve, 250));
    }
    browser = await chromium.launch({ headless: true, executablePath: process.env.CHROME_PATH || "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" });
    const results = [];
    for (const [label, width, height] of [["desktop-dark", 1440, 1000], ["mobile-dark", 390, 844], ["desktop-light", 1440, 1000], ["mobile-light", 390, 844]]) {
      const context = await browser.newContext({ viewport: { width, height }, colorScheme: label.endsWith("light") ? "light" : "dark" });
      await context.addInitScript(theme => localStorage.setItem("hq.remote.appearance", theme), label.endsWith("light") ? "light" : "dark");
      const page = await context.newPage();
      page.setDefaultTimeout(15000);
      console.log(`${label}: open form`);
      const errors = [];
      page.on("pageerror", error => errors.push(error.message));
      await page.goto(`${base}/ui#agents`);
      await page.getByRole("button", { name: "New project", exact: true }).click();
      await page.waitForFunction(() => state.projectCreation && !state.refreshInFlight && document.getElementById("tycho-boot-shell").hidden);
      await page.evaluate(() => Promise.all(document.getAnimations().filter(animation => animation.effect?.getComputedTiming().iterations !== Infinity).map(animation => animation.finished.catch(() => {}))));
      await page.getByLabel("Name", { exact: true }).fill("Atlas");
      assert.equal(await page.locator("#new-project-key").inputValue(), "atlas");
      assert.equal(await page.locator("[data-project-destination]").textContent(), "~/tycho-projects/atlas");
      assert.equal(await page.locator("#new-project-options").evaluate(el => el.open), false);
      assert.equal(await page.locator("html").getAttribute("data-appearance"), label.endsWith("light") ? "light" : "dark");
      await page.evaluate(() => window.scrollTo(0, 0));
      const formBox = await page.locator("#new-project-form").boundingBox();
      assert(formBox.width <= 720, "desktop form must remain compact");
      await page.screenshot({ path: path.join(capture, `${label}-form.png`), fullPage: false });
      await assertProjectKeyOwnership(page, label, capture);
      await page.locator("#new-project-options > summary").click();
      await page.getByLabel("Project key", { exact: true }).fill("Invalid key");
      await page.locator("#new-project-options > summary").click();
      await page.getByRole("button", { name: "Create project", exact: true }).click();
      assert.equal(await page.locator("#new-project-options").evaluate(el => el.open), true, "invalid hidden key must be revealed");
      assert.equal(await page.evaluate(() => document.activeElement.id), "new-project-key", "native validation must focus the key");
      assert.equal(await page.getByLabel("Project key", { exact: true }).evaluate(input => input.checkValidity()), false);
      await page.getByLabel("Project key", { exact: true }).fill(label);
      await page.getByLabel("Name", { exact: true }).fill(label);
      await page.getByLabel("Name", { exact: true }).fill(`${label} project`);
      assert.equal(await page.getByLabel("Project key", { exact: true }).inputValue(), label, "edited key must survive name changes");
      await page.locator("#new-project-folder-options > summary").click();
      await page.getByLabel("Folder path", { exact: true }).fill(path.join(root, "outside"));
      console.log(`${label}: submit`);
      await page.getByRole("button", { name: "Create project", exact: true }).click();
      await page.getByRole("alert").filter({ hasText: "inside the server user home" }).waitFor();
      assert.equal(await page.getByLabel("Name", { exact: true }).inputValue(), `${label} project`);
      assert(!fs.existsSync(path.join(root, "outside")));
      await page.screenshot({ path: path.join(capture, `${label}-error.png`), fullPage: true });
      await page.getByLabel("Folder path", { exact: true }).fill("");
      // A forced real refresh must keep entered values and the focused input.
      await page.getByLabel("Group (optional)").fill("Personal");
      await page.getByLabel("Name", { exact: true }).focus();
      await page.evaluate(() => refresh({ force: true }));
      assert.equal(await page.getByLabel("Name", { exact: true }).inputValue(), `${label} project`);
      assert.equal(await page.evaluate(() => document.activeElement.id), "new-project-name");
      assert.equal(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth), true);
      assert.equal(await page.getByLabel("Group (optional)").inputValue(), "Personal");
      assert.equal(await page.locator("#new-project-options").evaluate(el => el.open), true, "disclosure state must survive polling");
      const heights = await page.locator("#new-project-form input").evaluateAll(inputs => inputs.map(i => i.getBoundingClientRect().height));
      assert(heights.every(h => h === 44), "all input heights must match");
      const keyBox = await page.getByLabel("Project key", { exact: true }).boundingBox();
      const groupBox = await page.getByLabel("Group (optional)").boundingBox();
      if (width >= 760) assert.equal(keyBox.y, groupBox.y, "secondary inputs must align");
      await page.reload();
      await page.getByLabel("Name", { exact: true }).waitFor();
      await page.waitForFunction(() => state.projectCreation && !state.refreshInFlight && document.getElementById("tycho-boot-shell").hidden);
      await page.locator("#new-project-options > summary").click();
      assert.equal(await page.getByLabel("Project key", { exact: true }).inputValue(), label, "edited key draft must survive reload");
      assert.equal(await page.getByLabel("Group (optional)").inputValue(), "Personal", "group draft must survive reload");
      await page.locator("#new-project-folder-options > summary").click();
      await page.screenshot({ path: path.join(capture, `${label}-options.png`), fullPage: false });
      await page.getByRole("button", { name: "Create project", exact: true }).scrollIntoViewIfNeeded();
      if (width < 760) {
        await page.getByLabel("Group (optional)").scrollIntoViewIfNeeded();
        const field = await page.getByLabel("Group (optional)").boundingBox();
        const actions = await page.getByRole("button", { name: "Create project", exact: true }).boundingBox();
        assert(field.y + field.height <= actions.y, "bottom field must clear the sticky actions");
      }
      console.log(`${label}: submit`);
      assert.equal(await page.locator("[data-project-destination]").textContent(), `~/tycho-projects/${label}`);
      const created = page.waitForResponse(response => response.request().method() === "POST" && new URL(response.url()).pathname === "/projects" && response.status() === 201);
      await page.getByRole("button", { name: "Create project", exact: true }).click();
      const submitted = await (await created).json();
      assert.equal(submitted.project.key, label, "submission must retain the custom key");
      assert.equal(submitted.project.path, path.join(home, "tycho-projects", label), "submitted path must match the preview");
      await page.waitForURL(new RegExp(`#project/${label}$`));
      await page.getByRole("button", { name: "New agent", exact: true }).first().waitFor();
      const folder = path.join(home, "tycho-projects", label);
      assert(fs.statSync(folder).isDirectory());
      assert(fs.readFileSync(config, "utf8").includes(folder));
      await page.waitForFunction(() => !document.querySelector(".onboarding-panel") && document.querySelector("[data-create-agent]"));
      await page.screenshot({ path: path.join(capture, `${label}-created.png`), fullPage: false });
      await page.reload();
      await page.getByRole("button", { name: "New agent", exact: true }).first().waitFor();
      await page.goto(`${base}/ui#agents`);
      await page.getByRole("button", { name: "New project", exact: true }).click();
      await page.getByLabel("Name", { exact: true }).fill("Duplicate");
      await page.locator("#new-project-options > summary").click();
      await page.getByLabel("Project key", { exact: true }).fill(label);
      console.log(`${label}: submit`);
      await page.getByRole("button", { name: "Create project", exact: true }).click();
      await page.getByRole("alert").filter({ hasText: "Duplicate project key" }).waitFor();
      await page.getByRole("button", { name: "Cancel", exact: true }).click();
      await page.waitForURL(/#agents$/);
      const custom = path.join(home, "code", label);
      fs.mkdirSync(custom, { recursive: true });
      fs.writeFileSync(path.join(custom, "keep.txt"), "Keep this file");
      await page.getByRole("button", { name: "New project", exact: true }).click();
      await page.getByLabel("Name", { exact: true }).fill(`${label} existing`);
      await page.locator("#new-project-folder-options > summary").focus();
      await page.keyboard.press("Enter");
      await page.getByLabel("Folder path", { exact: true }).fill(`~/code/${label}`);
      assert.equal(await page.locator("[data-project-destination]").textContent(), `~/code/${label}`);
      const existing = page.waitForResponse(response => response.request().method() === "POST" && new URL(response.url()).pathname === "/projects" && response.status() === 201);
      await page.getByRole("button", { name: "Create project", exact: true }).click();
      assert.equal((await (await existing).json()).project.path, custom, "custom folder must be used exactly as previewed");
      await page.waitForURL(new RegExp(`#project/${label}-existing$`));
      assert.equal(fs.readFileSync(path.join(custom, "keep.txt"), "utf8"), "Keep this file");
      assert(fs.readFileSync(config, "utf8").includes(custom), "custom input is the final folder, not a parent");
      assert.deepEqual(errors, []);
      results.push({ label, width, height, created: true, outsideRejected: true, duplicateRejected: true, refreshDraftFocus: true, derivedKey: true, explicitManualOwnership: true, legacyDraft: true, clearedManualDraft: true, deliberateReset: true, rerenderWithoutStorage: true, submittedPreviewMatches: true, editedKeyReload: true, hiddenValidationFocus: true, customExistingFolder: true, theme: label.endsWith("light") ? "light" : "dark", overflow: false });
      await context.close();
    }
    fs.writeFileSync(path.join(capture, "results.json"), JSON.stringify(results, null, 2));
    console.log(JSON.stringify({ status: "passed", capture, results }));
  } finally {
    await browser?.close();
    server.kill("SIGTERM");
    await new Promise(resolve => {
      if (server.exitCode !== null) return resolve();
      const timeout = setTimeout(() => { server.kill("SIGKILL"); resolve(); }, 5000);
      server.once("exit", () => { clearTimeout(timeout); resolve(); });
    });
    fs.closeSync(log);
    if (process.env.TYCHO_REMOTE_UI_CAPTURE_DIR) fs.rmSync(root, { recursive: true, force: true });
  }
})().catch(error => { console.error(error); process.exitCode = 1; });
