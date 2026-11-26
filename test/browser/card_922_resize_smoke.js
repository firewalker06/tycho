const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");

async function dragToStableMaximum(page, textarea, label, targetInset) {
  const initialHeight = await textarea.evaluate(element => element.getBoundingClientRect().height);
  const dragHeights = [];
  let stable = false;
  for (let drag = 0; drag < 80; drag++) {
    await textarea.scrollIntoViewIfNeeded();
    const box = await textarea.boundingBox();
    await page.mouse.move(box.x + box.width - 5, box.y + box.height - 5);
    await page.mouse.down();
    await page.mouse.move(box.x + box.width - 5, page.viewportSize().height - targetInset, {steps:10});
    await page.mouse.up();
    const height = await textarea.evaluate(element => element.getBoundingClientRect().height);
    dragHeights.push(height);
    if (height <= box.height + 1) {
      stable = true;
      break;
    }
  }
  assert(stable, `${label} did not reach a stable maximum within 80 drags: ${JSON.stringify(dragHeights)}`);
  assert(dragHeights.at(-1) > initialHeight + 1, `${label} did not grow during resize: ${JSON.stringify(dragHeights)}`);
  return {initialHeight, maximumHeight:dragHeights.at(-1), drags:dragHeights.length, dragHeights};
}

async function assertSubmitReachable(page, selector, label) {
  const submit = page.locator(selector);
  await submit.scrollIntoViewIfNeeded();
  assert(await submit.evaluate(element => {
    const box = element.getBoundingClientRect();
    return box.top >= 0 && box.bottom <= innerHeight && element.contains(document.elementFromPoint(box.x + box.width / 2, box.y + box.height / 2));
  }), `${label} submit control is reachable after maximum drag`);
}

