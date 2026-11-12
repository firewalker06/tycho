// Run from the repository root. All server files and projects use a temp home.
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const net = require("node:net");
const { spawn } = require("node:child_process");
const assert = require("node:assert/strict");
const { chromium } = require(process.env.TYCHO_PLAYWRIGHT_PATH || "playwright");

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
    for (const [label, width, height] of [["desktop", 1440, 1000], ["mobile", 390, 844]]) {
      const context = await browser.newContext({ viewport: { width, height } });
      const page = await context.newPage();
      page.setDefaultTimeout(15000);
      console.log(`${label}: open form`);
      const errors = [];
      page.on("pageerror", error => errors.push(error.message));
      await page.goto(`${base}/ui#agents`);
      await page.getByRole("button", { name: "New project", exact: true }).click();
      await page.waitForFunction(() => state.projectCreation && !state.refreshInFlight && document.getElementById("tycho-boot-shell").hidden);
      await page.evaluate(() => Promise.all(document.getAnimations().filter(animation => animation.effect?.getComputedTiming().iterations !== Infinity).map(animation => animation.finished.catch(() => {}))));
      await page.getByLabel("Name", { exact: true }).fill(`${label} project`);
      await page.getByLabel("Project key", { exact: true }).fill("Invalid key");
      assert.equal(await page.getByLabel("Project key", { exact: true }).evaluate(input => input.checkValidity()), false);
      await page.getByLabel("Project key", { exact: true }).fill(label);
      await page.screenshot({ path: path.join(capture, `${label}-form.png`), fullPage: false });
      await page.getByLabel("Server folder (optional)").fill(path.join(root, "outside"));
      console.log(`${label}: submit`);
      await page.getByRole("button", { name: "Create project", exact: true }).click();
      await page.getByRole("alert").filter({ hasText: "inside the server user home" }).waitFor();
      assert.equal(await page.getByLabel("Name", { exact: true }).inputValue(), `${label} project`);
      assert(!fs.existsSync(path.join(root, "outside")));
      await page.screenshot({ path: path.join(capture, `${label}-error.png`), fullPage: true });
      await page.getByLabel("Server folder (optional)").fill("");
      // A forced real refresh must keep entered values and the focused input.
      await page.getByLabel("Name", { exact: true }).focus();
      await page.evaluate(() => refresh({ force: true }));
      assert.equal(await page.getByLabel("Name", { exact: true }).inputValue(), `${label} project`);
      assert.equal(await page.evaluate(() => document.activeElement.id), "new-project-name");
      assert.equal(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth), true);
      await page.getByRole("button", { name: "Create project", exact: true }).scrollIntoViewIfNeeded();
      if (label === "mobile") {
        await page.getByLabel("Group (optional)").scrollIntoViewIfNeeded();
        const field = await page.getByLabel("Group (optional)").boundingBox();
        const actions = await page.getByRole("button", { name: "Create project", exact: true }).boundingBox();
        assert(field.y + field.height <= actions.y, "bottom field must clear the sticky actions");
      }
      console.log(`${label}: submit`);
      await page.getByRole("button", { name: "Create project", exact: true }).click();
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
      await page.getByLabel("Project key", { exact: true }).fill(label);
      console.log(`${label}: submit`);
      await page.getByRole("button", { name: "Create project", exact: true }).click();
      await page.getByRole("alert").filter({ hasText: "Duplicate project key" }).waitFor();
      await page.getByRole("button", { name: "Cancel", exact: true }).click();
      await page.waitForURL(/#agents$/);
      assert.deepEqual(errors, []);
      results.push({ label, width, height, created: true, outsideRejected: true, duplicateRejected: true, refreshDraftFocus: true, overflow: false });
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
