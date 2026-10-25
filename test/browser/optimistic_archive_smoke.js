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

  // Bulk archive: the same pattern across the agents list, including a partial failure.
  const bulkUrl = `${baseUrl}/agents/archive`;
  const runBulk = async (names, respond) => {
    const agents = [];
    for (const name of names) agents.push(await createAgent(name));
    await page.goto(`${baseUrl}/ui#agents`, { waitUntil: "networkidle" });
    await page.evaluate(() => navigate({ type: "tab", tab: "agents" }));
    await page.locator("[data-toggle-bulk-archive]").first().click();
    for (const agent of agents) await page.locator(`input[data-select-agent='${agent.key}']`).check();
    let release;
    const held = new Promise(resolve => { release = resolve; });
    await page.route(bulkUrl, async route => {
      await held;
      await respond(route);
    }, { times: 1 });
    const requested = page.waitForRequest(request => request.url() === bulkUrl && request.method() === "POST");
    await page.locator("[data-run-bulk-archive]:visible").first().click();
    await page.locator("[data-confirmation-accept]").click();
    await requested;
    const immediate = await page.evaluate(keys => ({
      inState: keys.map(key => state.agents.some(agent => agent.key === key)),
      bulkMode: state.bulkArchiveMode,
      selection: state.bulkArchiveSelection.size,
    }), agents.map(agent => agent.key));
    assert.deepEqual(immediate.inState, [false, false], "Bulk archive must remove selected agents before the request settles");
    assert.equal(immediate.bulkMode, false, "Bulk archive must leave selection mode at once");
    assert.equal(immediate.selection, 0, "Bulk archive must clear the selection at once");
    release();
    await page.waitForFunction(() => !state.bulkArchiveMode && !document.querySelector("[data-run-bulk-archive]"), null, { timeout: 10_000 });
    await page.waitForTimeout(200);
    const settled = await page.evaluate(keys => ({
      inState: keys.map(key => state.agents.some(agent => agent.key === key)),
      markers: keys.map(key => state.archivedAgentKeys.has(key)),
      connection: state.connection,
    }), agents.map(agent => agent.key));
    return { agents, immediate, settled };
  };
  const fulfillJson = (status, body) => route => route.fulfill({ status, contentType: "application/json", body: JSON.stringify(body) });

  // Success: both removed and kept removed.
  const bulkOk = await runBulk(["Bulk archive ok A", "Bulk archive ok B"], async route => {
    const body = JSON.parse(route.request().postData() || "{}");
    const archived = body.keys.map(key => ({ agent_key: key }));
    await route.fulfill({ status: 200, contentType: "application/json", body: JSON.stringify({ archived, skipped: [], failed: [] }) });
  });
  assert.deepEqual(bulkOk.settled.inState, [false, false], "Successful bulk archive must keep both agents removed");

  // Partial failure: the confirmed agent stays archived, the unconfirmed agent comes back.
  const bulkPartial = await runBulk(["Bulk partial A", "Bulk partial B"], async route => {
    const body = JSON.parse(route.request().postData() || "{}");
    const [confirmed, unconfirmed] = body.keys;
    await route.fulfill({ status: 200, contentType: "application/json", body: JSON.stringify({
      archived: [{ agent_key: confirmed }], skipped: [], failed: [{ agent_key: unconfirmed, error: "Fixture busy" }],
    }) });
  });
  assert.deepEqual(bulkPartial.settled.inState, [false, true], "Partial failure must keep only the confirmed agent archived");
  assert.deepEqual(bulkPartial.settled.markers, [true, false], "Partial failure must mark only the confirmed agent as archived");
  const partialGrowl = await page.locator("#growl").innerText();
  assert.match(partialGrowl, /could not be archived/, "Partial failure must show an error that stays visible after refresh");
  if (captureDir) await page.screenshot({ path: path.join(captureDir, `optimistic-bulk-partial-${width}.png`) });

  // Whole request refused: both come back with an error.
  const bulkRefused = await runBulk(["Bulk refused A", "Bulk refused B"], fulfillJson(503, { error: "Fixture bulk refused" }));
  assert.deepEqual(bulkRefused.settled.inState, [true, true], "Refused bulk archive must restore every selected agent");
  assert.deepEqual(bulkRefused.settled.markers, [false, false], "Refused bulk archive must clear archived markers");
  const refusedGrowl = await page.locator("#growl").innerText();
  assert.match(refusedGrowl, /Archive failed/, "Refused bulk archive must show an error");
  if (captureDir) await page.screenshot({ path: path.join(captureDir, `optimistic-bulk-refused-${width}.png`) });
  console.log(JSON.stringify({ bulkOk: bulkOk.settled, bulkPartial: bulkPartial.settled, bulkRefused: bulkRefused.settled }));

  const overflow = await page.evaluate(() => document.documentElement.scrollWidth > innerWidth + 1);
  assert.equal(overflow, false);
  assert.deepEqual(errors, [], `Unexpected page errors: ${errors.join("; ")}`);
  const proof = { failing: failing.key, succeeding: succeeding.key, immediate, restored, failureText: failureText.slice(0, 120) };
  console.log(JSON.stringify(proof));
  await context.close();
};
