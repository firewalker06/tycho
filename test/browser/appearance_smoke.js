const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");

async function readable(locator, minimum = 4.5, focus = false) {
  const ratio = await locator.evaluate((element, focus) => {
    const canvas = document.createElement("canvas").getContext("2d");
    const rgba = (value) => {
      canvas.clearRect(0, 0, 1, 1);
      canvas.fillStyle = value;
      canvas.fillRect(0, 0, 1, 1);
      return [...canvas.getImageData(0, 0, 1, 1).data].map((value, index) => index === 3 ? value / 255 : value);
    };
    const over = (a, b) => a.slice(0, 3).map((value, index) => value * a[3] + b[index] * (1 - a[3])).concat(1);
    const chain = [];
    for (let node = focus ? element.parentElement : element; node; node = node.parentElement) chain.unshift(node);
    const background = chain.reduce((color, node) => over(rgba(getComputedStyle(node).backgroundColor), color), [255, 255, 255, 1]);
    const style = getComputedStyle(element);
    const foreground = rgba(focus ? style.outlineColor : style.color);
    if (!focus) for (let node = element; node; node = node.parentElement) foreground[3] *= Number(getComputedStyle(node).opacity);
    const luminance = (color) => color.slice(0, 3).map((value) => {
      value /= 255;
      return value <= 0.04045 ? value / 12.92 : ((value + 0.055) / 1.055) ** 2.4;
    }).reduce((sum, value, index) => sum + value * [0.2126, 0.7152, 0.0722][index], 0);
    const a = luminance(over(foreground, background)), b = luminance(background);
    return (Math.max(a, b) + 0.05) / (Math.min(a, b) + 0.05);
  }, focus);
  assert(ratio >= minimum, `${locator} contrast ${ratio.toFixed(3)} must reach ${minimum}:1`);
}

