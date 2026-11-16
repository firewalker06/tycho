const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");

module.exports = async ({ browser, baseUrl, agentKey, captureDir }) => {
  const engine = browser.browserType().name();
  const setup = await browser.newContext();
  for (const [url, data] of [[`${baseUrl}/agents/${agentKey}`, { name: "Tycho Card Work" }], [`${baseUrl}/projects/web`, { name: "Second Brain" }]]) {
    const response = await setup.request.patch(url, { data });
    assert(response.ok(), `${url}: ${await response.text()}`);
  }
  const focus = await (await setup.request.get(`${baseUrl}/agents/${agentKey}/focus`)).json();
  const saved = await setup.request.put(`${baseUrl}/agents/${agentKey}/focus`, {data:{revision:focus.focus.revision,sections:[{title:"Mobile review",items:Array.from({length:45},(_,i)=>({title:`Review item ${i+1}`,subtitle:"Keep the first heading reachable while reading."}))}]}});
  assert(saved.ok(), await saved.text());
  await setup.close();
  const results = [];
  for (const [width, height, theme] of [[390,844,"dark"],[320,740,"light"]]) {
    const context = await browser.newContext({ viewport: { width, height }, isMobile: true, hasTouch: true, deviceScaleFactor: 2 });
    const page = await context.newPage();
    const errors = [];
    page.on("pageerror", error => errors.push(error.message));
    const frames = () => page.evaluate(() => new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(() => requestAnimationFrame(resolve)))));
    const toggle = kind => page.locator(`.side-conversation-controls [data-side-conversation="${kind}"]`);
    const show = async kind => {
      const visible = await page.locator(`[data-side-kind="${kind}"]`).isVisible();
      if (!visible) {
        if (await toggle(kind).getAttribute("aria-pressed") === "true") await toggle(kind).click();
        await page.waitForFunction(key => document.querySelector(`.side-conversation-controls [data-side-conversation="${key}"]`)?.getAttribute("aria-pressed") === "false", kind);
        await toggle(kind).click();
      }
      await page.locator(`[data-side-kind="${kind}"]`).waitFor({state:"visible"});
      await frames();
    };
    const wrapped = async () => { await page.evaluate(() => setHeaderSubtitle("Paused / Second Brain / Host")); await frames(); };
    const inspect = async (kind, stage) => {
      await frames();
      const geometry = await page.evaluate(({kind,stage}) => {
        const pane = document.querySelector(`[data-side-kind="${kind}"]`);
        const body = pane.querySelector(".side-conversation-body");
        [body,...body.querySelectorAll("*")].forEach(e => { if (e.scrollTop) e.scrollTop=0; });
        window.scrollTo(0,0);
        const selector = {summary:".agent-summary-heading",focus:".agent-focus-panel-heading","pull-requests":".pr-diff-toolbar"}[kind];
        const first = pane.querySelector(selector);
        const rect = e => e.getBoundingClientRect().toJSON();
        const firstRect = rect(first);
        const hit = document.elementFromPoint(firstRect.left+8, firstRect.top+Math.min(10,firstRect.height/2));
        const visibleClose = [...document.querySelectorAll(".side-conversation-close,[data-close-agent-focus],#header-detail-close")].filter(e=>e.getClientRects().length && getComputedStyle(e).display!=="none").length;
        return {kind,stage,header:rect(document.querySelector(".app-header")),first:firstRect,body:rect(body),dock:rect(document.querySelector("[data-agent-dock]")),controls:rect(document.querySelector(".side-conversation-controls")),reserved:parseFloat(getComputedStyle(document.querySelector(".content")).getPropertyValue("--detail-header-height")),scrollTop:body.scrollTop,pageScroll:scrollY,firstReceivesHit:first.contains(hit),visibleClose,viewport:innerHeight,pageWidth:document.documentElement.scrollWidth,viewportWidth:innerWidth,subtitleHeight:document.querySelector(".subtitle-status-text").getBoundingClientRect().height};
      }, {kind,stage});
      results.push(geometry);
      if (captureDir && stage === "initial") {
        fs.mkdirSync(captureDir,{recursive:true});
        await page.screenshot({path:path.join(captureDir,`mobile-top-${engine}-${width}-${kind}.png`),animations:"disabled"});
      }
      assert(geometry.subtitleHeight>25,"fixture must wrap the header metadata");
      assert(geometry.first.top>=geometry.header.bottom,`first content hidden: ${JSON.stringify(geometry)}`);
      assert(geometry.first.bottom<=geometry.dock.top,`first controls clipped by composer: ${JSON.stringify(geometry)}`);
      assert(geometry.firstReceivesHit,`first content must be reachable: ${JSON.stringify(geometry)}`);
      assert(Math.abs(geometry.reserved-geometry.header.height)<1.1,`reserved header height is stale: ${JSON.stringify(geometry)}`);
      assert(geometry.dock.bottom<=geometry.viewport+1 && geometry.controls.top>=geometry.header.bottom,`composer/control clearance: ${JSON.stringify(geometry)}`);
      assert.equal(geometry.visibleClose,0,"mobile panels use grouped toggles, without Close buttons");
      assert(geometry.pageWidth<=geometry.viewportWidth+1,"page must not overflow horizontally");
      assert.equal(await page.locator("#prompt-input").inputValue(),"Keep this mobile review draft.");
    };
    await page.goto(`${baseUrl}/ui#settings`,{waitUntil:"networkidle"});
    await page.locator("[data-appearance-preference]").selectOption(theme);
    await page.goto(`${baseUrl}/ui#agent/${agentKey}/summary`,{waitUntil:"networkidle"});
    // Simulate mobile text size and safe insets; no physical iOS browser chrome is claimed.
    await page.addStyleTag({content:'@media(max-width:899px) { :root { --safe-area-top:47px; } .subtitle-status-text { font-size:16px; } [data-agent-dock] { padding-bottom:34px !important; } }'});
    await page.locator("#prompt-input").fill("Keep this mobile review draft.");
    await page.evaluate(() => {setHeaderSubtitle("Paused / Web / Host");syncDetailHeaderLayout();syncAgentDockLayout();window.scrollTo(0,0);});
    await frames();
    await wrapped();
    for (const kind of ["summary","focus","pull-requests"]) {
      await show(kind); await wrapped(); await inspect(kind,"initial");
      const scrolled = await page.locator(`[data-side-kind="${kind}"] .side-conversation-body`).evaluate(body => {
        const scroll = [body,...body.querySelectorAll("*")].find(e=>/auto|scroll/.test(getComputedStyle(e).overflowY) && e.scrollHeight>e.clientHeight+50);
        if (!scroll) return null;
        scroll.scrollTop=160;return scroll.scrollTop;
      });
      if (kind!=="pull-requests") assert(scrolled>0,`${kind} fixture must really scroll`);
      await inspect(kind,"return-to-top");
      await page.evaluate(() => refresh({force:true})); await wrapped(); await inspect(kind,"polling");
      await page.evaluate(() => {document.querySelector(".subtitle-status-text").style.fontSize="18px";});
      await inspect(kind,"font-change");
      await page.evaluate(() => document.documentElement.style.setProperty("--safe-area-top","59px"));
      await inspect(kind,"inset-change");
      await page.setViewportSize({width:width===390?320:390,height}); await wrapped(); await inspect(kind,"resize");
      await page.setViewportSize({width,height});
      await page.evaluate(() => {document.documentElement.style.setProperty("--safe-area-top","47px");navigate({type:"tab",tab:"settings"});});
      await page.locator("[data-appearance-preference]").waitFor();
      await page.evaluate(key=>navigate({type:"agentSummary",key}),agentKey);
      await page.locator("[data-side-workspace]").waitFor();
      await show(kind); await wrapped(); await inspect(kind,"navigation");
    }
    await page.setViewportSize({width:1440,height:900}); await frames();
    assert.equal(await page.locator(".side-conversation-close,[data-close-agent-focus]").count(),0,"panel toggles replace Close controls on desktop too");
    await page.setViewportSize({width,height}); await wrapped(); await inspect("pull-requests","return-to-mobile");
    for (const kind of ["summary","focus","pull-requests"]) if (await toggle(kind).getAttribute("aria-pressed")==="true") await toggle(kind).click();
    await page.locator("#prompt-input").waitFor({state:"visible"});
    await toggle("summary").click(); await wrapped(); await inspect("summary","reopen");
    assert.deepEqual(errors,[]);
    await context.close();
  }
  if(captureDir) fs.writeFileSync(path.join(captureDir,`mobile-top-${engine}-geometry.json`),JSON.stringify({engine,version:browser.version(),results},null,2));
  console.log(JSON.stringify({engine,version:browser.version(),checks:results.length,summary:results[0]}));
};
