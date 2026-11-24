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
  assert.deepEqual(errors, [], `Unexpected page errors: ${errors.join("; ")}`);
  await context.close();
};