module.exports = async ({browser, baseUrl, agentKey, captureDir}) => {
  const cases = [
    {name:"desktop", width:1260, height:875},
    {name:"mobile", width:390, height:844, mobile:true},
  ];
  const results = [];
  for (const layout of cases) {
    const context = await browser.newContext({viewport:{width:layout.width,height:layout.height},isMobile:!!layout.mobile,hasTouch:!!layout.mobile});
    const page = await context.newPage();
    await page.goto(`${baseUrl}/ui#agent/${agentKey}`, {waitUntil:"networkidle"});
    await page.waitForSelector("#composer textarea");
    const composer = page.locator("#prompt-input");
    await composer.fill("Conversation resize fixture\n".repeat(8));
    const composerBefore = await composer.evaluate(e => ({height:e.getBoundingClientRect().height, maxHeight:getComputedStyle(e).maxHeight, resize:getComputedStyle(e).resize, panel:e.closest(".agent-dock").getBoundingClientRect().toJSON(), shell:e.closest(".composer-editor-shell").getBoundingClientRect().toJSON()}));
    if (captureDir) await page.screenshot({path:path.join(captureDir,`before-composer-${layout.name}.png`)});
    await page.locator("[data-toggle-composer-full-screen]").click();
    const composerExpanded = await composer.evaluate(e => ({height:e.getBoundingClientRect().height, maxHeight:getComputedStyle(e).maxHeight, resize:getComputedStyle(e).resize, form:e.closest("form").className, panel:e.closest(".agent-dock")?.getBoundingClientRect().toJSON(), shell:e.closest(".composer-editor-shell")?.getBoundingClientRect().toJSON(), send:e.closest("form").querySelector("button[type=submit]")?.getBoundingClientRect().toJSON()}));
    const composerBox = await composer.boundingBox();
    await page.mouse.move(composerBox.x+composerBox.width-5,composerBox.y+composerBox.height-5);
    await page.mouse.down();
    await page.mouse.move(composerBox.x+composerBox.width-5,layout.height-30,{steps:10});
    await page.mouse.up();
    const composerAfter = await composer.evaluate(e => ({height:e.getBoundingClientRect().height, maxHeight:getComputedStyle(e).maxHeight, form:e.closest("form").className, panel:e.closest(".agent-dock")?.getBoundingClientRect().toJSON(), send:e.closest("form").querySelector("button[type=submit]")?.getBoundingClientRect().toJSON()}));
    if (layout.width >= 900) {
      assert.match(composerExpanded.form,/composer-full-height/);
      assert(composerExpanded.shell.height >= 200, `expanded Conversation textarea fills the panel: ${JSON.stringify(composerExpanded)}`);
    }
    const composerSubmit = page.locator("#composer button[type=submit]");
    await composerSubmit.scrollIntoViewIfNeeded();
    assert(await composerSubmit.evaluate(e => {const r=e.getBoundingClientRect();return r.top>=0&&r.bottom<=innerHeight&&e.contains(document.elementFromPoint(r.x+r.width/2,r.y+r.height/2));}), "Conversation submit control remains reachable after maximum drag");
    if (captureDir) await page.screenshot({path:path.join(captureDir,`after-composer-${layout.name}.png`)});

    const inquiry = await context.newPage();
    await inquiry.goto(`${baseUrl}/ui#agent/web-inquiry-recovery-0`, {waitUntil:"networkidle"});
    await inquiry.waitForSelector("#inquiry-form textarea[data-inquiry-control]", {state:"attached"});
    const mobileDisclosure = inquiry.locator(".mobile-inquiry > summary");
    if (await mobileDisclosure.count()) await mobileDisclosure.click();
    const answer = inquiry.locator("#inquiry-form textarea[data-inquiry-control]").first();
    await answer.fill("Answers resize fixture\n".repeat(8));
    const answerBefore = await answer.evaluate(e => ({height:e.getBoundingClientRect().height,maxHeight:getComputedStyle(e).maxHeight,resize:getComputedStyle(e).resize,fields:e.closest(".inquiry-fields").getBoundingClientRect().toJSON(),dock:e.closest(".agent-dock").getBoundingClientRect().toJSON()}));
    const feedback = inquiry.locator("#inquiry-feedback");
    await feedback.fill("Feedback resize fixture\n".repeat(5));
    const feedbackBefore = await feedback.evaluate(e => ({height:e.getBoundingClientRect().height,maxHeight:getComputedStyle(e).maxHeight,resize:getComputedStyle(e).resize}));
    if (captureDir) await inquiry.screenshot({path:path.join(captureDir,`before-answers-${layout.name}.png`)});
    await inquiry.locator("[data-toggle-inquiry-full-screen]").click();
    const answerExpanded = await answer.evaluate(e => ({height:e.getBoundingClientRect().height,maxHeight:getComputedStyle(e).maxHeight,resize:getComputedStyle(e).resize,form:e.closest("form").className,fields:e.closest(".inquiry-fields")?.getBoundingClientRect().toJSON(),dock:e.closest(".agent-dock")?.getBoundingClientRect().toJSON(),submit:e.closest("form").querySelector("button[type=submit]")?.getBoundingClientRect().toJSON()}));
    const feedbackExpanded = await feedback.evaluate(e => ({height:e.getBoundingClientRect().height,maxHeight:getComputedStyle(e).maxHeight,resize:getComputedStyle(e).resize,fields:e.closest(".inquiry-fields").getBoundingClientRect().toJSON()}));
    if (captureDir) await inquiry.screenshot({path:path.join(captureDir,`after-answers-${layout.name}.png`)});
    const answerDrag = await dragToStableMaximum(inquiry, answer, `${layout.name} main Answers textarea`, 30);
    await assertSubmitReachable(inquiry, "#inquiry-form button[type=submit]", `${layout.name} main Answers`);
    const answerAfter = await answer.evaluate(e => ({height:e.getBoundingClientRect().height,maxHeight:getComputedStyle(e).maxHeight,form:e.closest("form").className,fields:e.closest(".inquiry-fields")?.getBoundingClientRect().toJSON(),dock:e.closest(".agent-dock")?.getBoundingClientRect().toJSON(),submit:e.closest("form").querySelector("button[type=submit]")?.getBoundingClientRect().toJSON()}));
    const feedbackDrag = await dragToStableMaximum(inquiry, feedback, `${layout.name} Answers feedback textarea`, 8);
    const feedbackAfter = await feedback.evaluate(e => ({height:e.getBoundingClientRect().height,maxHeight:getComputedStyle(e).maxHeight,fields:e.closest(".inquiry-fields").getBoundingClientRect().toJSON(),submit:e.closest("form").querySelector("button[type=submit]").getBoundingClientRect().toJSON()}));
    assert.equal(feedbackExpanded.maxHeight,"none",`expanded Answers feedback can use the available panel height: ${JSON.stringify(feedbackExpanded)}`);
    await assertSubmitReachable(inquiry, "#inquiry-form button[type=submit]", `${layout.name} Answers feedback`);
    if (captureDir) await inquiry.screenshot({path:path.join(captureDir,`max-answers-${layout.name}.png`)});
    results.push({layout:layout.name,composer:{before:composerBefore,expanded:composerExpanded,after:composerAfter},answers:{before:answerBefore,expanded:answerExpanded,mainAnswerDrag:answerDrag,after:answerAfter,feedbackBefore,feedbackExpanded,feedbackDrag,feedbackAfter}});
    await context.close();
  }
  if (captureDir) { fs.mkdirSync(captureDir,{recursive:true}); fs.writeFileSync(path.join(captureDir,"card-922-measurements.json"),JSON.stringify(results,null,2)); }
  console.log(JSON.stringify(results));
};
