const assert = require("node:assert/strict");
const path = require("node:path");

module.exports = async ({ browser, baseUrl, captureDir }) => {
  const context = await browser.newContext({ viewport: { width: 1280, height: 900 } });
  const page = await context.newPage();
  const errors = [];
  page.on("pageerror", error => errors.push(error.message));
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
  if (captureDir) await page.screenshot({ path: path.join(captureDir, "archive-delegates-dialog.png") });

  await page.locator("[data-open-agent]").filter({ hasText: "Cancel" }).click();
  assert.equal(await page.evaluate(key => state.agents.some(agent => agent.key === key), parent.key), true,
    "Cancel must keep the parent active");
  assert.equal(await page.evaluate(key => state.agents.some(agent => agent.key === key), child.key), true,
    "Cancel must keep the delegate active");

  await page.goto(`${baseUrl}/ui#agent/${parent.key}/archive`, { waitUntil: "networkidle" });
  await page.locator("[data-archive-delegate]").uncheck();
  const archiveRequestPromise = page.waitForRequest(request =>
    new URL(request.url()).pathname.endsWith(`/agents/${parent.key}/archive`) && request.method() === "POST");
  await page.locator("[data-agent-action='archive']").click();
  const confirmation = page.locator("[data-confirmation-accept]");
  if (await confirmation.isVisible().catch(() => false)) await confirmation.click();
  const archiveRequest = await Promise.race([
    archiveRequestPromise,
    page.waitForTimeout(3000).then(() => null),
  ]);
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
  const bulkRequestPromise = page.waitForRequest(request =>
    new URL(request.url()).pathname.endsWith("/agents/archive") && request.method() === "POST");
  await page.locator("[data-agent-action='archive']").click();
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
  await page.route("**/servers/review-peer/agents/**", async route => {
    const request = route.request();
    const pathname = new URL(request.url()).pathname;
    if (request.method() === "POST" && pathname === "/servers/review-peer/agents/archive") {
      const payload = request.postDataJSON();
      peerArchivePayloads.push(payload);
      const keys = payload.keys;
      archivePosts += 1;
      if (archivePosts === 1) {
        const changed = peerRecords.get("peer-child");
        changed.current_run_id = "synthetic-run-c";
        changed.archive_work_token = "peer-child-run-c";
        return route.fulfill({ status: 409, json: {
          error: "Agent work changed after confirmation. Review it and confirm again.",
          details: { work_changed: true, agent_keys: ["peer-child"] },
        } });
      }
      assert.deepEqual(payload.expected_work_states, {
        "peer-parent": "peer-parent-idle", "peer-child": "peer-child-run-c",
      }, "Retry must bind to the run shown in the latest confirmation");
      await route.fulfill({ json: { archived: keys.map(agent_key => ({ agent_key })), skipped: [], failed: [] } });
      return;
    }
    const rawKey = pathname.split("/").at(-1);
    const record = peerRecords.get(rawKey);
    if (!record) return route.fulfill({ status: 404, json: { error: "Synthetic peer agent missing" } });
    if (rawKey === "peer-child") {
      childReads += 1;
      if (childReads === 2) {
        record.current_run_id = "synthetic-run-b";
        record.archive_work_token = "peer-child-run-b";
      }
    }
    const response = structuredClone(record);
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
  assert.match(firstConfirmation, /Peer running delegate fixture \(running\)/,
    "Fresh delegate status must appear in the active-work confirmation");
  await page.locator("[data-confirmation-accept]").click();
  await page.locator("[data-confirmation-accept]").waitFor();
  await page.locator("[data-confirmation-accept]").click();
  await page.locator("[data-confirmation-accept]").waitFor();
  await page.locator("[data-confirmation-accept]").click();
  for (let attempt = 0; attempt < 50 && archivePosts < 2; attempt += 1) await page.waitForTimeout(100);
  assert.deepEqual(peerArchivePayloads.at(-1).keys, ["peer-parent", "peer-child"],
    "Peer archive request must use raw keys on the peer server route");
  assert.equal(childReads, 5, "Held-read and archive-conflict races must each trigger fresh reads");
  assert.equal(archivePosts, 2, "A server conflict must not archive until the user confirms again");
  assert.deepEqual(errors, [], `Unexpected page errors: ${errors.join("; ")}`);
  await context.close();
};
