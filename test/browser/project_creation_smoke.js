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
  const existingProjectPath = path.join(home, "tycho-projects", "existing");
  fs.mkdirSync(existingProjectPath, { recursive: true });
  fs.writeFileSync(config, `projects:\n  - key: existing\n    name: Existing project\n    path: ${JSON.stringify(existingProjectPath)}\n    agent: codex\n`);
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
      const context = await browser.newContext({ viewport: { width, height } });
      await context.addInitScript(theme => localStorage.setItem("hq.remote.appearance", theme), label.endsWith("light") ? "light" : "dark");
      const page = await context.newPage();
      page.setDefaultTimeout(15000);
      const errors = [];
      page.on("pageerror", error => errors.push(error.message));
      const posts = [];
      page.on("request", request => { if (request.method() === "POST" && new URL(request.url()).pathname === "/projects") posts.push(request.postDataJSON()); });
      const ready = async () => page.waitForFunction(() => state.projectCreation && !state.refreshInFlight && document.getElementById("tycho-boot-shell").hidden);
      const openForm = async () => {
        await page.goto(`${base}/ui#agents`);
        await page.getByRole("button", { name: "New project", exact: true }).click();
        await ready();
      };
      const name = page.getByLabel("Project Name", { exact: true });
      const key = page.getByLabel("Project Key", { exact: true });
      const options = page.locator("#new-project-options");
      const modal = page.getByRole("dialog", { name: "Project created", exact: true });
      const okay = page.getByRole("button", { name: "Okay", exact: true });
      const create = page.getByRole("button", { name: "Create project", exact: true });
      const openOptions = async () => { if (!await options.evaluate(el => el.open)) await options.locator("summary").click(); };
      const assertModal = async (expectedKey) => {
        await modal.waitFor();
        assert.equal(await modal.getByRole("button").count(), 1);
        assert.equal(await modal.getByRole("button").textContent(), "Okay");
        assert((await modal.textContent()).includes(`~/tycho-projects/${expectedKey}`));
        assert.equal(await okay.evaluate(button => document.activeElement === button), true);
        await page.keyboard.press("Tab");
        assert.equal(await okay.evaluate(button => document.activeElement === button), true);
        await page.keyboard.press("Shift+Tab");
        assert.equal(await okay.evaluate(button => document.activeElement === button), true);
        await page.keyboard.press("Escape");
        assert.equal(await modal.evaluate(dialog => dialog.open), true, "Escape must not dismiss an unacknowledged result");
      };
      await openForm();
      assert.equal(await page.locator("#new-project-form input:visible").count(), 1);
      assert.deepEqual(await page.locator("#new-project-form input").evaluateAll(inputs => inputs.map(i => i.name)), ["name", "key", "group"]);
      assert.equal(await page.locator("#new-project-form details").count(), 1);
      assert.equal(await options.locator("summary").textContent(), "Options");
      assert.equal(await page.locator("[data-project-destination], #new-project-path, #new-project-folder-options").count(), 0);
      await name.fill("Atlas");
      assert.equal(await key.inputValue(), "atlas");
      await page.evaluate(() => window.scrollTo(0, 0));
      await page.screenshot({ path: path.join(capture, `${label}-form.png`) });
      await openOptions();
      await key.fill("custom");
      await name.fill("Custom");
      await name.fill("Other");
      await options.locator("summary").click();
      await page.evaluate(() => refresh({ force: true }));
      assert.equal(await key.inputValue(), "custom");
      await page.reload(); await ready();
      await name.fill("Custom"); await name.fill("Other");
      assert.equal(await key.inputValue(), "custom", "manual ownership must survive matching Name and reload");
      await openOptions();
      await page.getByRole("button", { name: "Use name", exact: true }).click();
      assert.equal(await key.inputValue(), "other");
      await name.fill(`${label} project`);
      assert.equal(await key.inputValue(), `${label}-project`);
      await key.fill(label);
      await name.fill(label); await name.fill(`${label} project`);
      assert.equal(await key.inputValue(), label);
      await page.getByLabel("Group", { exact: true }).fill("Design");
      // A definite server rejection restores the field and text selection used
      // to submit with Enter. Manual key ownership remains active.
      for (const [field, selection] of [[name, [2, 6]], [key, [1, 4]]]) {
        if (field === key) await openOptions();
        await field.focus();
        await field.evaluate((input, [start, end]) => input.setSelectionRange(start, end), selection);
        await page.route("**/projects", route => route.request().method() === "POST"
          ? route.fulfill({ status: 400, contentType: "application/json", body: JSON.stringify({ error: "Choose a different project name", details: { creation_rejected: true } }) }) : route.continue(), { times: 1 });
        const rejectedResponse = page.waitForResponse(response => response.url().endsWith("/projects") && response.request().method() === "POST");
        await field.press("Enter");
        assert.equal((await rejectedResponse).status(), 400);
        await page.getByRole("alert").filter({ hasText: "Choose a different project name" }).waitFor();
        assert.equal(await field.evaluate(input => input.disabled), false);
        assert.deepEqual(await field.evaluate(input => [input.selectionStart, input.selectionEnd]), selection);
        assert.equal(await field.evaluate(input => document.activeElement === input), true, `${field === name ? "Name" : "Project Key"} focus must return after a definite rejection`);
        assert.equal(await page.locator("#project-created-dialog").evaluate(dialog => dialog.open), false);
      }
      assert.equal(await name.inputValue(), `${label} project`);
      assert.equal(await key.inputValue(), label);
      await name.fill(`${label} revised`);
      assert.equal(await key.inputValue(), label, "manual key ownership must survive a rejected Enter submission");
      await name.fill(`${label} project`);
      const pendingFocus = page.locator("#agent-filter");
      let rejectPending;
      const rejectionDone = new Promise(resolve => { rejectPending = resolve; });
      await page.route("**/projects", async route => {
        if (route.request().method() !== "POST") return route.continue();
        await new Promise(resolve => setTimeout(resolve, 100));
        await route.fulfill({ status: 400, contentType: "application/json", body: JSON.stringify({ error: "Choose a different project name", details: { creation_rejected: true } }) });
        rejectPending();
      }, { times: 1 });
      await name.press("Enter");
      await page.evaluate(() => navigate({ type: "tab", tab: "agents" }));
      await page.waitForURL(/#agents$/);
      await pendingFocus.waitFor({ state: "visible" });
      await pendingFocus.focus();
      await rejectionDone;
      assert.equal(await pendingFocus.evaluate(button => document.activeElement === button), true,
        `a late rejection must not steal focus after navigation: ${await page.evaluate(() => `${location.hash} ${document.activeElement?.outerHTML || document.activeElement?.tagName}`)}`);
      await openForm();
      const formHash = new URL(page.url()).hash;
      let release;
      const held = new Promise(resolve => { release = resolve; });
      let accepted;
      const committed = new Promise(resolve => { accepted = resolve; });
      await page.route("**/projects", async route => {
        if (route.request().method() !== "POST") return route.continue();
        const response = await route.fetch();
        accepted();
        await held;
        await route.fulfill({ response });
      }, { times: 1 });
      const before = posts.length;
      await create.click(); await committed;
      await page.evaluate(() => refresh({ force: true }));
      assert.equal(new URL(page.url()).hash, formHash, "no navigation before acknowledgment");
      assert.equal(await page.locator("#project-created-dialog").evaluate(dialog => dialog.open), false, "catalog visibility is not a confirmation receipt");
      assert.equal(posts.length, before + 1, "polling cannot create again");
      release();
      await assertModal(label);
      assert.equal(new URL(page.url()).hash, formHash);
      await page.evaluate(() => { state.renderedViewHtml = ""; render(); });
      await page.evaluate(() => refresh({ force: true }));
      assert.equal(await modal.evaluate(dialog => dialog.open), true);
      assert.equal(posts.length, before + 1);
      await page.reload(); await ready();
      await assertModal(label);
      assert.equal(posts.length, before + 1, "confirmed reload cannot create again");
      await page.screenshot({ path: path.join(capture, `${label}-success.png`) });
      assert.equal(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth), true);
      await okay.click();
      await page.waitForURL(new RegExp(`#project/${label}$`));
      assert(fs.statSync(path.join(home, "tycho-projects", label)).isDirectory());
      assert.equal(await page.locator("#project-created-dialog").evaluate(dialog => dialog.open), false);
      // Lost and malformed replies both retain the ID, survive reload and
      // recover only through an explicit replay of the original request.
      for (const failure of ["lost", "malformed"]) {
        await openForm();
        await name.fill(`${label} ${failure}`);
        const expectedKey = `${label}-${failure}`;
        await page.route("**/projects", async route => {
          if (route.request().method() !== "POST") return route.continue();
          const response = await route.fetch();
          assert.equal(response.status(), 201);
          if (failure === "lost") return route.abort("failed");
          await route.fulfill({ status: 201, contentType: "application/json", body: "{}" });
        }, { times: 1 });
        const first = posts.length;
        await create.click();
        await page.getByRole("alert").filter({ hasText: "Could not confirm creation" }).waitFor();
        assert.equal(await page.locator("#project-created-dialog").evaluate(dialog => dialog.open), false);
        assert.equal(await name.isDisabled(), true, "unknown receipt must keep original payload fixed");
        await page.reload(); await ready();
        await page.getByRole("alert").filter({ hasText: "Creation awaits confirmation" }).waitFor();
        assert.equal(posts.length, first + 1, "reload cannot automatically retry");
        assert.equal(await name.inputValue(), `${label} ${failure}`);
        await create.click(); await assertModal(expectedKey);
        assert.equal(posts.length, first + 2);
        assert.equal(posts[first].creation_request_id, posts[first + 1].creation_request_id, "retry must reuse its ID");
        assert.equal(Object.hasOwn(posts[first], "path"), false, "UI must not send a custom folder");
        await okay.click();
        await page.waitForURL(new RegExp(`#project/${expectedKey}$`));
        const catalog = await (await fetch(`${base}/projects`)).json();
        assert.equal(catalog.projects.filter(project => project.key === expectedKey).length, 1, "retry must register once");
      }
      assert.deepEqual(errors, []);
      results.push({ label, width, height, minimalFields: true, manualKey: true, oneActionModal: true, confirmedOnly: true, pollStable: true, focusTrap: true, reloadRecovery: true, lostReplyReplay: true, malformedReplyReplay: true });
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
