const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");

module.exports = async function appearanceLayoutSmoke({ page, captures, guide }) {
  const results = [];
  const root = page.locator(".settings-appearance");
  const editor = page.locator("[data-custom-theme-json]");
  const preferences = page.locator("[data-appearance-preference]");
  const imageOptions = page.locator(".theme-image-settings details");
  const guideDetails = page.locator(".theme-agent-guide details");
  const jsonDetails = page.locator("#custom-theme-editor");
  const settle = () => page.evaluate(() => new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve))));
  const alignTop = async () => {
    await page.evaluate(() => {
      const heading = document.querySelector("#appearance-heading");
      const nav = document.querySelector(".settings-section-nav-shell");
      settingsScrollRoot().scrollTop += heading.getBoundingClientRect().top - nav.getBoundingClientRect().bottom - 20;
    });
    await settle();
  };
  const shot = async name => {
    if (!captures) return;
    fs.mkdirSync(captures, { recursive: true });
    await page.screenshot({ path: path.join(captures, `${name}.png`) });
  };
  for (const width of [1920, 1440, 1024, 768, 390]) for (const mode of ["dark", "light"]) {
    await page.setViewportSize({ width, height: width === 390 ? 844 : 1100 });
    await preferences.selectOption(mode);
    await page.waitForFunction(() => !TychoBackdropImages.getState().busy);
    await page.locator(".settings-appearance details").evaluateAll(nodes => nodes.forEach(node => { node.open = false; }));
    await alignTop();
    await page.locator("[data-theme-guide-copy]").click();
    assert.equal(await page.evaluate(() => navigator.clipboard.readText()), guide);
    await page.locator("[data-theme-guide-copy]").press("Tab");
    assert(await guideDetails.locator("summary").evaluate(node => node === document.activeElement), "Guide disclosure follows Copy in keyboard order");
    await page.keyboard.press("Tab");
    assert(await preferences.evaluate(node => node === document.activeElement), "Palette controls follow the guide in keyboard order");
    const geometry = await root.evaluate(section => {
      const rect = node => { const r = node.getBoundingClientRect(); return { left: r.left, right: r.right, top: r.top, bottom: r.bottom, width: r.width }; };
      const palette = section.querySelector(".appearance-palette-settings");
      const image = section.querySelector(".theme-image-settings");
      return { width: section.clientWidth, palette: rect(palette), image: rect(image), modeWidth: section.querySelector("#appearance-preference").getBoundingClientRect().width,
        columns: getComputedStyle(section.querySelector(".appearance-columns")).gridTemplateColumns.split(" ").length,
        sourceOrder: Boolean(palette.compareDocumentPosition(image) & Node.DOCUMENT_POSITION_FOLLOWING),
        unlabelled: [...section.querySelectorAll("input,select,textarea")].filter(node => !node.labels?.length && !node.getAttribute("aria-label")).map(node => node.id || node.type) };
    });
    assert.equal(geometry.columns, geometry.width >= 864 ? 2 : 1);
    assert(geometry.sourceOrder && !geometry.unlabelled.length, "Groups retain DOM order and labels");
    assert(geometry.palette.width <= 672 && geometry.image.width <= 672 && geometry.modeWidth <= 353, "Form controls have readable bounds");
    if (geometry.columns === 2) {
      assert(geometry.image.left >= geometry.palette.right + 24, "Wide groups have a clear gutter");
      assert(Math.abs(geometry.image.top - geometry.palette.top) < 2, "Peer groups align at the top");
    } else assert(geometry.image.top > geometry.palette.bottom, "Narrow groups stack in DOM order");
    const guideGeometry = await page.locator(".theme-agent-guide").evaluate(node => {
      const heading = node.querySelector("h4").getBoundingClientRect();
      const button = node.querySelector("button").getBoundingClientRect();
      return { left: node.getBoundingClientRect().left, headingLeft: heading.left, headingMiddle: (heading.top + heading.bottom) / 2, buttonMiddle: (button.top + button.bottom) / 2 };
    });
    assert(Math.abs(guideGeometry.left - guideGeometry.headingLeft) < 2, "Guide heading aligns with the form");
    if (geometry.width >= 576) assert(Math.abs(guideGeometry.headingMiddle - guideGeometry.buttonMiddle) < 2, "Wide guide heading and Copy share one row");
    await alignTop();
    await shot(`appearance-layout-${width}-${mode}`);
    // Exercise actual validation and retained drafts with both advanced groups open.
    await guideDetails.locator("summary").click();
    assert(await guideDetails.locator("pre").isVisible());
    await jsonDetails.locator("summary").click();
    await imageOptions.locator("summary").click();
    const draft = JSON.stringify({ bad: true, label: `${width} ${mode} pending palette` }, null, 2);
    await editor.fill(draft);
    await page.locator("[data-theme-save]").click();
    assert.match(await page.locator("[data-theme-result]").textContent(), /unique theme id/);
    await page.locator("[data-theme-image-file]").setInputFiles({ name: "invalid.svg", mimeType: "image/svg+xml", buffer: Buffer.from("<svg/>") });
    await page.waitForFunction(() => !TychoBackdropImages.getState().busy && Boolean(TychoBackdropImages.getState().error));
    assert.match(await page.locator("[data-theme-image-status]").textContent(), /PNG, JPEG, or WebP/);
    const startup = page.locator("[data-startup-message]");
    await startup.fill(`Layout draft ${width} ${mode}`);
    await editor.focus();
    await page.evaluate(() => refresh({ force: true }));
    await settle();
    assert.equal(await editor.inputValue(), draft, "Polling preserves the JSON draft");
    assert.equal(await startup.inputValue(), `Layout draft ${width} ${mode}`, "Polling preserves startup text");
    assert(await editor.evaluate(node => node === document.activeElement), "Polling preserves focus in the editor");
    assert(await imageOptions.evaluate(node => node.open));
    assert(await guideDetails.evaluate(node => node.open));
    assert(await jsonDetails.evaluate(node => node.open));
    await editor.press("Tab");
    assert(await page.locator("[data-theme-save]").evaluate(node => node === document.activeElement), "Save follows the editor in keyboard order");
    const overflow = await root.evaluate(section => {
      const bounds = section.getBoundingClientRect();
      return { page: document.documentElement.scrollWidth > innerWidth, outside: [...section.querySelectorAll("input,select,textarea,button,pre")].filter(node => {
        if (!node.getClientRects().length) return false;
        const r = node.getBoundingClientRect(); return r.left < bounds.left - 1 || r.right > bounds.right + 1;
      }).map(node => ({ control: node.id || node.type || node.textContent.slice(0, 30), right: node.getBoundingClientRect().right, edge: bounds.right })) };
    });
    assert(!overflow.page && !overflow.outside.length, JSON.stringify({ width, mode, overflow }));
    // Re-run validation after polling so the capture shows the current error with the retained draft.
    await page.locator("[data-theme-save]").click();
    assert.match(await page.locator("[data-theme-result]").textContent(), /unique theme id/);
    if (captures) {
      const target = width === 390 ? jsonDetails : page.locator(".appearance-columns");
      await target.screenshot({ path: path.join(captures, `appearance-advanced-errors-${width}-${mode}.png`) });
      if (width === 390) await page.locator(".theme-image-settings").screenshot({ path: path.join(captures, `appearance-image-options-${width}-${mode}.png`) });
    }
    // Clear the image validation error without changing the selected backdrop.
    await page.locator("[data-theme-image-retry]").click();
    await page.waitForFunction(() => !TychoBackdropImages.getState().error);
    results.push({ viewport: width, mode, ...geometry, overflow: false, draft_and_focus: "preserved", advanced_errors: "passed" });
  }
  await page.locator(".settings-appearance details").evaluateAll(nodes => nodes.forEach(node => { node.open = false; }));
  if (captures) fs.writeFileSync(path.join(captures, "appearance-layout-results.json"), JSON.stringify(results, null, 2));
  return results;
};
