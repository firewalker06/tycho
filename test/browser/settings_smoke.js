const assert = require("node:assert/strict");

module.exports = async function settingsSmoke({ page, baseUrl }) {
  const response = await page.request.get(`${baseUrl}/setup`);
  const fixture = await response.json();
  Object.assign(fixture.setup, {
    auth: { required: false, status: "Local access", warning: null },
    tailscale: { available: false, magic_dns: false },
    server: { restartable: true },
    schema: { valid: true, path: "~/.tycho/config/schemas/agent_result.json" },
    harnesses: ["codex", "claude", "opencode", "pi"].map((name) => ({
      name, ready: true, detail: `${name} is available`, commands: [name],
      auth_snapshot: { state: "authenticated" }, model_suggestions: ["example-model"],
    })),
    tools: [{ name: "gh", ready: true, detail: "GitHub CLI is available" }],
  });
  await page.route("**/setup", (route) => route.fulfill({ json: fixture }));
  await page.emulateMedia({ reducedMotion: "reduce" });
  await page.goto(`${baseUrl}/ui#settings`, { waitUntil: "networkidle" });
  await page.locator(".automation-ready-details").waitFor({ state: "attached" });

  async function renderFixture(change) {
    await page.evaluate((change) => {
      Object.assign(state.setup, change);
      render();
    }, change);
  }

  for (const viewport of [{ width: 1440, height: 900 }, { width: 390, height: 844 }]) {
    await page.setViewportSize(viewport);
    assert.equal(await page.locator(".settings-section-heading h2").count(), 6);
    for (const section of ["connection", "servers", "notifications", "automation", "skills", "configuration"]) {
      const control = page.locator(`[aria-controls="settings-panel-${section}"]`);
      await control.click();
      await page.waitForTimeout(600);
      assert.equal(await control.getAttribute("aria-current"), "location", `${viewport.width}px ${section}`);
      const geometry = await page.evaluate((section) => {
        const panel = document.getElementById(`settings-panel-${section}`).getBoundingClientRect();
        const nav = document.querySelector(".settings-section-nav-shell").getBoundingClientRect();
        return { panelTop: panel.top, navBottom: nav.bottom, overflow: document.documentElement.scrollWidth > innerWidth };
      }, section);
      assert(!geometry.overflow, "Settings must not overflow horizontally");
      assert(geometry.panelTop >= geometry.navBottom - 2, `${section} heading must clear the section navigator`);
    }
    if (viewport.width === 390) {
      const scroll = await page.evaluate(() => {
        const root = settingsScrollRoot();
        const nav = els.nav.getBoundingClientRect();
        const content = root.getBoundingClientRect();
        return { contentBottom: content.bottom, navTop: nav.top, navBottom: nav.bottom, height: innerHeight, scrollable: root.scrollHeight > root.clientHeight };
      });
      assert(scroll.scrollable && scroll.contentBottom <= scroll.navTop + 1);
      assert(scroll.navBottom <= scroll.height + 1);
      // Walk the complete content range, in both directions, with real wheel input.
      await page.locator('[aria-controls="settings-panel-connection"]').click();
      await page.waitForTimeout(600);
      await page.mouse.move(180, 400);
      const steps = await page.evaluate(() => Math.ceil(els.view.scrollHeight / 500) + 1);
      for (const delta of [...Array(steps).fill(500), ...Array(steps).fill(-500)]) {
        await page.mouse.wheel(0, delta);
        await page.waitForTimeout(50);
        assert.equal(await page.locator("#bottom-nav.nav-hidden").count(), 0);
        for (const tab of ["now", "agents", "settings"]) {
          const button = page.locator(`#bottom-nav [data-tab="${tab}"]`);
          await button.click({ trial: true });
          const box = await button.boundingBox();
          assert(box.width >= 44 && box.height >= 44);
        }
      }
      await page.locator('[aria-controls="settings-panel-connection"]').click();
      await page.waitForTimeout(600);
      const keyScrollStart = await page.evaluate(() => els.view.scrollTop);
      await page.keyboard.press("PageDown");
      await page.waitForTimeout(250);
      assert(await page.evaluate((top) => els.view.scrollTop > top, keyScrollStart), "Keyboard input must scroll Settings content");
    }
  }

  await page.locator('[aria-controls="settings-panel-connection"]').click();
  await page.locator(".connection-details > summary").focus();
  await page.keyboard.press("Enter");
  assert.equal(await page.locator(".connection-details").getAttribute("open"), "");
  for (const fact of ["Authentication", "API", "Transport", "Naming"]) {
    assert(await page.locator(".connection-details").getByText(fact, { exact: true }).isVisible());
  }
  const detailsBefore = await page.evaluate(() => ({ top: els.view.scrollTop, open: document.querySelector(".connection-details").open }));
  await page.evaluate(() => refresh({ force: true }));
  assert.deepEqual(await page.evaluate(() => ({ top: els.view.scrollTop, open: document.querySelector(".connection-details").open })), detailsBefore);

  await page.locator('[aria-controls="settings-panel-automation"]').click();
  const ready = page.locator(".automation-ready-details");
  assert.equal(await ready.getAttribute("open"), null);
  await ready.locator(":scope > summary").click();
  assert(await page.getByText("1 tool", { exact: true }).isVisible());
  for (const name of ["codex", "claude", "opencode", "pi"]) {
    const harness = page.locator(`[data-harness-name="${name}"]`);
    await harness.locator(":scope > summary").click();
    assert(await harness.getByText("Authentication: Authenticated", { exact: true }).isVisible());
    await harness.locator(`summary[aria-label="${name} actions"]`).click();
    await harness.getByRole("menuitem", { name: "Check authentication", exact: true }).click({ trial: true });
    await page.keyboard.press("Escape");
    await harness.locator(":scope > summary").click();
  }
  // A focused draft, disclosure, and the mobile scroll position survive real polling.
  await page.locator('[data-harness-name="codex"] > summary').click();
  await page.locator('[data-harness-name="codex"] .harness-catalog-editor > summary').click();
  const models = page.locator("#harness-codex-models");
  await models.fill("kept-during-refresh");
  const before = await page.evaluate(() => ({ top: els.view.scrollTop, active: document.activeElement.id }));
  await page.evaluate(() => refresh({ force: true }));
  assert.equal(await models.inputValue(), "kept-during-refresh");
  assert.deepEqual(await page.evaluate(() => ({ top: els.view.scrollTop, active: document.activeElement.id })), before);
  assert.equal(await ready.getAttribute("open"), "");

  // Render real warning/missing data without invoking install, login, or restart actions.
  const warningHarnesses = structuredClone(fixture.setup.harnesses);
  warningHarnesses[0].ready = false;
  warningHarnesses[0].detail = "codex executable is missing";
  warningHarnesses[1].auth_snapshot = { state: "unauthenticated" };
  warningHarnesses[2].auth_snapshot = { state: "unknown", checked_at: "2026-10-15T00:00:00Z" };
  warningHarnesses[3].safety_gaps = ["Synthetic safety warning"];
  await renderFixture({ harnesses: warningHarnesses, schema: { valid: false }, server: { restartable: false }, tools: [{ name: "gh", ready: false, detail: "gh executable is missing" }] });
  assert.equal(await ready.count(), 0, "Failures must not enter the healthy disclosure");
  assert(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth && els.view.scrollWidth <= els.view.clientWidth), "Warning states must fit the mobile content width");
  assert(await page.locator('[data-harness-name="codex"] > summary').getByText("Missing", { exact: true }).isVisible());
  assert(await page.locator('[data-harness-name="claude"] > summary').getByText("Unauthenticated", { exact: true }).isVisible());
  for (const name of ["opencode", "pi"]) {
    assert(await page.locator(`[data-harness-name="${name}"] > summary`).getByText("Review diagnostics", { exact: true }).isVisible());
  }
  for (const text of ["Invalid", "Off", "gh executable is missing", "Synthetic safety warning"]) {
    const target = page.getByText(text, { exact: true });
    await target.scrollIntoViewIfNeeded();
    assert(await target.isVisible());
  }
  await renderFixture({ auth: { required: false, status: "Unprotected access", warning: "Synthetic token warning" } });
  await page.locator('[aria-controls="settings-panel-connection"]').click();
  assert(await page.getByText("Synthetic token warning", { exact: true }).isVisible());
  await renderFixture({ harnesses: fixture.setup.harnesses.map((item) => ({ ...item, auth_snapshot: {} })), schema: fixture.setup.schema, server: fixture.setup.server, tools: [] });
  await page.locator('[aria-controls="settings-panel-automation"]').click();
  assert(await page.getByText("Authentication not checked", { exact: true }).isVisible());
  assert(await page.locator(".automation-ready-details > summary").getByText(/0 tools/).isVisible());
  await renderFixture({ tools: [fixture.setup.tools[0], { name: "other", ready: true }] });
  assert(await page.locator(".automation-ready-details > summary").getByText(/2 tools/).isVisible());

  const migration = await page.evaluate(async () => {
    const original = { brokerPost, requestServerResourceRefresh, schedule, render, showGrowl };
    const previous = localStorage.getItem(SERVER_TOKENS_STORAGE_KEY);
    const servers = state.servers;
    try {
      localStorage.setItem(SERVER_TOKENS_STORAGE_KEY, JSON.stringify({ fixture: "synthetic-token" }));
      const forwarded = resourceHeaders("fixture")["X-Tycho-Remote-Server-Token"] === "synthetic-token";
      brokerPost = async () => { throw new Error("Synthetic persistence failure"); };
      try { await saveRemoteServerToken("fixture", "synthetic-token"); } catch (_error) { /* Expected. */ }
      const retained = remoteServerToken("fixture") === "synthetic-token";
      brokerPost = async () => ({ servers });
      requestServerResourceRefresh = async () => {};
      schedule = render = showGrowl = () => {};
      await saveRemoteServerToken("fixture", "synthetic-token");
      return { forwarded, retained, removed: remoteServerToken("fixture") === "", writerAbsent: typeof storeRemoteServerToken === "undefined" };
    } finally {
      ({ brokerPost, requestServerResourceRefresh, schedule, render, showGrowl } = original);
      state.servers = servers;
      if (previous === null) localStorage.removeItem(SERVER_TOKENS_STORAGE_KEY);
      else localStorage.setItem(SERVER_TOKENS_STORAGE_KEY, previous);
    }
  });
  assert.deepEqual(migration, { forwarded: true, retained: true, removed: true, writerAbsent: true });
  // Leaving Settings restores ordinary page scrolling and native top-level navigation.
  await page.locator('#bottom-nav [data-tab="agents"]').click();
  await page.locator(".content.settings-page").waitFor({ state: "detached" });
  await page.locator('#bottom-nav [data-tab="settings"]').click();
  await page.locator(".content.settings-page").waitFor({ state: "visible" });
};
