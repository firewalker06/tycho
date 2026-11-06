const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");

module.exports = async ({browser, baseUrl, captureDir}) => {
  const key = "web-inquiry-recovery-0";
  const apiContext = await browser.newContext();
  const response = await apiContext.request.get(`${baseUrl}/agents/${key}`);
  const data = await response.json();
  await apiContext.close();
  const {agent} = data;
  assert(agent?.latest_inquiry, "fixture must have an inquiry");
  const layouts = [
    {name: "desktop-split", width: 1440, height: 900},
    {name: "desktop-no-split", width: 1000, height: 900},
    {name: "mobile", width: 390, height: 844},
  ];
  const results = [];
  for (const layout of layouts) {
    const context = await browser.newContext({viewport: {width: layout.width, height: layout.height}, isMobile: layout.width < 500, hasTouch: layout.width < 500});
    const page = await context.newPage();
    try {
      await page.route(new RegExp(`/agents/${key}/inquiries/[^/]+/answer$`), route => route.fulfill({status:503, contentType:"application/json", body:JSON.stringify({error:"Synthetic failed answer"})}));
      await page.goto(`${baseUrl}/ui#agent/${key}`, {waitUntil: "networkidle"});
      await page.waitForSelector("#inquiry-form", {state:"attached"});
      if (layout.width < 500) await page.locator(".mobile-inquiry > summary").click();
      const button = page.locator("[data-toggle-inquiry-full-screen]").first();
      const geometry = await button.evaluate(el => {
        const r = el.getBoundingClientRect();
        const p = el.parentElement.getBoundingClientRect();
        el.focus();
        return {button: {top:r.top,bottom:r.bottom,left:r.left,right:r.right}, parent:{top:p.top,bottom:p.bottom,left:p.left,right:p.right}, focusVisible:el.matches(":focus-visible"), outline:getComputedStyle(el).outlineStyle};
      });
      if (captureDir) {
        fs.mkdirSync(captureDir, {recursive:true});
        await page.screenshot({path:path.join(captureDir, `${layout.name}-before.png`), clip: await page.locator("#inquiry-form").boundingBox()});
      }
      results.push({layout:layout.name, geometry});
      const form = page.locator("#inquiry-form");
      const submit = form.locator("button[type=submit]");
      await submit.scrollIntoViewIfNeeded();
      const clearance = await form.evaluate(el => {
        const formRect = el.getBoundingClientRect();
        const buttonRect = el.querySelector("button[type=submit]").getBoundingClientRect();
        return formRect.bottom - buttonRect.bottom;
      });
      assert(clearance >= 6, `${layout.name} submit button needs 6px of bottom padding; got ${clearance}px`);
      await submit.focus();
      if (captureDir) await page.screenshot({path:path.join(captureDir, `${layout.name}-after.png`), clip: await form.boundingBox()});
      await form.locator('input[type="text"]').fill("One-line synthetic answer");
      await submit.click();
      await page.waitForSelector("[data-inquiry-answer-recovery]");
      await page.reload({waitUntil:"networkidle"});
      await page.waitForSelector("[data-inquiry-answer-recovery]", {state:"attached"});
      if (layout.width < 500 && !await form.isVisible()) await page.locator(".mobile-inquiry > summary").click();
      assert.equal(await form.locator("[data-retry-inquiry-answer]").count(),1,"failed form has Retry");
      assert.equal(await form.locator("[data-cancel-inquiry-answer]").count(),1,"failed form has Remove");
      if (captureDir) await page.screenshot({path:path.join(captureDir, `${layout.name}-failed-after.png`), clip: await form.boundingBox()});
    } finally { await context.close(); }
  }
  if (captureDir) fs.writeFileSync(path.join(captureDir, "inquiry-card-padding.json"), JSON.stringify(results,null,2));
  console.log(JSON.stringify(results));
};
