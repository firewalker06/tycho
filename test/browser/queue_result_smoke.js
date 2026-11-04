const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");

module.exports = async ({ browser, baseUrl, agentKey, captureDir }) => {
  const results = [];
  const gate = () => { let release; const promise = new Promise(resolve => { release = resolve; }); return { promise, release }; };
  for (const width of [1440, 390]) for (const theme of ["dark", "light"]) {
    const context = await browser.newContext({ viewport: { width, height: 900 }, isMobile: width < 500, hasTouch: width < 500 });
    const page = await context.newPage();
    const errors = [];
    page.on("pageerror", error => errors.push(error.message));
    await page.addInitScript(() => { document.hasFocus = () => true; });
    page.setDefaultTimeout(10000);
    let held;
    try {
      await page.goto(`${baseUrl}/ui#settings`, { waitUntil: "networkidle" });
      await page.locator("[data-appearance-preference]").selectOption(theme);
      const original = (await (await page.request.get(`${baseUrl}/agents/${agentKey}`)).json()).agent;
      let canonical;
      const raw = () => ({ ...structuredClone(original), name: "Queue messages", running: false,
        prompt_queue: { entries: ["a", "b", "protected"].map(id => ({ id, prompt: ({a:"Prepare the summary",b:"Check the result",protected:"Reply from another agent"})[id], source: id === "protected" ? "delegation_callback" : "user", state: "queued" })),
          processing_stopped: true, unprocessed_reason: "debug-state-sentinel", processing: { state: "workspace", message: "Waiting for the workspace." } } });
      canonical = raw();
      await page.route(/\/servers\/(resources|activity)(\?.*)?$/, async route => {
        const response = await route.fetch();
        if (!response.ok()) return route.fulfill({ response });
        const replace = value => {
          if (Array.isArray(value)) return value.map(replace);
          if (!value || typeof value !== "object") return value;
          if (value.key === agentKey && (value.project_key || value.prompt_queue)) return structuredClone(canonical);
          return Object.fromEntries(Object.entries(value).map(([key, child]) => [key, replace(child)]));
        };
        return route.fulfill({ response, json: replace(await response.json()) });
      });
      await page.route(`${baseUrl}/agents/${agentKey}`, route => route.fulfill({ json: { agent: canonical } }));
      await page.goto(`${baseUrl}/ui#agent/${agentKey}`, { waitUntil: "networkidle" });
      for (const kind of ["process", "remove"]) for (const scenario of kind === "process"
        ? ["started", "busy", "refusal", "stale", "partial", "unknown", "empty", "invalid", "network", "peer", "auth", "newer", "navigation"]
        : ["removed", "partial", "stale", "unknown", "empty", "invalid", "network", "auth", "newer"]) {
        if (captureDir) fs.appendFileSync(path.join(captureDir, "progress.log"), `${width} ${theme} ${kind} ${scenario} start\n`);
        canonical = raw();
        await page.evaluate(async key => {
          state.pendingPromptQueueActions.delete(key);
          state.promptQueueSelections.delete(key);
          await ensureAgentDetail(key, true);
          state.renderedViewHtml = ""; render(); clearTimeout(state.timer);
          document.querySelector("[data-prompt-queue]").open = true;
        }, agentKey);
        await page.locator('[data-select-queue-entry="a"]').focus();
        await page.keyboard.press("Space");
        await page.locator('[data-select-queue-entry="b"]').check();
        const before = await page.evaluate(key => ({ selection: [...promptQueueSelection(key)], ids: findAgent(key).prompt_queue.entries.map(e => e.id) }), agentKey);
        assert.deepEqual(before.selection, ["a", "b"]);
        const seen = gate(); held = gate(); let writes = 0, sent;
        const endpoint = `${baseUrl}/agents/${agentKey}/prompt-queue/${kind}`;
        const handler = async route => {
          writes++; sent = route.request().postDataJSON(); seen.release(); await held.promise;
          if (scenario === "network") return route.abort("failed");
          if (scenario === "peer" || scenario === "auth") return route.fulfill({ status: scenario === "auth" ? 401 : 502, json: { error: "Synthetic peer/auth error" } });
          if (["empty", "invalid"].includes(scenario)) return route.fulfill({ status: 200, contentType: "application/json", body: scenario === "empty" ? "" : "invalid" });
          const ids = scenario === "stale" ? [] : scenario === "partial" ? ["a"] : ["a", "b"];
          const returned = raw();
          returned.running = scenario === "started";
          if (kind === "remove" && scenario !== "stale") returned.prompt_queue.entries = returned.prompt_queue.entries.filter(e => !ids.includes(e.id));
          if (scenario === "refusal") {
            returned.prompt_queue.dispatch_error = { message: "Synthetic token-secret /private/file" };
            returned.prompt_queue.queue_work = {batch_id:"batch", entry_ids:["a","b"], unresolved_entry_ids:["a","b"], entries:returned.prompt_queue.entries.filter(e=>e.id!=="protected")};
          }
          const status = scenario === "unknown" ? "unknown" : scenario === "stale" ? "stale" : kind === "remove" ? "removed" : scenario === "started" ? "started" : "accepted";
          if (!["newer", "navigation", "unknown"].includes(scenario)) canonical = structuredClone(returned);
          return route.fulfill({ json: { status, [kind === "remove" ? "removed_entry_ids" : "processed_entry_ids"]: ids,
            current_entry_ids: returned.prompt_queue.entries.map(e => e.id), agent: returned } });
        };
        await page.route(endpoint, handler);
        await page.locator(`[data-queue-action="${kind}-selected"]`).click();
        if (kind === "remove") await page.locator("[data-confirmation-accept]").click();
        await Promise.race([seen.promise, page.waitForTimeout(10000).then(() => { throw Error(`No mutation request: ${kind} ${scenario}`); })]);
        assert.deepEqual(sent, { entry_ids: ["a", "b"], expected_entry_ids: ["a", "b", "protected"] });
        await page.locator('[data-prompt-queue-management][aria-busy="true"]').waitFor();
        assert((await page.locator('[data-prompt-queue]').innerText()).includes(kind === "remove" ? "Removing messages" : "Processing queue"));
        await page.evaluate(async () => refresh({ force: true }));
        assert.equal(await page.locator('[data-queue-action="process-all"]').isEnabled(), false);
        if (scenario === "started") {
          await page.evaluate(() => { replaceView("<p>Synthetic conversation reload</p>"); state.renderedViewHtml = ""; render(); });
          assert.equal(await page.locator("[data-prompt-queue]").evaluate(node => node.open), true, "keep queue disclosure through a transient loading view");
        }
        if (captureDir && kind === "process" && scenario === "busy") await page.screenshot({ path: path.join(captureDir, `queue-pending-${width}-${theme}.png`) });
        if (scenario === "newer") {
          canonical.name = "Newer canonical name";
          canonical.prompt_queue.entries.push({ id: "newer", prompt: "New message", source: "user" });
          await page.evaluate(async key => { await ensureAgentDetail(key, true); state.promptQueueSelections.set(key, new Set(["newer"])); }, agentKey);
        }
        if (scenario === "navigation") {
          await page.evaluate(() => navigate({ type: "tab", tab: "agents" }));
          await page.waitForFunction(() => location.hash === "#agents");
        }
        held.release();
        const uncertain = ["unknown", "empty", "invalid", "network", "peer", "auth"].includes(scenario);
        await page.waitForFunction(({ key, uncertain }) => uncertain
          ? state.pendingPromptQueueActions.get(key)?.phase === "uncertain"
          : !state.pendingPromptQueueActions.has(key), { key: agentKey, uncertain });
        await page.waitForFunction(() => !state.refreshInFlight);
        const after = await page.evaluate(key => ({ selected: [...promptQueueSelection(key)], name: findAgent(key)?.name,
          ids: findAgent(key)?.prompt_queue?.entries.map(e => e.id), growl: document.querySelector("[role=status].growl")?.textContent || document.querySelector(".growl")?.textContent || "",
          hash: location.hash }), agentKey);
        if (scenario === "started") {
          await page.evaluate(() => { replaceView("<p>Synthetic post-result reload</p>"); state.renderedViewHtml = ""; render(); });
          assert.equal(await page.locator("[data-prompt-queue]").evaluate(node => node.open), true, "retain disclosure after confirmation and a temporary empty view");
          await page.locator("[data-prompt-queue] > summary").focus(); await page.keyboard.press("Enter");
          await page.evaluate(() => { replaceView("<p>Synthetic reload after operator close</p>"); state.renderedViewHtml = ""; render(); });
          assert.equal(await page.locator("[data-prompt-queue]").evaluate(node => node.open), false, "respect the operator's later close");
          await page.locator("[data-prompt-queue] > summary").focus(); await page.keyboard.press("Enter");
        }
        const text = after.growl;
        if (scenario === "started") assert(text.includes("Started 2 queued messages"));
        if (scenario === "busy") assert(text.includes("Accepted 2 queued messages") && text.includes("Waiting for the workspace") && !text.includes("Started"));
        if (scenario === "refusal") assert(text.includes("Could not process the queue") && !text.includes("Started"));
        if (scenario === "partial") assert(text.includes("1 of 2 selected") && !text.includes("Removed 2") && !text.includes("Started 2"));
        if (scenario === "stale") assert(text.includes("Queue changed"));
        if (uncertain) assert(text.includes("Could not confirm"));
        if (scenario === "newer") {
          assert.equal(after.name, "Newer canonical name"); assert(after.ids.includes("newer")); assert.deepEqual(after.selected, ["newer"]);
        }
        if (scenario === "navigation") assert.equal(after.hash, "#agents");
        if (uncertain) {
          assert.deepEqual(after.selected, ["a", "b"]);
          assert.equal(await page.locator('[data-queue-action="process-all"]').count(), 0);
          await page.locator("[data-review-queue-action]").waitFor();
          assert((await page.locator("[data-prompt-queue]").innerText()).includes("Could not confirm"));
          if (captureDir && scenario === "invalid" && kind === "process") await page.screenshot({ path: path.join(captureDir, `queue-uncertain-${width}-${theme}.png`) });
          // Recovery reads cannot replay the old write, even if a newer queue appears.
          canonical.prompt_queue.entries.push({ id: "later", prompt: "Later message", source: "user" });
          await page.locator("[data-review-queue-action]").focus(); await page.keyboard.press("Enter");
          await page.waitForFunction(key => !state.pendingPromptQueueActions.has(key), agentKey);
          assert.equal(writes, 1);
          assert(await page.evaluate(key => findAgent(key).prompt_queue.entries.some(e => e.id === "later"), agentKey));
          assert.equal(await page.locator('[data-queue-action="process-selected"]').isEnabled(), true);
        }
        if (scenario === "refusal") {
          assert((await page.locator("[data-prompt-queue]").innerText()).includes("Could not process the queue"));
          if (captureDir) await page.screenshot({ path: path.join(captureDir, `queue-refusal-${width}-${theme}.png`) });
        }
        if (scenario !== "navigation") {
          const productText = await page.locator("[data-prompt-queue]").innerText();
          assert(!/Synthetic|token-secret|debug-state-sentinel|private\/file/.test(productText));
          const bounds = await page.locator("[data-prompt-queue]").evaluate(node => ({ overflow: node.scrollWidth > node.clientWidth, right: node.getBoundingClientRect().right, viewport: innerWidth }));
          assert(!bounds.overflow && bounds.right <= bounds.viewport);
        }
        assert.equal(writes, 1);
        results.push({ width, theme, kind, scenario, writes, selection: after.selected, originalSnapshot: sent.expected_entry_ids });
        await page.unroute(endpoint, handler);
        if (scenario === "navigation") {
          await page.evaluate(key => navigate({ type: "agent", key }), agentKey);
          await page.locator("[data-prompt-queue]").waitFor();
        }
      }
      // Exercise the actual resource router and HTTP error parser for a synthetic peer.
      for (const status of [401, 502]) {
        let peerWrites = 0;
        const endpoint = `${baseUrl}/servers/peer-fixture/agents/queue/prompt-queue/process`;
        await page.route(endpoint, async route => { peerWrites++; return route.fulfill({ status, json: { error: "Synthetic routed peer error" } }); });
        const observed = await page.evaluate(async () => {
          const key = "peer-fixture/queue";
          state.pendingPromptQueueActions.delete(key);
          upsertAgent({ key, resource_key: "queue", server_key: "peer-fixture", name: "Remote queue", running: false,
            prompt_queue: { entries: [{ id: "peer-entry", source: "user", prompt: "Check the result" }] } });
          state.promptQueueSelections.set(key, new Set(["peer-entry"]));
          await runPromptQueueAction({ dataset: { agentKey: key, queueAction: "process-selected" } });
          return { phase: state.pendingPromptQueueActions.get(key)?.phase, selected: [...promptQueueSelection(key)] };
        });
        assert.equal(peerWrites, 1); assert.equal(observed.phase, "uncertain"); assert.deepEqual(observed.selected, ["peer-entry"]);
        results.push({ width, theme, kind: "process", scenario: `routed-peer-${status}`, writes: peerWrites });
      }
      assert.deepEqual(errors, []);
    } finally { held?.release(); await context.close(); }
  }
  if (captureDir) fs.writeFileSync(path.join(captureDir, "queue-result-browser-results.json"), JSON.stringify(results, null, 2));
  await require("./queue_recovery_smoke")({ browser, baseUrl, agentKey, captureDir });
  console.log(`queue_result_smoke: ${results.length} desktop/mobile Dark/Light cases passed`);
};
