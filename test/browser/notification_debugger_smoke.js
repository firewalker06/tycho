const assert = require("node:assert/strict");

module.exports = async function notificationDebuggerSmoke({ page, baseUrl }) {
  const synthetic = {
    agent: { key: "synthetic-agent", name: "Synthetic review", session_id: "native-fixture", target_state: "active" },
    server: { id: "synthetic-server", name: "Local fixture" }, type: "failed", event: "finished",
    payload: { title: "Failed", body: "Synthetic review: Retained result", url: "/#notification/preview" },
    target_url: "/#agent/synthetic-agent", build: { version: "fixture", asset_version: "fixture-assets" },
    delivery: "Preview only; nothing sent",
  };
  let sends = 0;
  let previews = 0;
  let scenario = "ok";
  await page.route("**/push/agent-preview", async (route) => {
    previews += 1;
    const body = route.request().postDataJSON();
    assert.equal(body.session_id, "native-fixture");
    assert.equal(body.type, "failed");
    assert(!body.endpoint, "preview must not send a subscription capability");
    if (scenario === "missing") return route.fulfill({ status: 404, json: { error: "No retained agent matches this ID on this server" } });
    if (scenario === "ambiguous" && !body.agent_key) return route.fulfill({ json: { choices: [synthetic.agent, { key: "second-agent", name: "Second fixture", target_state: "archived" }] } });
    return route.fulfill({ json: synthetic });
  });
  await page.route("**/push/agent-test", async (route) => {
    sends += 1;
    const body = route.request().postDataJSON();
    assert.equal(body.endpoint, "https://push.example.test/current-browser");
    assert.equal(body.session_id, "native-fixture");
    assert.equal(body.type, "failed");
    assert.equal(body.agent_key, "synthetic-agent");
    return route.fulfill({ json: { ...synthetic, record_id: "debug:synthetic", payload: { ...synthetic.payload, url: "/#notification/debug%3Asynthetic" }, delivery: { sent: 1, failed: 0, attempted: 1, disabled: 0 } } });
  });
  await page.route("**/push/status", (route) => route.fulfill({ json: { subscribed: true } }));
  const actualDiagnostics = await page.evaluate(() => notificationBrowserDiagnostics());
  assert.match(actualDiagnostics.served_worker_sha256, /^[0-9a-f]{64}$/);
  assert(!JSON.stringify(actualDiagnostics).includes("endpoint"));
  for (const viewport of [{ width: 1440, height: 900 }, { width: 390, height: 844 }]) {
    await page.setViewportSize(viewport);
    await page.goto(`${baseUrl}/ui#settings`, { waitUntil: "networkidle" });
    await page.locator("#settings-panel-notifications").waitFor();
    await page.evaluate(() => {
      state.setup.push.notification_types = [
        { key: "succeeded", title: "Done", event: "finished" },
        { key: "failed", title: "Failed", event: "finished" },
        { key: "awaiting-input", title: "Input needed", event: "input_required" },
      ];
      render();
    });
    await page.locator('[aria-controls="settings-panel-notifications"]').click();
    if (!(await page.locator("#notification-debugger").evaluate((element) => element.open))) await page.locator("#notification-debugger > summary").click();
    const form = page.locator("#notification-debugger-form");
    assert.equal(await form.locator("input").getAttribute("required"), "");
    await form.getByLabel("Agent session ID or Tycho key").fill("native-fixture");
    await form.getByLabel("Notification type").selectOption("failed");
    // Only browser capability discovery is synthetic. No permission prompt or registration occurs.
    await page.evaluate(() => {
      notificationBrowserDiagnostics = async () => ({ permission: "default", subscribed: false, subscription_present: false, served_worker_sha256: "fixture-sha256", worker_note: "Synthetic browser capability check" });
    });
    const previewCount = previews;
    const beforeSends = sends;
    await form.getByRole("button", { name: "Preview notification" }).click();
    await page.locator("[data-notification-debug-preview]").waitFor();
    assert(previews > previewCount);
    assert(await form.getByRole("button", { name: "Send to this browser" }).isDisabled());
    assert.equal(sends, beforeSends, "preview must never send");
    await page.evaluate(() => {
      notificationBrowserDiagnostics = async () => ({ permission: "granted", subscribed: true, subscription_present: true, served_worker_sha256: "fixture-sha256" });
      currentPushSubscription = async () => ({ endpoint: "https://push.example.test/current-browser" });
    });
    await page.evaluate(() => {
      window.notificationSmokeBrokerPost = brokerPost;
      brokerPost = async (path, body) => {
        if (path === "/push/agent-preview") throw new Error("No retained agent matches this ID on this server");
        return window.notificationSmokeBrokerPost(path, body);
      };
    });
    await form.getByRole("button", { name: "Preview notification" }).click();
    await page.getByText("No retained agent matches this ID on this server", { exact: true }).waitFor();
    await page.evaluate(() => { brokerPost = window.notificationSmokeBrokerPost; delete window.notificationSmokeBrokerPost; });
    scenario = "ambiguous";
    await form.getByRole("button", { name: "Preview notification" }).click();
    await page.locator("#notification-agent-choice").waitFor();
    assert(await form.getByRole("button", { name: "Send to this browser" }).isDisabled());
    await page.locator("#notification-agent-choice").selectOption("synthetic-agent");
    await form.getByRole("button", { name: "Preview notification" }).click();
    await page.locator("[data-notification-debug-preview]").waitFor();
    await page.evaluate(() => render());
    assert.equal(await form.getByLabel("Agent session ID or Tycho key").inputValue(), "native-fixture", "polling must preserve identity input");
    assert.equal(await form.getByLabel("Notification type").inputValue(), "failed");
    assert(await form.innerText().then((text) => text.includes("/#agent/synthetic-agent") && text.includes("Local fixture") && text.includes("Retained result")));
    for (const button of await form.locator("button:visible").all()) {
      if (!(await button.isDisabled())) await button.click({ trial: true });
      const bounds = await button.boundingBox();
      assert(bounds.width >= 44 && bounds.height >= 44);
    }
    await form.getByRole("button", { name: "Send to this browser" }).click();
    await page.getByText(/Provider accepted 1; failed 0; attempted 1/).waitFor();
    assert.equal(sends, beforeSends + 1, "one explicit click sends one scoped request");
    if (!(await page.locator(".notification-debug-diagnostics").evaluate((element) => element.open))) await page.locator(".notification-debug-diagnostics > summary").click();
    const trace = await page.evaluate(() => JSON.stringify(notificationDebugTrace()));
    assert(trace.includes("debug:synthetic") && !trace.includes("https://push.example.test") && !trace.includes("endpoint"));
    const downloadPromise = page.waitForEvent("download");
    await page.locator("[data-export-notification-trace]").click();
    const download = await downloadPromise;
    assert.equal(download.suggestedFilename(), "tycho-notification-trace.json");
    await form.getByLabel("Agent session ID or Tycho key").fill("changed");
    assert(await form.getByRole("button", { name: "Send to this browser" }).isDisabled(), "changed identity invalidates preview");
    assert.equal(await page.locator("[data-notification-debug-preview]").count(), 0);
    assert(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth && els.view.scrollWidth <= els.view.clientWidth), "debugger must not overflow");
    scenario = "ok";
  }
  await page.unroute("**/push/agent-preview");
  await page.unroute("**/push/agent-test");
  await page.unroute("**/push/status");
};
