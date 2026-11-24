const assert = require("node:assert/strict");
const path = require("node:path");

module.exports = async ({ browser, baseUrl, captureDir }) => {
  const context = await browser.newContext({ viewport: { width: 1280, height: 900 } });
  const page = await context.newPage();
  const errors = [];
  page.on("pageerror", error => errors.push(error.message));
  page.on("console", message => {
    if (message.type() === "error" && !/409 \(Conflict\)|404 \(Not Found\)|500 \(Internal Server Error\)/.test(message.text())) {
      errors.push(message.text());
    }
  });
  page.on("response", response => {
    if (response.status() === 404) errors.push(`HTTP 404 ${response.url()}`);
  });
  const createAgent = async (name, parentAgentKey = "") => {
    const response = await context.request.post(`${baseUrl}/agents`, { data: {
      project_key: "web", template_key: "custom", agent: "codex", name,
      prompt: "Synthetic archive delegate fixture.", ...(parentAgentKey ? { parent_agent_key: parentAgentKey } : {}),
    } });
    assert(response.ok(), `Agent fixture failed: ${await response.text()}`);
    return (await response.json()).agent;
  };
  const parent = await createAgent("Archive parent fixture");
  const child = await createAgent("Archive delegate fixture", parent.key);
  const unrelated = await createAgent("Unrelated active fixture");
  await page.goto(`${baseUrl}/ui#agent/${parent.key}/archive`, { waitUntil: "networkidle" });
  const delegate = page.locator("[data-archive-delegate]");
  assert.equal(await delegate.count(), 1, "Archive dialog must list only the direct active delegate");
  assert.equal(await delegate.isChecked(), true, "Direct delegate must be selected by default");
  assert.equal(await delegate.evaluate(node => node.closest(".agent-row")?.classList.contains("archive-delegate-row")), true,
    "Delegate must use the standard agent block with a left checkbox segment");
  assert.equal(await delegate.evaluate(node => node.parentElement.firstElementChild === node), true,
    "Delegate checkbox must be the first row segment");
  if (captureDir) await page.screenshot({ path: path.join(captureDir, "archive-delegates-dialog.png") });
  await page.evaluate(parentKey => {
    state.bulkArchiveMode = true;
    renderAgentArchive(parentKey);
  }, parent.key);
  assert.equal(await page.locator("[data-archive-delegate]").count(), 1,
    "Archive delegates must keep their own checkbox while Agents bulk mode is active");
  assert.equal(await page.locator("[data-select-agent]").count(), 0,
    "Archive dialog rows must not become Agents bulk-selection rows");
  await page.evaluate(parentKey => {
    state.bulkArchiveMode = false;
    renderAgentArchive(parentKey);
  }, parent.key);

  await page.locator("[data-open-agent]").filter({ hasText: "Cancel" }).click();
  assert.equal(await page.evaluate(key => state.agents.some(agent => agent.key === key), parent.key), true,
    "Cancel must keep the parent active");
  assert.equal(await page.evaluate(key => state.agents.some(agent => agent.key === key), child.key), true,
    "Cancel must keep the delegate active");

  await page.goto(`${baseUrl}/ui#agent/${parent.key}/archive`, { waitUntil: "networkidle" });
  await page.locator("[data-archive-delegate]").uncheck();
  await page.locator("[data-agent-action='archive']").click();
  await page.locator("[data-confirmation-accept]").waitFor();
  assert.match(await page.locator("#confirmation-title").innerText(), /Archive selected agents/);
  assert.doesNotMatch(await page.locator("#confirmation-description").innerText(), /running|queued|inquiry/i,
    "Main confirmation must not show work status or prompt for a separate abort decision");
  const archiveRequestPromise = page.waitForRequest(request =>
    new URL(request.url()).pathname.endsWith(`/agents/${parent.key}/archive`) && request.method() === "POST");
  await page.locator("[data-confirmation-accept]").click();
  const archiveRequest = await Promise.race([
    archiveRequestPromise,
    page.waitForTimeout(3000).then(() => null),
  ]).catch(() => null);
  assert.deepEqual(errors, [], `Page errors before archive: ${errors.join("; ")}`);
  assert(archiveRequest, `Archive request missing; button=${await page.locator("[data-agent-action='archive']").count()}, dialog=${await page.locator("#confirmation-dialog").evaluate(node => node.open).catch(() => false)}, growl=${await page.locator("#growl").innerText().catch(() => "")}`);
  await page.waitForFunction(key => !state.agents.some(agent => agent.key === key), parent.key);
  assert.equal(await page.evaluate(key => state.agents.some(agent => agent.key === key), child.key), true,
    "Unselected delegate must remain active");
  assert.equal(await page.evaluate(key => state.agents.some(agent => agent.key === key), unrelated.key), true,
    "Unrelated agent must remain active");

  const selectedParent = await createAgent("Selected archive parent fixture");
  const selectedChild = await createAgent("Selected archive delegate fixture", selectedParent.key);
  await page.goto(`${baseUrl}/ui#agent/${selectedParent.key}/archive`, { waitUntil: "networkidle" });
  assert.equal(await page.locator("[data-archive-delegate]").isChecked(), true,
    "Delegate must remain selected for the default archive action");
  await page.locator("[data-agent-action='archive']").click();
  await page.locator("[data-confirmation-accept]").waitFor();
  const bulkRequestPromise = page.waitForRequest(request =>
    new URL(request.url()).pathname.endsWith("/agents/archive") && request.method() === "POST");
  await page.locator("[data-confirmation-accept]").click();
  const bulkRequest = await bulkRequestPromise;
  assert.deepEqual(JSON.parse(bulkRequest.postData()).keys, [selectedParent.key, selectedChild.key],
    "Default archive action must include the parent and all selected delegates");
  await page.waitForFunction(keys => keys.every(key => !state.agents.some(agent => agent.key === key)),
    [selectedParent.key, selectedChild.key]);

  const retainedParent = await createAgent("Selection preservation parent fixture");
  const retainedFirst = await createAgent("Selection preservation first fixture", retainedParent.key);
  const retainedLast = await createAgent("Selection preservation last fixture", retainedParent.key);
  await page.goto(`${baseUrl}/ui#agent/${retainedParent.key}/archive`, { waitUntil: "networkidle" });
  const lastCheckbox = page.locator(`[data-archive-delegate][value="${retainedLast.key}"]`);
  await lastCheckbox.uncheck();
  await page.evaluate(({ parentKey, removeKey }) => {
    const removed = findAgent(removeKey);
    state.agents = state.agents.filter(agent => agent.key !== removeKey);
    delete state.agentDetails[removeKey];
    renderAgentArchive(parentKey);
    if (removed) state.agents.push(removed);
    renderAgentArchive(parentKey);
  }, { parentKey: retainedParent.key, removeKey: retainedLast.key });
  assert.equal(await page.locator(`[data-archive-delegate][value="${retainedLast.key}"]`).isChecked(), false,
    "Excluded delegate must stay excluded after it disappears and returns during the dialog");
  await page.goto(`${baseUrl}/ui#agents`, { waitUntil: "networkidle" });
  await page.goto(`${baseUrl}/ui#agent/${retainedParent.key}/archive`, { waitUntil: "networkidle" });
  assert.equal(await page.locator(`[data-archive-delegate][value="${retainedLast.key}"]`).isChecked(), true,
    "A new dialog lifetime must select the delegate by default");

  const source = await page.evaluate(key => structuredClone(findAgent(key)), unrelated.key);
  const peerParent = { ...source, key: "review-peer/peer-parent", resource_key: "peer-parent", name: "Peer archive parent fixture", server_key: "review-peer",
    server_name: "Review peer", delegation: { parent: null, children: [] }, running: false, status: "idle" };
  const peerChild = { ...source, key: "review-peer/peer-child", resource_key: "peer-child", name: "Peer running delegate fixture", server_key: "review-peer",
    server_name: "Review peer", delegation: { parent: { key: peerParent.key, agent_key: "peer-parent", server_key: "review-peer" }, children: [] },
    running: false, status: "idle" };
  peerParent.archive_work_token = "peer-parent-idle";
  peerChild.archive_work_token = "peer-child-run-a";
  peerChild.running = true;
  peerChild.status = "running";
  peerChild.current_run_id = "synthetic-run-a";
  const peerRecords = new Map([["peer-parent", peerParent], ["peer-child", peerChild]]);
  let childReads = 0;
  let archivePosts = 0;
  const peerArchivePayloads = [];
  const peerDetailPaths = [];
  const peerArchivePaths = [];
  await page.route("**/servers/review-peer/**", async route => {
    const request = route.request();
    const pathname = new URL(request.url()).pathname;
    if (request.method() === "GET" && pathname === "/servers/review-peer/projects/web") {
      await route.fulfill({ json: { project: { key: "web", name: "Peer Web", path: "/tmp/synthetic-peer-web" } } });
      return;
    }
    if (request.method() === "POST" && pathname === "/servers/review-peer/agents/archive") {
      const payload = request.postDataJSON();
      peerArchivePayloads.push(payload);
      peerArchivePaths.push(pathname);
      const keys = payload.keys;
      archivePosts += 1;
      if (archivePosts < 3) {
        const changed = peerRecords.get("peer-child");
        const run = `synthetic-run-${String.fromCharCode(96 + archivePosts + 2)}`;
        changed.current_run_id = run;
        changed.archive_work_token = `peer-child-run-${String.fromCharCode(96 + archivePosts + 2)}`;
        return route.fulfill({ status: 409, json: {
          error: "Agent work changed after confirmation. Review it and confirm again.",
          details: { work_changed: true, agent_keys: ["peer-child"] },
        } });
      }
      assert.deepEqual(payload.expected_work_states, {
        "peer-parent": "peer-parent-idle", "peer-child": "peer-child-run-d",
      }, "Repeated retry must bind to the run shown in the latest confirmation");
      await route.fulfill({ json: { archived: keys.map(agent_key => ({ agent_key })), skipped: [], failed: [] } });
      return;
    }
    const rawKey = pathname.split("/").at(-1);
    peerDetailPaths.push(pathname);
    const record = peerRecords.get(rawKey);
    if (!record) return route.fulfill({ status: 404, json: { error: "Synthetic peer agent missing" } });
    if (rawKey === "peer-child") childReads += 1;
    const response = structuredClone(record);
    response.key = rawKey;
    delete response.resource_key;
    delete response.server_key;
    delete response.server_name;
    if (rawKey === "peer-child") {
      response.running = true;
      response.status = "running";
    }
    await route.fulfill({ json: { agent: response } });
  });
  await page.evaluate(({ parent, child }) => {
    state.servers.push({ key: "review-peer", name: "Review peer", status: "online", stale: false });
    state.agents = [parent, child, ...state.agents.filter(agent => agent.server_key !== "review-peer")];
    state.agentDetails[parent.key] = parent;
    state.agentDetails[child.key] = child;
    navigate({ type: "agentArchive", key: parent.key });
  }, { parent: peerParent, child: peerChild });
  await page.locator("[data-agent-action='archive']").waitFor();
  await page.locator("[data-agent-action='archive']").click();
  await page.locator("[data-confirmation-accept]").waitFor();
  const firstConfirmation = await page.locator("#confirmation-description").innerText();
  assert.match(firstConfirmation, /stop and archive/,
    "The main confirmation must authorize stopping and archiving selected agents");
  assert.doesNotMatch(firstConfirmation, /running|queued|inquiry/i,
    "The confirmation must not expose status details or use a separate abort prompt");
  await page.locator("[data-confirmation-accept]").click();
  await page.locator("[data-confirmation-accept]").waitFor({ state: "hidden" });
  await page.locator("[data-confirmation-accept]").waitFor();
  const retryConfirmation = await page.locator("#confirmation-description").innerText();
  assert.equal(retryConfirmation, firstConfirmation, "A work race must repeat the same main confirmation");
  await page.locator("[data-confirmation-accept]").click();
  await page.locator("[data-confirmation-accept]").waitFor({ state: "hidden" });
  await page.locator("[data-confirmation-accept]").waitFor();
  assert.equal(await page.locator("#confirmation-description").innerText(), firstConfirmation,
    "A second peer conflict must repeat the same main confirmation");
  await page.locator("[data-confirmation-accept]").click();
  for (let attempt = 0; attempt < 50 && archivePosts < 3; attempt += 1) await page.waitForTimeout(100);
  assert.deepEqual(peerArchivePayloads.at(-1).keys, ["peer-parent", "peer-child"],
    "Peer archive request must use raw keys on the peer server route");
  assert.equal(peerArchivePayloads[1].expected_work_states["peer-child"], "peer-child-run-c",
    "First peer retry must use normalized raw detail from the peer server");
  assert.equal(peerArchivePayloads[2].expected_work_states["peer-child"], "peer-child-run-d",
    "Second peer retry must use the latest normalized peer detail");
  assert.equal(peerArchivePaths.length, 3, "All archive retries must use the peer server route");
  assert.equal(peerDetailPaths.length, 6, "All refreshed detail requests must use peer raw keys");
  assert(peerDetailPaths.every(pathname => /^\/servers\/review-peer\/agents\/peer-(parent|child)$/.test(pathname)),
    `Peer detail retries must use scoped routes with raw keys: ${peerDetailPaths.join(", ")}`);
  assert.equal(childReads, 3, "Each archive attempt must read the delegate from the peer server");
  assert.equal(archivePosts, 3, "Two server conflicts must not archive before the latest confirmation");

  const partialParent = await createAgent("Partial archive parent fixture");
  const partialChild = await createAgent("Partial archive stopped delegate fixture", partialParent.key);
  const localSource = await page.evaluate(key => structuredClone(findAgent(key)), unrelated.key);
  const partialParentState = { ...localSource, key: partialParent.key, resource_key: partialParent.key,
    server_key: "local", name: partialParent.name, delegation: { parent: null, children: [] } };
  const partialChildState = { ...localSource, key: partialChild.key, resource_key: partialChild.key,
    server_key: "local", name: partialChild.name,
    delegation: { parent: { key: partialParent.key, agent_key: partialParent.key }, children: [] } };
  await page.evaluate(({ parentState, childState }) => {
    state.agents = [parentState, childState, ...state.agents.filter(agent =>
      agent.key !== parentState.key && agent.key !== childState.key)];
    state.agentDetails[parentState.key] = parentState;
    state.agentDetails[childState.key] = childState;
    navigate({ type: "agentArchive", key: parentState.key });
  }, { parentState: partialParentState, childState: partialChildState });
  assert.equal(await page.locator("[data-archive-delegate]").count(), 1,
    "Partial-failure fixture must include its selected delegate");
  const stoppedDetail = await page.evaluate(key => structuredClone(findAgent(key)), partialChild.key);
  Object.assign(stoppedDetail, {
    running: false, status: "stopped", last_result: "stopped", last_exit_code: 143,
    finished_at: new Date().toISOString(), archive_work_token: "synthetic-stopped-token",
    prompt_queue: { entries: [], pending_count: 0 },
  });
  let partialFailureReturned = false;
  await page.route(`**/agents/${partialChild.key}`, async route => {
    if (!partialFailureReturned) return route.continue();
    await route.fulfill({ json: { agent: stoppedDetail } });
  });
  await page.route("**/agents/archive", async route => {
    if (route.request().method() !== "POST") return route.continue();
    partialFailureReturned = true;
    await route.fulfill({ status: 500, json: {
      error: "Synthetic disk failure after process stop",
      details: { archive_partial: true, stopped_agent_keys: [partialChild.key], affected_agent_keys: [partialChild.key] },
    } });
  });
  await page.locator("[data-agent-action='archive']").click();
  await page.locator("[data-confirmation-accept]").waitFor();
  const partialRequest = page.waitForRequest(request =>
    request.method() === "POST" && new URL(request.url()).pathname === "/agents/archive");
  await page.locator("[data-confirmation-accept]").click();
  await partialRequest;
  await page.waitForFunction(key => state.agentDetails[key]?.status === "stopped" &&
    state.agentDetails[key]?.last_result === "stopped", partialChild.key);
  assert.match(await page.locator("#growl").innerText(), /Synthetic disk failure after process stop/,
    "The archive error must remain visible after the stopped state refresh");
  assert.equal(await page.evaluate(({ parentKey, childKey }) => state.agents.some(agent => agent.key === parentKey) &&
    state.agents.some(agent => agent.key === childKey), { parentKey: partialParent.key, childKey: partialChild.key }), true,
  "A partial archive failure must restore all agents to the active view");

  await page.setViewportSize({ width: 390, height: 844 });
  await page.goto(`${baseUrl}/ui#agent/${retainedParent.key}/archive`, { waitUntil: "networkidle" });
  assert.equal(await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth), true,
    "Archive delegate rows must fit the mobile viewport");
  if (captureDir) await page.screenshot({ path: path.join(captureDir, "archive-delegates-dialog-mobile.png") });
  assert.deepEqual(errors, [], `Unexpected page errors: ${errors.join("; ")}`);
  await context.close();
};