module.exports = async function appearanceSmoke({ browser, baseUrl, agentKey, captureDir = "" }) {
  const context = await browser.newContext({ viewport: { width: 1440, height: 1000 }, colorScheme: "light", reducedMotion: "reduce", serviceWorkers: "block" });
  const page = await context.newPage();
  const route = `${baseUrl}/ui#agent/${encodeURIComponent(agentKey)}`;
  const mode = (page) => page.locator("html").getAttribute("data-appearance");
  const waitMode = (page, value) => page.waitForFunction((value) => document.documentElement.dataset.appearance === value, value);
  const capture = async (name) => {
    if (!captureDir) return;
    fs.mkdirSync(captureDir, { recursive: true });
    await page.locator(".app-header").evaluate(async (element) => {
      await Promise.all(element.getAnimations().filter((animation) => Number.isFinite(animation.effect.getComputedTiming().endTime)).map((animation) => animation.finished.catch(() => {})));
    });
    await page.screenshot({ path: path.join(captureDir, `${name}.png`) });
  };
  try {
    await page.goto(`${baseUrl}/ui#settings`);
    await page.locator("[data-appearance-preference]").waitFor();
    assert.equal(await mode(page), "dark", "a new browser keeps dark even with a light OS");
    await page.locator('[data-scroll-settings-section="settings-configuration"]').click();
    await page.locator("[data-appearance-preference]").selectOption("light");
    await waitMode(page, "light");
    const peer = await context.newPage();
    await peer.goto(route);
    await peer.locator("#prompt-input").fill("Draft survives appearance changes.");
    await page.locator("[data-appearance-preference]").selectOption("dark");
    await waitMode(peer, "dark");
    assert.equal(await peer.locator("#prompt-input").inputValue(), "Draft survives appearance changes.", "cross-tab changes preserve a conversation draft");
    await page.locator("[data-appearance-preference]").selectOption("system");
    await waitMode(page, "light");
    await page.emulateMedia({ colorScheme: "dark" });
    await waitMode(page, "dark");
    await page.emulateMedia({ colorScheme: "light" });
    await waitMode(page, "light");
    await page.locator("[data-appearance-preference]").selectOption("light");
    await page.emulateMedia({ colorScheme: "dark" });
    assert.equal(await mode(page), "light", "an explicit choice overrides the OS");
    await peer.close();

    // Pause CSS on reload to inspect the head bootstrap before the app can paint.
    let releaseCss;
    let cssRequested;
    const cssGate = new Promise((resolve) => { releaseCss = resolve; });
    const requested = new Promise((resolve) => { cssRequested = resolve; });
    await page.route("**/ui.css?*", async (request) => { cssRequested(); await cssGate; await request.continue(); });
    const reload = page.reload({ waitUntil: "domcontentloaded" });
    await requested;
    await waitMode(page, "light");
    assert.equal(await page.locator('meta[name="theme-color"]').getAttribute("content"), "#e5e9f0");
    assert.equal(await page.evaluate(() => document.documentElement.style.colorScheme), "light", "native controls match before app startup");
    releaseCss();
    await reload;
    await page.unroute("**/ui.css?*");
    await page.locator("[data-appearance-preference]").waitFor();
    assert.equal(await page.locator("[data-appearance-preference]").inputValue(), "light", "reload keeps the explicit choice");
    await page.evaluate(() => refresh({ force: true }));
    assert.equal(await page.locator("[data-appearance-preference]").inputValue(), "light", "polling keeps the choice");

    for (const [device, viewport] of Object.entries({ desktop: { width: 1440, height: 1000 }, mobile: { width: 390, height: 844 } })) {
      await page.setViewportSize(viewport);
      await page.goto(`${baseUrl}/ui#settings`);
      await page.locator("[data-appearance-preference]").waitFor();
      await page.locator('[data-scroll-settings-section="settings-configuration"]').click();
      await page.locator(".settings-appearance").scrollIntoViewIfNeeded();
      await page.locator("[data-appearance-preference]").focus();
      await readable(page.locator('.settings-section-nav button[aria-current="location"]'));
      await capture(`light-${device}-selector`);
      await page.goto(route);
      await page.locator("#prompt-input").waitFor();
      await page.locator(".message.assistant").first().waitFor();
      await page.locator(".message.user").first().waitFor();
      await page.locator("#prompt-input").fill("Review the selected Nord mapping.");
      await page.locator("#prompt-input").focus();
      const colors = await page.evaluate(() => ({
        canvas: getComputedStyle(document.body).backgroundColor,
        user: getComputedStyle(document.querySelector(".message.user")).backgroundColor,
        assistant: getComputedStyle(document.querySelector(".message.assistant")).backgroundColor,
      }));
      assert.deepEqual(colors, { canvas: "rgb(229, 233, 240)", user: "rgb(136, 192, 208)", assistant: "rgb(236, 239, 244)" }, "the selected message mapping reaches the real UI");
      await readable(page.locator(".message.user .message-role").first());
      await capture(`light-${device}-conversation`);
      await page.evaluate((key) => {
        const agent = findAgent(key);
        agent.latest_inquiry = { id: "appearance-fixture", message: "Review the selected Nord appearance.", fields: [
          { key: "theme", label: "Light theme", description: "Synthetic inquiry for required and enabled states.", input_type: "select", required: true, options: ["Nord Light"] },
        ] };
        agent.attachments = [{ type: "link", title: "Synthetic preview notes", url: "https://example.test/notes" }];
        state.renderedViewHtml = "";
        render();
      }, agentKey);
      if (device === "mobile") await page.locator(".mobile-inquiry > summary").click();
      const field = page.locator("#inquiry-form select");
      const send = page.locator('#inquiry-form button[type="submit"]');
      await field.focus();
      await page.keyboard.press("Tab");
      await page.keyboard.press("Shift+Tab");
      await page.locator(".inquiry-fields").evaluate((element) => { element.scrollTop = 0; });
      assert.equal(await field.getAttribute("aria-invalid"), "true");
      assert(await send.isDisabled(), "required answers stay gated");
      await readable(send);
      await readable(page.locator("[data-inquiry-field-error]").first());
      await readable(field, 3, true);
      await capture(`light-${device}-inquiry-validation`);
      await field.selectOption("Nord Light");
      await field.focus();
      await page.keyboard.press("Tab");
      await page.keyboard.press("Shift+Tab");
      await page.locator(".inquiry-fields").evaluate((element) => { element.scrollTop = 0; });
      await page.waitForFunction(() => {
        const button = document.querySelector('#inquiry-form button[type="submit"]');
        return !button.disabled && getComputedStyle(button).backgroundColor === "rgb(136, 192, 208)";
      });
      assert.equal(await field.getAttribute("aria-invalid"), "false");
      await readable(send);
      await readable(field);
      await capture(`light-${device}-inquiry-selected`);
      await page.getByRole("button", { name: "Show attachments", exact: true }).click();
      await page.locator("[data-attachment-flyout]").waitFor({ state: "visible" });
      await capture(`light-${device}-inquiry-attachments`);
      assert.equal(await page.evaluate(() => document.documentElement.scrollWidth > innerWidth), false, "mobile and desktop panels stay within the viewport");
      await page.evaluate(() => window.TychoAppearance.setPreference("dark"));
      assert.equal(await field.inputValue(), "Nord Light", "switching mode preserves an inquiry answer");
      await field.selectOption("");
      assert(await send.isDisabled(), "dark mode still enforces required answers");
      await send.evaluate(async (element) => {
        await Promise.all(element.getAnimations().filter((animation) => Number.isFinite(animation.effect.getComputedTiming().endTime)).map((animation) => animation.finished.catch(() => {})));
      });
      await capture(`dark-${device}-inquiry`);
      await page.evaluate((key) => {
        window.TychoAppearance.setPreference("light");
        findAgent(key).latest_inquiry = null;
        state.renderedViewHtml = "";
        render();
      }, agentKey);
      await page.locator("#header-more-button").click();
      await page.locator("#header-more-panel").waitFor({ state: "visible" });
      await capture(`light-${device}-menu`);
      await page.locator("#header-more-button").click();
      await page.evaluate(() => { void confirmAction({ title: "Review appearance", description: "Synthetic confirmation; no action is sent.", intent: "danger" }); });
      await page.locator("#confirmation-dialog").waitFor({ state: "visible" });
      await capture(`light-${device}-dialog`);
      await page.locator("[data-confirmation-cancel]").click();
      await page.goto(`${baseUrl}/ui#agents`);
      await page.locator("#quick-agent-fab").click();
      await page.locator("#quick-agent-prompt").fill("Synthetic draft; do not run.");
      if (await page.locator("[data-quick-agent-toggle]").getAttribute("aria-expanded") === "false") {
        await page.locator("[data-quick-agent-toggle]").click();
      }
      await page.locator("[data-quick-agent-model]").waitFor({ state: "visible" });
      await page.evaluate(() => { window.TychoAppearance.setPreference("dark"); window.TychoAppearance.setPreference("light"); });
      assert.equal(await page.locator("#quick-agent-prompt").inputValue(), "Synthetic draft; do not run.", "appearance changes preserve dialog drafts");
      await capture(`light-${device}-options`);
      await page.locator("[data-quick-agent-close]").click();
    }

    // Render through the same Markdown and Mermaid path used by real conversations.
    const fence = String.fromCharCode(96).repeat(3);
    await page.route(new RegExp(`/agents/${agentKey}/conversation(?:\\?|$)`), async (request) => {
      const response = await request.fetch();
      const data = await response.json();
      data.conversation = [{ id: "appearance-markdown", kind: "message", role: "assistant", content:
        `## Readability sample\n\n| State | Action |\n| --- | --- |\n| Ready | Review |\n\n${fence}ruby\n# Synthetic source\nputs "ready"\n${fence}\n\n${fence}mermaid\nflowchart LR\n A[Draft] --> B[Review]\n${fence}` }];
      data.conversation_block_count = 1;
      data.conversation_has_older = false;
      await request.fulfill({ json: data });
    });
    // Leave the app document so this fixture cannot reuse the earlier conversation cache.
    await page.goto("about:blank");
    await page.goto(route, { waitUntil: "networkidle" });
    await page.locator("#prompt-input").waitFor();
    assert(await page.evaluate(async () => { const ready = await ensureMarkdownParserLoaded(); state.renderedRouteKey = null; state.renderedViewHtml = ""; render(); return ready; }), "the Markdown renderer must load for the chart check");
    await page.locator("code.language-mermaid").waitFor();
    const block = page.locator(".markdown-code-block").filter({ has: page.locator("code.language-mermaid") });
    const retainedSource = await block.locator("pre > code").textContent();
    await block.locator("[data-toggle-markdown-code-menu]").click();
    await page.locator(".markdown-code-menu-popover:not([hidden]) [data-preview-mermaid-code]").click();
    await block.locator(".mermaid svg").waitFor({ timeout: 30000 });
    assert.equal(await page.evaluate(() => window.mermaid.mermaidAPI.getConfig().theme), "base");
    await page.evaluate(() => window.TychoAppearance.setPreference("dark"));
    await block.locator(".mermaid svg").waitFor({ timeout: 30000 });
    assert.equal(await page.evaluate(() => window.mermaid.mermaidAPI.getConfig().theme), "redux-dark-color");
    await capture("dark-mobile-markdown");
    await page.evaluate(() => window.TychoAppearance.setPreference("light"));
    await block.locator(".mermaid svg").waitFor({ timeout: 30000 });
    assert.equal(await page.evaluate(() => window.mermaid.mermaidAPI.getConfig().securityLevel), "strict", "mode changes retain diagram security");
    assert.equal(await block.locator("pre > code").textContent(), retainedSource, "mode changes retain diagram source");
    for (const [device, viewport] of Object.entries({ desktop: { width: 1440, height: 1000 }, mobile: { width: 390, height: 844 } })) {
      await page.setViewportSize(viewport);
      await capture(`light-${device}-markdown`);
      assert.equal(await page.evaluate(() => document.documentElement.scrollWidth > innerWidth), false, "Markdown tables and charts stay within the page");
    }
    console.log("appearance_smoke: ok");
  } finally {
    await context.close();
  }
};
