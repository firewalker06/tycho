const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const { execFileSync } = require("node:child_process");

module.exports = async ({ browser, baseUrl, captureDir, metadataFixture }) => {
  const results = [];
  const deadline = async (promise, label) => {
    let timer;
    try {
      return await Promise.race([promise, new Promise((_, reject) => {
        timer = setTimeout(() => reject(new Error(`metadata fixture timed out: ${label}`)), 20000);
      })]);
    } finally { clearTimeout(timer); }
  };
  const count = key => {
    const file = metadataFixture.commands_path;
    if (!fs.existsSync(file)) return 0;
    return fs.readFileSync(file, "utf8").trim().split("\n").filter(Boolean).map(JSON.parse)
      .filter(record => record.args[1] === metadataFixture.workspaces[key]).length;
  };
  for (const [key, width, boundary] of [
    ["metadata-desktop", 1440, "navigation"],
    ["metadata-mobile", 390, "navigation"],
    ["metadata-blur", 1440, "blur"],
    ["metadata-hidden", 390, "hidden"],
    ["metadata-close", 1440, "close"],
  ]) {
    const context = await browser.newContext({ viewport: { width, height: 844 }, isMobile: width < 500, hasTouch: width < 500 });
    const page = await context.newPage();
    let release;
    const gate = new Promise(resolve => { release = resolve; });
    let captured;
    const initialResponse = new Promise(resolve => { captured = resolve; });
    let completed;
    const releasedResponse = new Promise(resolve => { completed = resolve; });
    let first = true;
    const requests = [];
    const failures = [];
    page.on("pageerror", error => failures.push(error.message));
    page.on("request", request => {
      if (new URL(request.url()).pathname === `/projects/${key}`) requests.push(request.url());
    });
    try {
      await page.goto(`${baseUrl}/ui#agents`);
      await page.waitForFunction(() => typeof state !== "undefined" && state.initialRouteLoaded && !state.refreshInFlight);
      await page.route(`**/projects/${key}`, async route => {
        if (!first) return route.continue();
        first = false;
        const response = await route.fetch();
        captured(await response.json());
        await gate;
        try {
          await route.fulfill({ response });
        } catch (error) {
          // Cancellation is expected when the view or browser page is closed.
          if (!/closed|canceled|interception/i.test(error.message)) throw error;
        } finally { completed(); }
      });
      await page.evaluate(key => navigate({ type: "project", key }), key);
      const initial = await deadline(initialResponse, `${key} capture`);
      assert.equal(initial.project.git_metadata_refreshing, true, `${key}: fixture must hold a cold, pending result`);
      if (boundary === "navigation") {
        await page.evaluate(() => navigate({ type: "tab", tab: "agents" }));
        await page.waitForFunction(() => location.hash === "#agents");
      } else if (boundary === "blur") {
        // Headless Chrome keeps native focus. Use the existing active-window seam.
        await page.evaluate(() => { document.hasFocus = () => false; window.dispatchEvent(new Event("blur")); });
      } else if (boundary === "hidden") {
        await page.evaluate(() => {
          Object.defineProperty(document, "hidden", { configurable: true, get: () => true });
          document.dispatchEvent(new Event("visibilitychange"));
        });
      } else {
        await page.close();
      }
      // The first refresh must finish and its 10-second freshness window must
      // expire. New work after release cannot be completion of that first job.
      await new Promise(resolve => setTimeout(resolve, 13000));
      const before = count(key);
      assert.equal(before, 3, `${key}: initial refresh must complete all three real Git commands`);
      const requestsBefore = requests.length;
      release();
      await deadline(releasedResponse, `${key} release`);
      await new Promise(resolve => setTimeout(resolve, 2500));
      const extraCommands = count(key) - before;
      assert.equal(extraCommands, 0, `${key}: late response started new Git metadata work`);
      assert.equal(requests.length, requestsBefore, `${key}: late response sent another detail request`);
      assert.deepEqual(failures, [], `${key}: page errors`);
      if (boundary === "navigation") {
        assert.equal(await page.evaluate(() => location.hash), "#agents");
        assert.equal(await page.getByText("Revision", { exact: true }).count(), 0);
        assert(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth + 1));
        if (captureDir) {
          fs.mkdirSync(captureDir, { recursive: true });
          await page.screenshot({ path: path.join(captureDir, `${key}-late-response.png`) });
        }
      }
      results.push({ key, width, boundary, initialCommands: before, extraCommands, extraDetailRequests: requests.length - requestsBefore });
    } finally {
      release?.();
      await context.close();
    }
  }
  const context = await browser.newContext({ viewport: { width: 1440, height: 844 } });
  try {
    const page = await context.newPage();
    const key = "metadata-desktop";
    const workspace = metadataFixture.workspaces[key];
    await page.goto(`${baseUrl}/ui#project/${key}`);
    await page.waitForFunction(key => state.projectDetails[key]?.git_metadata_known === true, key);
    execFileSync("git", ["-C", workspace, "checkout", "-qb", "metadata-active-project"]);
    await page.waitForFunction(key => state.projectDetails[key]?.branch === "metadata-active-project" &&
      state.projectDetails[key]?.git_metadata_known === true, key, { timeout: 25000 });
    const response = await context.request.post(`${baseUrl}/agents`, { data: {
      project_key: key, name: "Metadata lifecycle fixture", prompt: "Synthetic fixture only", agent: "codex", start: false,
    } });
    assert(response.ok());
    const { agent } = await response.json();
    await page.goto(`${baseUrl}/ui#agent/${agent.key}`);
    await page.locator("#composer").waitFor();
    execFileSync("git", ["-C", workspace, "checkout", "-qb", "metadata-active-agent"]);
    await page.waitForFunction(key => state.projectDetails[key]?.branch === "metadata-active-agent" &&
      state.projectDetails[key]?.git_metadata_known === true, key, { timeout: 25000 });
    await page.goto(`${baseUrl}/ui#project/${key}/diff?scope=worktree`);
    await page.locator(".diff-viewer").waitFor();
    results.push({ boundary: "active project, agent, and diff", branchPolling: true });
  } finally { await context.close(); }
  if (captureDir) fs.writeFileSync(path.join(captureDir, "project-metadata-lifecycle.json"), JSON.stringify(results, null, 2));
  console.log(`project metadata browser lifecycle: ${JSON.stringify(results)}`);
};
