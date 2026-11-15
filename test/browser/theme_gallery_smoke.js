const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");

module.exports = async function themeGallerySmoke({ page, context, base, request, captures }) {
  const tile = (target, id) => target.locator(`[data-theme-example="${id}"]`);
  const remove = (target, id) => target.locator(`[data-theme-delete="${id}"]`);
  const save = async (target, theme) => {
    const details = target.locator("#custom-theme-editor");
    if (!(await details.evaluate(node => node.open))) await details.locator("summary").click();
    await target.locator("[data-custom-theme-json]").fill(JSON.stringify(theme, null, 2));
    await target.locator("[data-theme-save]").click();
  };
  const images = async () => (await (await request("GET", "/appearance/images")).json()).images;
  const selectedImages = async () => page.evaluate(() => {
    const preference = TychoAppearance.getState().preference, result = {};
    for (const mode of ["dark", "light"]) { TychoAppearance.setPreference(mode); result[mode] = TychoBackdropImages.getState().image?.serverId; }
    TychoAppearance.setPreference(preference);
    return result;
  });
  const assetsBefore = await images(), choicesBefore = await selectedImages();
  const themes = await page.evaluate(() => TychoAppearance.getThemeState());
  const dusk = { ...themes.samples.dark, id: "imported-dusk", name: "Imported Dusk" };
  const morning = { ...themes.samples.light, id: "imported-morning", name: "Imported Morning", backdrop: themes.examples.find(theme => theme.mode === "light").backdrop };
  const spare = { ...themes.samples.dark, id: "unselected-custom", name: "Unselected Custom" };
  assert.equal(await page.getByRole("heading", { name: "Scenes", exact: true }).count(), 0);
  assert.equal(await page.getByRole("heading", { name: "Themes", exact: true }).count(), 1);
  await save(page, dusk);
  assert.equal(await tile(page, dusk.id).count(), 1, "Import immediately adds a visible tile");
  assert(await tile(page, dusk.id).isVisible());
  assert.match(await tile(page, dusk.id).locator(".theme-example-art").evaluate(node => getComputedStyle(node).backgroundImage), /linear-gradient/);
  await save(page, { ...dusk, name: "Updated Dusk" });
  assert.equal(await tile(page, dusk.id).count(), 1, "Duplicate id updates one tile");
  assert.match(await tile(page, dusk.id).textContent(), /Updated Dusk/);
  assert(await page.locator("[data-theme-save]").evaluate(node => document.activeElement === node), "Gallery refresh keeps editor action focus");
  await save(page, morning);
  assert.equal(await page.locator("[data-appearance-preference]").inputValue(), "dark", "Importing light does not switch active mode");
  assert.match(await tile(page, morning.id).locator(".theme-example-art").evaluate(node => getComputedStyle(node).backgroundImage), /data:image\/svg/);
  await save(page, { ...dusk, mode: "light" });
  assert.match(await page.locator("[data-theme-result]").textContent(), /different id/);
  assert.match(await tile(page, dusk.id).textContent(), /Updated Dusk/);
  await save(page, spare);
  await tile(page, dusk.id).focus(); await tile(page, dusk.id).press("Tab");
  assert(await remove(page, dusk.id).evaluate(node => node === document.activeElement), "Tab reaches the tile's Delete action");
  await remove(page, dusk.id).press("Shift+Tab");
  assert(await tile(page, dusk.id).evaluate(node => node === document.activeElement));
  await tile(page, dusk.id).press("Enter");
  assert.equal(await page.locator("[data-theme-mode=dark]").inputValue(), dusk.id);
  await page.reload();
  await page.getByRole("button", { name: "Configuration", exact: true }).click();
  await tile(page, dusk.id).waitFor();
  assert.equal(await page.locator("[data-theme-mode=dark]").inputValue(), dusk.id, "Selection and tile persist on reload");
  assert.equal(await tile(page, dusk.id).getAttribute("aria-pressed"), "true");
  const peer = await context.newPage();
  try {
    await peer.goto(`${base}/ui#settings`);
    await peer.getByRole("button", { name: "Configuration", exact: true }).click();
    await tile(peer, dusk.id).waitFor();
    await remove(page, dusk.id).focus();
    await page.locator("[data-theme-gallery]").evaluate(node => { node.scrollTop = 60; });
    const scrollBefore = await page.locator("[data-theme-gallery]").evaluate(node => node.scrollTop);
    await page.evaluate(() => refresh({ force: true }));
    assert(await remove(page, dusk.id).evaluate(node => node === document.activeElement), "Polling keeps gallery keyboard focus");
    assert.equal(await page.locator("[data-theme-gallery]").evaluate(node => node.scrollTop), scrollBefore, "Polling keeps gallery scroll");
    await save(peer, { ...dusk, name: "Shared Dusk" });
    await page.waitForFunction(() => document.querySelector('[data-theme-example="imported-dusk"]')?.textContent.includes("Shared Dusk"));
    assert(await remove(page, dusk.id).evaluate(node => node === document.activeElement), "Cross-tab tile update keeps keyboard focus");
    await remove(page, spare.id).focus(); await remove(page, spare.id).press("Space");
    assert.equal(await tile(page, spare.id).count(), 0);
    assert.equal(await page.locator("[data-theme-mode=dark]").inputValue(), dusk.id, "Unselected deletion keeps the active theme");
    await peer.waitForFunction(() => !document.querySelector('[data-theme-example="unselected-custom"]'));
    assert(await tile(page, "agent-theme").count(), "An unrelated custom theme remains");
    const capturedGallery = await page.evaluate(() => ({ bundled: document.querySelectorAll('[data-theme-gallery-item^="builtin:"]').length, custom: TychoAppearance.getThemeState().custom.length, tiles: document.querySelectorAll('[data-theme-gallery-item]').length }));
    for (const width of [1920, 1440, 1024, 390]) for (const mode of ["dark", "light"]) {
      await page.setViewportSize({ width, height: width === 390 ? 844 : 1100 });
      await page.locator("[data-appearance-preference]").selectOption(mode);
      await page.evaluate(() => {
        document.querySelector("#custom-theme-editor").open = false;
        document.querySelector("[data-theme-gallery]").scrollTop = 0;
        const heading = document.querySelector("#appearance-heading"), nav = document.querySelector(".settings-section-nav-shell");
        settingsScrollRoot().scrollTop += heading.getBoundingClientRect().top - nav.getBoundingClientRect().bottom - 20;
      });
      assert(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth));
      assert.equal(await tile(page, dusk.id).count(), 1);
      assert.equal(await tile(page, morning.id).count(), 1);
      assert.equal(await page.locator('[data-theme-gallery-item^="builtin:"] [data-theme-delete]').count(), 0, "Bundled assets have no Delete control");
      if (captures) { fs.mkdirSync(captures, { recursive: true }); await page.screenshot({ path: path.join(captures, `themes-gallery-${width}-${mode}.png`) }); await page.locator("[data-theme-gallery]").screenshot({ path: path.join(captures, `themes-tiles-${width}-${mode}.png`) }); }
    }
    await tile(page, dusk.id).focus(); await tile(page, dusk.id).press("Enter");
    await remove(page, dusk.id).focus(); await remove(page, dusk.id).press("Enter");
    assert.equal(await page.locator("[data-theme-mode=dark]").inputValue(), "dracula");
    assert.equal(await page.locator("html").getAttribute("data-theme"), "dracula");
    assert(await page.locator("[data-theme-mode=dark]").evaluate(node => node === document.activeElement));
    await peer.waitForFunction(() => !document.querySelector('[data-theme-example="imported-dusk"]') && document.querySelector('[data-theme-mode="dark"]').value === "dracula");
    assert.match(await page.locator("[data-theme-removal-result]").textContent(), /Images are unchanged/);
    assert.equal(await tile(page, morning.id).count(), 1, "Selected deletion preserves other themes");
    await tile(page, morning.id).focus(); await tile(page, morning.id).press("Space");
    assert.equal(await page.locator("[data-appearance-preference]").inputValue(), "light");
    await remove(page, morning.id).click();
    assert.equal(await page.locator("[data-theme-mode=light]").inputValue(), "nord");
    assert.equal(await page.locator("html").getAttribute("data-theme"), "nord");
    assert.deepEqual(await selectedImages(), choicesBefore, "Theme deletion preserves per-mode image choices");
    assert.deepEqual(await images(), assetsBefore, "Theme deletion does not delete or replace server images");
    assert.equal(await tile(page, "agent-theme").count(), 1);
    assert.equal(await page.locator('[data-theme-gallery-item^="builtin:"]').count(), 4);
    if (captures) {
      const evidence = { captured_gallery: capturedGallery, after_deletion_tiles: await page.locator("[data-theme-gallery-item]").count(), import_updates: "immediate", duplicate_id: "one updated tile", mode_change: "rejected", selected_defaults: { dark: "dracula", light: "nord" }, unselected_deletion: "selection preserved", cross_tab: "updated and deleted", keyboard: "Enter and Space", image_choices: choicesBefore, server_images: "unchanged", bundled_themes: "preserved" };
      fs.writeFileSync(path.join(captures, "theme-gallery-results.json"), JSON.stringify(evidence, null, 2));
    }
  } finally { await peer.close(); }
};
