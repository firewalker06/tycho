const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
module.exports = async function({ page, context, request, captures }) {
  await page.route("**/*", route => new URL(route.request().url()).origin === new URL(page.url()).origin ? route.continue() : route.abort());
  for (const file of ["senggigi-beach.webp","depok-city.webp","waking-up.webp","cyberpunk.webp","CREDITS.txt","CC-BY-3.0.txt","CC-BY-SA-4.0.txt"]) {
    const response = await request("GET", `/theme-photos/${file}`, undefined, false);
    assert.equal(response.status,200,"Bundled asset needs no library credential");
    assert((await response.arrayBuffer()).byteLength > 1000);
  }
  const before = await (await request("GET", "/appearance/images")).json();
  const examples = await page.evaluate(() => TychoAppearance.getThemeState().examples);
  assert.deepEqual(examples.map(t => [t.name, t.mode]), [["Senggigi Beach","light"],["Depok City","dark"],["Waking Up","light"],["Cyberpunk","dark"]]);
  for (const theme of examples) {
    for (const width of [1920,1440,1024,390]) {
      await page.setViewportSize({width,height:width === 390 ? 844 : 1100});
      await page.locator(`[data-theme-example="${theme.id}"]`).click();
      await page.waitForFunction(id => TychoBackdropImages.getState().themePhoto?.id === id, theme.id);
      assert.equal(await page.locator("html").getAttribute("data-image-backdrop"), "theme");
      await page.evaluate(async () => { const image = new Image(); image.src = TychoBackdropImages.getState().themePhoto.url; await image.decode(); if (image.naturalWidth < 1000) throw Error("Small or missing photo"); });
      assert(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth), "No horizontal overflow");
      if (captures) { fs.mkdirSync(captures,{recursive:true}); await page.screenshot({path:path.join(captures,`photo-${theme.id.slice(8)}-${width}.png`)}); }
    }
    await page.reload();
    await page.getByRole("button", {name:"Configuration",exact:true}).click();
    await page.waitForFunction(id => TychoBackdropImages.getState().themePhoto?.id === id, theme.id);
    if (await page.locator("[data-theme-use-saved]").isVisible()) {
      await page.locator("[data-theme-use-saved]").click();
      await page.waitForFunction(() => !TychoBackdropImages.getState().themePhoto);
      await page.reload();
      await page.getByRole("button", {name:"Configuration",exact:true}).click();
      await page.waitForFunction(() => TychoBackdropImages.getState().loaded);
      assert.equal(await page.evaluate(() => TychoBackdropImages.getState().themePhoto), null);
      await page.locator("[data-theme-use-photo]").click();
      await page.waitForFunction(id => TychoBackdropImages.getState().themePhoto?.id === id, theme.id);
    }
  }
  const editor = page.locator("#custom-theme-editor");
  if (!(await editor.evaluate(node => node.open))) await editor.locator("summary").click();
  await page.locator('[data-theme-load="dark"]').click();
  const exported = JSON.parse(await page.locator("[data-custom-theme-json]").inputValue());
  assert.equal(exported.photo, undefined, "Portable custom JSON has no product asset path");
  await page.locator("[data-theme-save]").click();
  assert.equal(await page.locator(`[data-theme-example="${exported.id}"]`).count(),1);
  assert.equal(await page.evaluate(() => TychoAppearance.getThemePhoto()),null,"Photo copy is a palette custom theme");
  await page.locator(`[data-theme-delete="${exported.id}"]`).click();
  await editor.locator("summary").click();
  await page.setViewportSize({width:1920,height:1100});
  const alignment = await page.locator("[data-theme-gallery-item]").evaluateAll(nodes => nodes.map(node => ({top:node.getBoundingClientRect().top,bottom:node.getBoundingClientRect().bottom,button:node.querySelector("[data-theme-example]").getBoundingClientRect().bottom,art:node.querySelector(".theme-example-art").getBoundingClientRect().bottom})));
  for (const a of alignment) for (const b of alignment) if (Math.abs(a.top-b.top)<1) { assert(Math.abs(a.bottom-b.bottom)<1); assert(Math.abs(a.button-b.button)<1); assert(Math.abs(a.art-b.art)<1); }
  assert.equal(await page.locator('[data-theme-gallery-item^="builtin:"] [data-theme-delete]').count(),0);
  assert.deepEqual(await (await request("GET", "/appearance/images")).json(), before,"Photo selection preserves server library");
  const peer = await context.newPage();
  await peer.goto(page.url());
  await page.evaluate(() => {TychoAppearance.setPreference("dark");TychoAppearance.setTheme("dark","builtin:depok-city");});
  await peer.waitForFunction(() => TychoBackdropImages.getState().themePhoto?.id === "builtin:depok-city");
  await peer.close();
  await page.unroute("**/*");
  await page.evaluate(() => {TychoAppearance.setTheme("dark","agent-theme");TychoAppearance.setTheme("light","nord");TychoAppearance.setPreference("dark");});
  if(captures) fs.writeFileSync(path.join(captures,"theme-photo-results.json"),JSON.stringify({examples:examples.map(t=>({id:t.id,name:t.name,mode:t.mode})),widths:[1920,1440,1024,390],reload:true,saved_image_restore:true,portable_photo_copy:true,cross_tab:true,aligned_tiles:true,server_library:"unchanged"},null,2));
};
