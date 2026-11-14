/* Isolated real-server acceptance test. No provider or live Tycho data. */
const assert = require("node:assert/strict");
const fs = require("node:fs/promises");
const path = require("node:path");
const { chromium } = require(process.env.TYCHO_PLAYWRIGHT_PATH);
const base = process.env.TYCHO_REMOTE_UI_URL;
const capture = process.env.TYCHO_REMOTE_UI_CAPTURE_DIR;
const fixture = process.env.TYCHO_DELETION_FIXTURE_ROOT;

(async () => {
  if (capture) await fs.mkdir(capture, { recursive: true });
  const browser = await chromium.launch({ executablePath: process.env.CHROME_PATH, headless: true });
  const errors = [];
  const page = await browser.newPage({ viewport: { width: 1440, height: 1000 } });
  page.on("pageerror", error => errors.push(error.message));
  const shot = async name => { if (capture) await page.screenshot({ path: path.join(capture, `${name}.png`), fullPage: false }); };
  const request = async (method, route, data) => {
    const response = await page.request.fetch(`${base}${route}`, { method, data });
    assert(response.ok(), `${method} ${route}: ${response.status()} ${await response.text()}`);
    return response.json();
  };
  const open = async () => {
    await page.goto(`${base}/ui#project/demo/edit`);
    await page.locator("#project-delete-form").waitFor();
    await page.locator("#project-delete-form").scrollIntoViewIfNeeded();
  };
  try {
    await request("POST", "/agents", { project_key: "demo", template_key: "custom", name: "Synthetic agent", prompt: "Do not run", agent: "codex" });
    await open();
    assert.equal(await page.locator('[name="remove_data"]').isChecked(), false);
    await page.locator('[name="confirmation"]').fill("wrong");
    await page.locator('#project-delete-form [type="submit"]').click();
    await page.getByText("Type the project key to confirm deletion.", { exact: true }).waitFor();
    assert.equal((await request("GET", "/projects/demo/deletion")).deletion, null);
    await page.locator('[name="confirmation"]').fill("demo");
    await shot("desktop-delete-project");
    await page.locator('#project-delete-form [type="submit"]').click();
    await page.getByRole("dialog", { name: "Delete project?" }).waitFor();
    await shot("desktop-confirm-project");
    await page.locator('[data-confirmation-cancel]').click();
    assert.equal((await request("GET", "/projects/demo/deletion")).deletion, null);
    await page.setViewportSize({ width: 390, height: 844 });
    await page.locator("#project-delete-form").scrollIntoViewIfNeeded();
    assert(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth));
    await shot("mobile-delete-project");

    // Hold POST delivery after the actual server has accepted and processed it.
    let release;
    let releaseStatus;
    let holdStatus = false;
    const statusHeld = new Promise(resolve => { releaseStatus = resolve; });
    const held = new Promise(resolve => { release = resolve; });
    await page.route("**/projects/demo/deletion", async route => {
      if (route.request().method() !== "POST") {
        if (!holdStatus) return route.continue();
        const response = await route.fetch();
        await statusHeld;
        return route.fulfill({ response });
      }
      const response = await route.fetch();
      await held;
      await route.fulfill({ response });
    });
    await page.locator('#project-delete-form [type="submit"]').click();
    await page.locator('[data-confirmation-accept]').click();
    await page.waitForFunction(() => document.querySelector('#project-delete-form [type="submit"]')?.disabled);
    holdStatus = true;
    release();
    await page.getByRole("heading", { name: "Deleting project", exact: true }).waitFor();
    await shot("mobile-project-deletion-progress");
    await page.setViewportSize({ width: 1440, height: 1000 });
    await shot("desktop-project-deletion-progress");
    await page.getByRole("button", { name: "Back to agents", exact: true }).click();
    await page.locator("#project-delete-form").waitFor({ state: "detached" });
    releaseStatus();
    await page.goto(`${base}/ui#project/demo/edit`);
    await page.getByRole("heading", { name: "Project deleted", exact: true }).waitFor();
    await page.setViewportSize({ width: 390, height: 844 });
    await shot("mobile-project-deleted");
    const deleted = (await request("GET", "/projects/demo/deletion")).deletion;
    assert.equal(deleted.status, "completed");
    assert.equal(deleted.remove_data, false);
    await page.reload();
    await page.getByRole("heading", { name: "Project deleted", exact: true }).waitFor();
    assert((await fs.readdir(path.join(fixture, "logs", "agents", "archive"))).length > 0);
    assert.equal((await request("GET", "/projects")).projects.length, 1);
    assert.equal(await fs.readFile(path.join(fixture, "workspace", "keep.txt"), "utf8"), "keep");
    await shot("mobile-project-deleted-reload");
    await page.unroute("**/projects/demo/deletion");
    const prior = await request("POST", "/agents", { project_key: "purge", template_key: "custom", name: "Prior archived agent", prompt: "Synthetic archive", agent: "codex" });
    await request("POST", `/agents/${encodeURIComponent(prior.agent.key)}/archive`, {});
    await request("POST", "/agents", { project_key: "purge", template_key: "custom", name: "Active purge agent", prompt: "Synthetic", agent: "codex" });
    const projectLogs = path.join(fixture, "logs", "projects", "purge");
    await fs.mkdir(projectLogs, { recursive: true });
    await fs.writeFile(path.join(projectLogs, "action.log"), "synthetic log");
    // The unsafe archive is fixture-only. It must fail without following the link.
    const unsafeTarget = path.join(fixture, "unsafe-target");
    await fs.mkdir(unsafeTarget);
    await fs.writeFile(path.join(unsafeTarget, "agent_manifest.json"), JSON.stringify({ project_key: "purge" }));
    await fs.writeFile(path.join(unsafeTarget, "keep.txt"), "keep unsafe target");
    const unsafeLink = path.join(fixture, "logs", "agents", "archive", "unsafe");
    await fs.symlink(unsafeTarget, unsafeLink);
    await page.goto(`${base}/ui#project/purge/edit`);
    await page.locator("#project-delete-form").waitFor();
    await page.locator('[name="remove_data"]').check();
    await page.locator('[name="confirmation"]').fill("purge");
    await page.locator('#project-delete-form [type="submit"]').click();
    await page.locator('[data-confirmation-accept]').click();
    await page.getByRole("heading", { name: "Project deletion needs attention", exact: true }).waitFor();
    await shot("mobile-project-deletion-error");
    await page.setViewportSize({ width: 1440, height: 1000 });
    await shot("desktop-project-deletion-error");
    assert.equal(await fs.readFile(path.join(unsafeTarget, "keep.txt"), "utf8"), "keep unsafe target");
    await fs.unlink(unsafeLink);
    await page.getByRole("button", { name: "Retry deletion", exact: true }).click();
    await page.locator('[data-confirmation-accept]').click();
    await page.getByRole("heading", { name: "Project deleted", exact: true }).waitFor();
    await shot("desktop-project-data-removed");
    const purgeJob = (await request("GET", "/projects/purge/deletion")).deletion;
    assert.equal(purgeJob.remove_data, true);
    const archives = await fs.readdir(path.join(fixture, "logs", "agents", "archive"));
    for (const directory of archives) {
      const manifest = JSON.parse(await fs.readFile(path.join(fixture, "logs", "agents", "archive", directory, "agent_manifest.json"), "utf8"));
      assert.notEqual(manifest.project_key, "purge");
    }
    assert.equal((await request("GET", "/projects")).projects.length, 0);
    assert.equal(await fs.readFile(path.join(fixture, "workspace", "keep.txt"), "utf8"), "keep");
    await page.setViewportSize({ width: 390, height: 844 });
    assert(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth));
    await shot("mobile-project-data-removed");
    assert.deepEqual(errors, []);
    console.log("project_deletion_smoke: desktop/mobile confirmation, cancel, key validation, delayed response, archive, reload, purge, failure, retry, workspace preservation: ok");
  } finally {
    await browser.close();
  }
})().catch(error => { console.error(error); process.exitCode = 1; });
