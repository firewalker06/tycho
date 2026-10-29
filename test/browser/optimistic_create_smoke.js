const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");

module.exports = async ({ browser, baseUrl, captureDir }) => {
  const receipts = [];
  if (captureDir) fs.mkdirSync(captureDir, { recursive: true });
  for (const width of [1440, 390]) {
    const context = await browser.newContext({ viewport: { width, height: 900 }, isMobile: width < 500 });
    const page = await context.newPage();
    const errors = [];
    page.on("pageerror", error => errors.push(error.message));
    const capture = async label => {
      assert(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth + 1), "horizontal overflow");
      if (captureDir) await page.screenshot({ path: path.join(captureDir, `create-${label}-${width}.png`) });
    };
    const checkErrorComposition = async expectedLabels => {
      const layout = await page.locator(".agent-creation-error").evaluate(card => {
        const content = card.querySelector(".agent-creation-error-content");
        const actions = card.querySelector(".agent-creation-error-actions");
        const buttons = [...actions.querySelectorAll("button")];
        const rect = el => { const r = el.getBoundingClientRect(); return { top: r.top, right: r.right, bottom: r.bottom, left: r.left }; };
        return {
          card: rect(card), content: rect(content), reason: rect(content.querySelector("p")), reasonFits: content.querySelector("p").scrollWidth <= content.querySelector("p").clientWidth, actions: rect(actions), buttons: buttons.map(rect),
          labels: buttons.map(button => button.textContent),
          titleAlign: getComputedStyle(content.querySelector("h2")).textAlign,
          reasonAlign: getComputedStyle(content.querySelector("p")).textAlign,
          borderWidth: getComputedStyle(actions).borderTopWidth,
          borderColor: getComputedStyle(actions).borderTopColor,
          borderToken: getComputedStyle(card).borderTopColor,
          justify: getComputedStyle(actions).justifyContent,
          rightPadding: parseFloat(getComputedStyle(actions).paddingRight),
        };
      });
      assert.deepEqual(layout.labels, expectedLabels);
      assert.equal(layout.titleAlign, "center");
      assert.equal(layout.reasonAlign, "center");
      assert(layout.reasonFits && layout.reason.left >= layout.card.left && layout.reason.right <= layout.card.right, "server reason must remain readable inside the card");
      assert.equal(layout.borderWidth, "1px");
      assert.equal(layout.borderColor, layout.borderToken, "divider must use the existing border color");
      assert.equal(layout.justify, "flex-end");
      assert(layout.actions.top >= layout.content.bottom - 1, "actions overlap error content");
      const last = layout.buttons.at(-1);
      assert(Math.abs(last.right - (layout.actions.right - layout.rightPadding)) < 2, "actions are not right aligned");
      for (const button of layout.buttons) {
        assert(button.top > layout.content.bottom && button.bottom < layout.actions.bottom);
        assert(button.left >= layout.card.left && button.right <= layout.card.right);
      }
      if (layout.buttons.length === 2) {
        assert(layout.buttons[0].left < layout.buttons[1].left, "Edit request must precede Discard");
        assert(Math.abs(layout.buttons[0].top - layout.buttons[1].top) < 1, "mobile actions must fit one row");
      }
      assert.equal(await page.locator("#screen-title").innerText(), "New agent");
      assert.equal(await page.locator("#screen-subtitle").innerText(), "Web");
      assert(await page.locator("#back-button").isVisible());
      assert.equal(await page.locator(".pending-agent-conversation h1, .pending-agent-conversation details").count(), 0);
      return layout;
    };
    const createCount = async () => (await (await context.request.get(`${baseUrl}/agents`)).json()).agents.length;
    const openForm = async quick => {
      await page.goto(`${baseUrl}/ui#${quick ? "agents" : "project/web"}`, { waitUntil: "networkidle" });
      if (quick) {
        await page.locator("#quick-agent-fab").click();
        await page.locator("#quick-agent-prompt").fill(`Keep quick prompt ${width}`);
      } else {
        await page.locator("#view [data-create-agent=web]").first().click();
        await page.locator("#agent-prompt").fill(`Keep project prompt ${width}`);
        assert.equal(await page.locator("#agent-form select[name=project_key]").count(), 0, "removed Project field returned");
      }
    };
    for (const quick of [true, false]) {
      await openForm(quick);
      let release;
      const held = new Promise(resolve => { release = resolve; });
      let calls = 0;
      let payload;
      await page.route(`${baseUrl}/agents`, async route => {
        if (route.request().method() !== "POST") return route.continue();
        calls += 1;
        payload = route.request().postDataJSON();
        await held;
        await route.continue();
      });
      await page.evaluate(() => {
        resourceServer("local").agents = [{ key: "unrelated", prompt: "PRIVATE_UNRELATED_PROMPT" }];
        resourceServer("local").token = "PRIVATE_UNRELATED_BEARER";
      });
      const before = await createCount();
      const start = Date.now();
      const submit = quick ? "#quick-agent-form button[type=submit]" : "#agent-form button[value=create]";
      await page.locator(submit).click();
      await page.locator(".pending-agent-conversation").waitFor();
      const visibleMs = Date.now() - start;
      assert(visibleMs < 1500, `pending view took ${visibleMs}ms`);
      assert.equal(await page.locator("#quick-agent-dialog").evaluate(el => el.open), false);
      assert.match(await page.locator(".pending-agent-conversation").innerText(), /Creating your agent/);
      assert.equal(await page.locator(".pending-agent-conversation").evaluate(el => el === document.activeElement), true, "pending view did not receive focus");
      assert.equal(await page.locator(".pending-agent-conversation h1, .pending-agent-conversation details").count(), 0);
      assert(!(await page.locator(".pending-agent-conversation").innerText()).includes("Your request"));
      assert.equal(await page.locator("#composer").count(), 0, "pending request must not allow agent actions");
      await page.evaluate(() => refresh({ force: true }));
      assert.equal(await page.locator(".pending-agent-conversation").count(), 1);
      assert.equal(calls, 1);
      assert.equal(await createCount(), before);
      const stored = await page.evaluate(() => sessionStorage.getItem(AGENT_CREATION_STORAGE_KEY));
      assert(!stored.includes("PRIVATE_UNRELATED"), "storage retained unrelated server data");
      assert.equal(JSON.parse(stored).filter(entry => entry.payload).length, 1);
      await capture(quick ? "quick-pending" : "project-pending");
      if (!quick) {
        // Going Back to the create form must retain this request and must not submit again.
        await page.goBack();
        await page.locator(".pending-agent-conversation").waitFor();
        assert.equal(await page.locator("#agent-form").count(), 0);
      }
      release();
      await page.waitForFunction(() => location.hash.startsWith("#agent/"));
      await page.locator("#composer").waitFor();
      const key = await page.evaluate(() => parseRoute().key);
      const agent = (await (await context.request.get(`${baseUrl}/agents/${key}`)).json()).agent;
      assert.equal(agent.project_key, "web");
      assert.equal(agent.prompt, payload.prompt);
      assert.equal(payload.start, quick);
      assert.equal(agent.run_count, quick ? 1 : 0);
      assert.equal(await createCount(), before + 1);
      await capture(quick ? "quick-success" : "project-success");
      const completed = await page.evaluate(() => JSON.parse(sessionStorage.getItem(AGENT_CREATION_STORAGE_KEY)));
      assert(completed.every(entry => Object.keys(entry).sort().join(",") === "agentKey,id"), "completed requests retained payloads");
      receipts.push({ width, flow: quick ? "quick" : "project-create-only", visibleMs, postCount: calls, runCount: agent.run_count });
      await page.unroute(`${baseUrl}/agents`);
    }

    // A server error with uncertain acceptance keeps the request ID for keyboard retry.
    await openForm(false);
    const beforeFailure = await createCount();
    let failureRequestId;
    let releaseFailure;
    const failureHeld = new Promise(resolve => { releaseFailure = resolve; });
    await page.route(`${baseUrl}/agents`, async route => {
      failureRequestId = route.request().postDataJSON().client_request_id;
      await failureHeld;
      await route.fulfill({ status: 503, contentType: "application/json", body: JSON.stringify({ error: "Fixture create service unavailable. This longer server reason checks readable wrapping on a narrow screen. Please try again when the service is ready." }) });
    }, { times: 1 });
    await page.locator("#agent-form button[value=create-run]").click();
    await page.locator(".pending-agent-conversation").waitFor();
    releaseFailure();
    const retry = page.locator("[data-retry-agent-create]");
    await retry.waitFor();
    assert.equal(await retry.evaluate(el => el === document.activeElement), true, "failure did not focus retry");
    assert.match(await page.locator("[role=alert]").innerText(), /Fixture create service unavailable/);
    assert.equal(await page.evaluate(() => [...pendingAgentCreations.values()].find(entry => entry.error)?.payload.prompt), `Keep project prompt ${width}`);
    assert.equal(await page.locator("[data-edit-agent-create], [data-discard-agent-create]").count(), 0, "uncertain response must keep the same request");
    await page.evaluate(() => refresh({ force: true }));
    await checkErrorComposition(["Try again"]);
    await capture("error");
    let releaseRetry;
    const retryHeld = new Promise(resolve => { releaseRetry = resolve; });
    let retryCalls = 0;
    await page.route(`${baseUrl}/agents`, async route => { retryCalls++; assert.equal(route.request().postDataJSON().client_request_id, failureRequestId); await retryHeld; await route.continue(); });
    await retry.focus();
    await page.keyboard.press("Enter");
    await page.locator(".pending-agent-conversation[aria-busy=true]").waitFor();
    await page.evaluate(() => {
      const entry = [...pendingAgentCreations.values()].find(entry => entry.pending);
      sendPendingAgentCreation(entry);
      sendPendingAgentCreation(entry);
    });
    assert.equal(retryCalls, 1);
    releaseRetry();
    await page.waitForFunction(() => location.hash.startsWith("#agent/"));
    assert.equal(await createCount(), beforeFailure + 1);
    await page.unroute(`${baseUrl}/agents`);

    // The server accepts, but the response is lost. Reload then retry with the same ID.
    await openForm(false);
    const beforeLoss = await createCount();
    let accepted;
    let acceptedRequestId;
    await page.route(`${baseUrl}/agents`, async route => {
      acceptedRequestId = route.request().postDataJSON().client_request_id;
      const response = await route.fetch();
      assert.equal(response.status(), 201);
      accepted = (await response.json()).agent;
      await route.abort("connectionfailed");
    }, { times: 1 });
    await page.locator("#agent-form button[value=create]").click();
    await retry.waitFor();
    await page.reload({ waitUntil: "networkidle" });
    await retry.waitFor();
    const recoveredResponse = page.waitForResponse(r => r.url() === `${baseUrl}/agents` && r.request().method() === "POST");
    await retry.click();
    assert.equal((await recoveredResponse).request().postDataJSON().client_request_id, acceptedRequestId);
    await page.waitForFunction(() => location.hash.startsWith("#agent/"));
    assert.equal(await page.evaluate(() => parseRoute().key), accepted.key);
    assert.equal(await createCount(), beforeLoss + 1, "lost response retry duplicated agent");

    // The real API rejects whitespace. The user can correct or discard it,
    // including after navigation and reload, without reusing its rejected ID.
    await openForm(false);
    const beforeCorrection = await createCount();
    await page.locator("#agent-form > details.agent-options > summary").click();
    await page.locator("#agent-name").fill("Correction name");
    await page.locator("#agent-prompt").fill("   ");
    const rejectedResponse = page.waitForResponse(r => r.url() === `${baseUrl}/agents` && r.request().method() === "POST");
    await page.locator("#agent-form button[value=create]").click();
    const rejected = await rejectedResponse;
    assert.equal(rejected.status(), 400);
    assert.equal((await rejected.json()).details.creation_rejected, true);
    const rejectedId = rejected.request().postDataJSON().client_request_id;
    await page.locator("[data-edit-agent-create]").waitFor();
    assert.match(await page.locator("[role=alert]").innerText(), /Prompt is required/);
    assert.equal(await page.locator("[data-edit-agent-create]").evaluate(el => el === document.activeElement), true);
    const errorLayout = await checkErrorComposition(["Edit request", "Discard"]);
    await page.keyboard.press("Tab");
    assert.equal(await page.locator("[data-discard-agent-create]").evaluate(el => el === document.activeElement), true);
    await page.keyboard.press("Shift+Tab");
    assert.equal(await page.locator("[data-edit-agent-create]").evaluate(el => el === document.activeElement), true);
    receipts.push({ width, flow: "error-composition", divider: errorLayout.borderWidth, rightAligned: true, contentSeparate: true, actionOrder: errorLayout.labels, keyboardOrder: true });
    await capture("rejected");
    await page.goBack();
    await page.locator("[data-edit-agent-create]").waitFor();
    await page.reload({ waitUntil: "networkidle" });
    await page.locator("[data-edit-agent-create]").click();
    await page.locator("#agent-prompt").fill(`Corrected prompt ${width}`);
    await page.locator("#agent-form > details.agent-options > summary").click();
    assert.equal(await page.locator("#agent-name").inputValue(), "Correction name");
    await page.evaluate(() => refresh({ force: true }));
    assert.equal(await page.locator("#agent-prompt").inputValue(), `Corrected prompt ${width}`);
    await page.evaluate(() => navigate({ type: "project", key: "web" }));
    await page.locator("#view [data-create-agent=web]").first().click();
    await page.locator("#agent-form").waitFor();
    assert.equal(await page.locator("#agent-prompt").inputValue(), `Corrected prompt ${width}`);
    await page.reload({ waitUntil: "networkidle" });
    assert.equal(await page.locator("#agent-prompt").inputValue(), `Corrected prompt ${width}`);
    await capture("correction");
    const correctedResponse = page.waitForResponse(r => r.url() === `${baseUrl}/agents` && r.request().method() === "POST");
    await page.locator("#agent-form button[value=create]").click();
    const corrected = await correctedResponse;
    assert.equal(corrected.status(), 201);
    assert.notEqual(corrected.request().postDataJSON().client_request_id, rejectedId);
    assert.equal((await corrected.json()).agent.prompt, `Corrected prompt ${width}`);
    await page.waitForFunction(() => location.hash.startsWith("#agent/"));
    assert.equal(await createCount(), beforeCorrection + 1);

    await openForm(false);
    await page.locator("#agent-prompt").fill("   ");
    await page.locator("#agent-form button[value=create]").click();
    await page.locator("[data-discard-agent-create]").waitFor();
    await page.reload({ waitUntil: "networkidle" });
    await page.locator("[data-edit-agent-create]").click();
    await page.locator("#agent-prompt").fill("Discarded draft");
    await page.goBack();
    await page.locator("[data-discard-agent-create]").click();
    await page.locator("#agent-form").waitFor();
    await page.reload({ waitUntil: "networkidle" });
    assert.equal(await page.locator("#agent-form").count(), 1, "discard restored the rejected trap");
    assert.notEqual(await page.locator("#agent-prompt").inputValue(), "Discarded draft", "discard restored an old correction draft");
    assert.equal(await page.evaluate(() => [...pendingAgentCreations.values()].filter(entry => entry.payload).length), 0);

    // A user who leaves the pending view keeps their chosen page after success.
    await openForm(false);
    let releaseNavigation;
    const navigationHeld = new Promise(resolve => { releaseNavigation = resolve; });
    await page.route(`${baseUrl}/agents`, async route => { await navigationHeld; await route.continue(); }, { times: 1 });
    await page.locator("#agent-form button[value=create]").click();
    await page.locator(".pending-agent-conversation").waitFor();
    await page.evaluate(() => navigate({ type: "project", key: "web" }));
    await page.waitForFunction(() => location.hash === "#project/web");
    releaseNavigation();
    await page.waitForFunction(() => [...pendingAgentCreations.values()].every(entry => !entry.pending));
    assert.equal(await page.evaluate(() => location.hash), "#project/web", "success overrode user navigation");
    assert.deepEqual(errors, []);
    await context.close();
  }
  console.log(JSON.stringify({ test: "optimistic-create", receipts }));
  if (captureDir) fs.writeFileSync(path.join(captureDir, "browser-receipts.json"), JSON.stringify(receipts, null, 2));
};
