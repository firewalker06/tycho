const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");

const KEY = "web-inquiry-recovery-2";
const ATTACHMENT_ID = "review333-padding-preview";
const MESSAGES = {
  short: "Which synthetic option?",
  long: "Please read this inquiry before you choose an answer. ".repeat(12),
};
const LAYOUTS = [
  {name:"desktop-split", width:1920, height:1080, split:true},
  {name:"desktop-no-split", width:1000, height:900},
  {name:"mobile", width:390, height:844, mobile:true},
];

async function prepareSummaryPreview(page) {
  await page.evaluate(() => {
    const workspace = document.querySelector(".agent-workspace");
    const form = document.querySelector("#inquiry-form");
    if (!workspace || !form) throw new Error("summary workspace and inquiry form must be present");
    workspace.classList.add("has-attachment-preview");
    const preview = document.createElement("aside");
    preview.className = "summary-attachment-preview-pane";
    preview.setAttribute("aria-label", "Synthetic attachment preview");
    workspace.append(preview);
    form.classList.remove("inquiry-form-full-screen");
    form.classList.add("inquiry-form-full-height");
  });
  const layoutState = await page.evaluate(() => ({classes:document.querySelector(".agent-workspace")?.className,form:document.querySelector("#inquiry-form")?.className,preview:document.querySelector(".summary-attachment-preview-pane")?.getClientRects().length}));
  assert.match(layoutState.classes || "", /has-attachment-preview/, `synthetic attachment preview did not activate split layout: ${JSON.stringify(layoutState)}`);
  assert.match(layoutState.form || "", /inquiry-form-full-height/, `full-height inquiry form did not render: ${JSON.stringify(layoutState)}`);
  assert(layoutState.preview, "split layout preview pane must be visible");
}

async function setMessage(page, message) {
  await page.evaluate(({key,message}) => {
    const agent = findAgent(key);
    agent.latest_inquiry.message = message;
    if (state.agentDetails[key]?.latest_inquiry) state.agentDetails[key].latest_inquiry.message = message;
    render();
  }, {key:KEY,message});
}

async function focusByKeyboard(page, button) {
  await button.focus();
  await page.keyboard.press("Shift+Tab");
  await page.keyboard.press("Tab");
  assert(await button.evaluate(element => element === document.activeElement), "keyboard focus must return to the inquiry expansion button");
}

async function measureRing(page) {
  return page.evaluate(() => {
    const button = document.querySelector("[data-toggle-inquiry-full-screen]");
    const card = button.closest("summary") || document.querySelector(".inquiry-banner");
    const buttonBox = button.getBoundingClientRect();
    const cardBox = card.getBoundingClientRect();
    const buttonStyle = getComputedStyle(button);
    const cardStyle = getComputedStyle(card);
    const ring = parseFloat(buttonStyle.outlineWidth) + parseFloat(buttonStyle.outlineOffset);
    const border = {
      top:parseFloat(cardStyle.borderTopWidth),
      right:parseFloat(cardStyle.borderRightWidth),
      bottom:parseFloat(cardStyle.borderBottomWidth),
      left:parseFloat(cardStyle.borderLeftWidth),
    };
    return {
      label:button.getAttribute("aria-label"),
      focusVisible:button.matches(":focus-visible"),
      outline:{style:buttonStyle.outlineStyle,width:buttonStyle.outlineWidth,offset:buttonStyle.outlineOffset},
      button:{top:buttonBox.top,right:buttonBox.right,bottom:buttonBox.bottom,left:buttonBox.left,width:buttonBox.width,height:buttonBox.height},
      card:{top:cardBox.top,right:cardBox.right,bottom:cardBox.bottom,left:cardBox.left,width:cardBox.width,height:cardBox.height},
      ringGap:{
        top:buttonBox.top-ring-cardBox.top-border.top,
        right:cardBox.right-border.right-buttonBox.right-ring,
        bottom:cardBox.bottom-border.bottom-buttonBox.bottom-ring,
        left:buttonBox.left-ring-cardBox.left-border.left,
      },
    };
  });
}

