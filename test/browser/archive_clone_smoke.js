const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");

module.exports = async ({ browser, baseUrl, captureDir }) => {
  const results = [];
  for (const width of [1440, 390]) {
    const context = await browser.newContext({ viewport: { width, height: 900 } });
    const page = await context.newPage();
    const errors = [];
    page.on("pageerror", error => errors.push(error.message));
    const response = await context.request.post(`${baseUrl}/agents`, { data: {
      project_key: "web", template_key: "custom", agent: "codex",
      name: `Archive source ${width}`, prompt: "Preserve fixture evidence."
    } });
    assert(response.ok());
    const source = (await response.json()).agent;
    await page.goto(`${baseUrl}/ui#agent/${source.key}/archive`, { waitUntil: "networkidle" });
    await page.locator("[data-clone-agent]").click();
    await page.locator("#agent-name").fill(`Independent clone ${width}`);
    const button = page.getByRole("button", { name: "Clone and archive", exact: true });
    if (captureDir) await page.screenshot({ path: path.join(captureDir, `clone-form-${width}.png`) });
    const cloneUrl = `${baseUrl}/agents/${source.key}/clone`;
    await page.route(cloneUrl, route => route.fulfill({ status: 503, contentType: "application/json", body: JSON.stringify({ error: "Fixture save failed" }) }), { times: 1 });
    const rejected = page.waitForResponse(r => r.url() === cloneUrl && r.status() === 503);
    await button.click();
    await rejected;
    await page.waitForFunction(() => !document.querySelector('#agent-form button[value="clone"]').disabled);
    assert.equal(await page.locator("#agent-name").inputValue(), `Independent clone ${width}`);
    assert.equal(await page.evaluate(key => state.agents.some(a => a.key === key), source.key), true);
    const beforeRetry = await (await context.request.get(`${baseUrl}/agents`)).json();
    assert.equal(beforeRetry.agents.filter(a => a.name === `Independent clone ${width}`).length, 0);
    const requested = page.waitForResponse(r => r.url().endsWith(`/agents/${source.key}/clone`) && r.request().method() === "POST");
    await button.click();
    const clonedResponse = await requested;
    const payload = clonedResponse.request().postDataJSON();
    const cloned = await clonedResponse.json();
    const catalog = await (await context.request.get(`${baseUrl}/agents`)).json();
    const proof = { width, payload, archived: cloned.archived, sourceActive: catalog.agents.some(a => a.key === source.key) };
    console.log(JSON.stringify(proof));
    assert.equal(proof.sourceActive, false, "Clone and archive left the source active");
    assert.equal(payload.archive_source, true);
    assert.equal(cloned.archived, true);
    assert.notEqual(cloned.agent.key, source.key);
    assert.equal(cloned.agent.name, `Independent clone ${width}`);
    assert.equal(cloned.agent.run_count, 0);
    const repeated = await context.request.post(cloneUrl, { data: payload });
    assert.equal(repeated.status(), 409, "Retry after a committed archive must not create another clone");
    const afterRetry = await (await context.request.get(`${baseUrl}/agents`)).json();
    assert.equal(afterRetry.agents.filter(a => a.name === `Independent clone ${width}`).length, 1);

    await page.waitForURL(`**#agent/${cloned.agent.key}`);
    await page.evaluate(async () => { await refresh({ force: true }); });
    assert.equal(await page.evaluate(key => state.agents.some(a => a.key === key), source.key), false);
    await page.reload({ waitUntil: "networkidle" });
    assert.equal((await (await context.request.get(`${baseUrl}/agents/${source.key}`)).json()).agent.archived, true);
    const overflow = await page.evaluate(() => document.documentElement.scrollWidth > innerWidth + 1);
    assert.equal(overflow, false);
    if (captureDir) await page.screenshot({ path: path.join(captureDir, `clone-result-${width}.png`) });
    await page.evaluate(() => navigate({ type: "tab", tab: "agents" }));
    await page.waitForFunction(name => els.view.textContent.includes(name), `Independent clone ${width}`);
    if (captureDir) await page.screenshot({ path: path.join(captureDir, `clone-agents-${width}.png`) });
    assert.deepEqual(errors, []);
    proof.rejectedSaveRetainedForm = true;
    proof.retryCreatedOneClone = true;
    proof.committedRetryRejected = true;
    results.push(proof);
    await context.close();
  }
  if (captureDir) fs.writeFileSync(path.join(captureDir, "archive-clone-results.json"), JSON.stringify(results, null, 2));
  console.log("archive-clone-smoke: ok");
};
