const assert = require("node:assert/strict");
const path = require("node:path");

module.exports = async ({ browser, baseUrl, captureDir }) => {
  const width = 1440;
  const context = await browser.newContext({ viewport: { width, height: 900 } });
  const page = await context.newPage();
  const errors = [];
  page.on("pageerror", error => errors.push(error.message));

  const createAgent = async name => {
    const response = await context.request.post(`${baseUrl}/agents`, { data: {
      project_key: "web", template_key: "custom", agent: "codex",
      name, prompt: "Optimistic archive fixture."
    } });
    assert(response.ok());
    return (await response.json()).agent;
  };

  // Failure path: the request is held open, so the UI must already show the agent as gone.
  const failing = await createAgent("Optimistic archive fail");
  const failingUrl = `${baseUrl}/agents/${failing.key}/archive`;
  let releaseFailure;
  const held = new Promise(resolve => { releaseFailure = resolve; });
  await page.route(failingUrl, async route => {
    await held;
    await route.fulfill({ status: 409, contentType: "application/json", body: JSON.stringify({ error: "Fixture archive refused" }) });
  }, { times: 1 });
  await page.goto(`${baseUrl}/ui#agent/${failing.key}/archive`, { waitUntil: "networkidle" });
  const requested = page.waitForRequest(request => request.url() === failingUrl && request.method() === "POST");
  await page.locator("[data-agent-action='archive']").click();
  await requested;
  const immediate = await page.evaluate(key => ({
    hash: location.hash,
    inState: state.agents.some(agent => agent.key === key),
    archivedMarker: state.archivedAgentKeys.has(key),
  }), failing.key);
  assert.equal(immediate.hash.includes(failing.key), false, "Archive must leave the detail page before the request settles");
  assert.equal(immediate.inState, false, "Archived agent must leave the active list before the request settles");
  assert.equal(immediate.archivedMarker, true, "Pending archive must be tracked so a refresh cannot bring it back");
  releaseFailure();
  await page.waitForFunction(key => document.body.innerText.includes("Archive failed"), failing.key, { timeout: 10_000 });
  const restored = await page.evaluate(key => ({
    inState: state.agents.some(agent => agent.key === key),
    archivedMarker: state.archivedAgentKeys.has(key),
    archivedDetail: state.agentDetails[key]?.archived === true,
  }), failing.key);
  assert.equal(restored.inState, true, "Failed archive must restore the agent to the list");
  assert.equal(restored.archivedMarker, false, "Failed archive must clear the archived marker");
  assert.equal(restored.archivedDetail, false, "Failed archive must not keep a read-only detail copy");
  const failureText = await page.locator("#growl, .growl, [data-growl]").first().innerText().catch(() => "");
  if (captureDir) await page.screenshot({ path: path.join(captureDir, `optimistic-archive-failed-${width}.png`) });

  // Success path: the agent stays removed after the server confirms the archive.
  const succeeding = await createAgent("Optimistic archive ok");
  await page.goto(`${baseUrl}/ui#agent/${succeeding.key}/archive`, { waitUntil: "networkidle" });
  const succeededUrl = `${baseUrl}/agents/${succeeding.key}/archive`;
  const succeeded = page.waitForResponse(response => response.url() === succeededUrl && response.request().method() === "POST");
  await page.locator("[data-agent-action='archive']").click();
  await succeeded;
  await page.waitForFunction(key => !state.archivedAgentKeys.has(key) || state.archivedAgentCatalogConfirmedKeys.has(key), succeeding.key, { timeout: 10_000 });
  await page.evaluate(async () => { await refresh({ force: true }); });
  assert.equal(await page.evaluate(key => state.agents.some(agent => agent.key === key), succeeding.key), false,
    "Successful archive must keep the agent out of the active list");
  const catalog = await (await context.request.get(`${baseUrl}/agents`)).json();
  assert.equal(catalog.agents.some(agent => agent.key === succeeding.key), false, "Server must report the agent as archived");

  const overflow = await page.evaluate(() => document.documentElement.scrollWidth > innerWidth + 1);
  assert.equal(overflow, false);
  assert.deepEqual(errors, [], `Unexpected page errors: ${errors.join("; ")}`);
  const proof = { failing: failing.key, succeeding: succeeding.key, immediate, restored, failureText: failureText.slice(0, 120) };
  console.log(JSON.stringify(proof));
  await context.close();
};