async function captureCard(page, filePath) {
  const selector = await page.locator(".mobile-inquiry > summary").count()
    ? page.locator(".mobile-inquiry > summary")
    : page.locator(".inquiry-banner");
  const box = await selector.boundingBox();
  const inset = 8;
  await page.screenshot({
    path:filePath,
    clip:{x:Math.max(0,box.x-inset),y:Math.max(0,box.y-inset),width:box.width+inset*2,height:box.height+inset*2},
  });
}

function assertRingClearance(result, label) {
  assert.equal(result.focusVisible, true, `${label} focus ring must be visible`);
  assert.equal(result.outline.style, "solid", `${label} must use a visible outline`);
  for (const [side, gap] of Object.entries(result.ringGap)) {
    assert(gap >= 2, `${label} focus ring needs 2px ${side} clearance; measured ${gap}px`);
  }
}

module.exports = async ({browser, baseUrl, captureDir}) => {
  const apiContext = await browser.newContext();
  const response = await apiContext.request.get(`${baseUrl}/agents/${KEY}`);
  const data = await response.json();
  await apiContext.close();
  assert(data.agent?.latest_inquiry, "fixture must have an inquiry");
  if (captureDir) fs.mkdirSync(captureDir, {recursive:true});
  const results = [];

  for (const layout of LAYOUTS) {
    for (const [messageName, message] of Object.entries(MESSAGES)) {
      const context = await browser.newContext({viewport:{width:layout.width,height:layout.height},isMobile:!!layout.mobile,hasTouch:!!layout.mobile});
      const page = await context.newPage();
      page.setDefaultTimeout(12000);
      try {
        await page.route(new RegExp(`/agents/${KEY}/inquiries/[^/]+/answer$`), route => route.fulfill({status:503,contentType:"application/json",body:JSON.stringify({error:"Synthetic failed answer"})}));
        await page.goto(`${baseUrl}/ui#agent/${KEY}/summary/review333`, {waitUntil:"networkidle"});
        await page.waitForSelector("#inquiry-form", {state:"attached"});
        await setMessage(page, message);
        if (layout.split) {
          await prepareSummaryPreview(page);
        } else if (layout.mobile) {
          await page.locator(".mobile-inquiry > summary").click();
        }

        const button = page.locator("[data-toggle-inquiry-full-screen]").first();
        await focusByKeyboard(page, button);
        const measurement = await measureRing(page);
        if (layout.split) assert.equal(await page.locator(".agent-workspace.has-attachment-preview").count(), 1, "desktop split must show an attachment preview");
        assertRingClearance(measurement, `${layout.name}/${messageName}`);
        results.push({layout:layout.name,message:messageName,measurement});
        if (captureDir) await captureCard(page, path.join(captureDir, `${layout.name}-${messageName}-after.png`));

        if (messageName === "short") {
          const form = page.locator("#inquiry-form");
          await form.locator('input[type="text"]').fill("One-line synthetic answer");
          await form.locator("button[type=submit]").click();
          await page.waitForSelector("[data-inquiry-answer-recovery]");
          await page.reload({waitUntil:"networkidle"});
          await page.waitForSelector("[data-inquiry-answer-recovery]", {state:"attached"});
          if (layout.split) await prepareSummaryPreview(page);
          if (layout.mobile && !await form.isVisible()) await page.locator(".mobile-inquiry > summary").click();
          assert.equal(await form.locator("[data-retry-inquiry-answer]").count(), 1, "failed form has Retry");
          assert.equal(await form.locator("[data-cancel-inquiry-answer]").count(), 1, "failed form has Remove");
          await focusByKeyboard(page, button);
          const failedMeasurement = await measureRing(page);
          assertRingClearance(failedMeasurement, `${layout.name}/short/failed-answer`);
          if (captureDir) await captureCard(page, path.join(captureDir, `${layout.name}-short-failed-after.png`));
        }
      } finally {
        await context.close();
      }
    }
  }
  if (captureDir) fs.writeFileSync(path.join(captureDir, "inquiry-card-padding.json"), JSON.stringify(results,null,2));
  console.log(JSON.stringify(results));
};
