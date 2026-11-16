const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");

module.exports = async ({ browser, baseUrl, agentKey, captureDir }) => {
  const results = [], failures = [];
  const check = (ok, message, data) => { if (!ok) failures.push(`${message}: ${JSON.stringify(data)}`); };
  const saveFocus = async (request, count) => {
    const current = await (await request.get(`${baseUrl}/agents/${agentKey}/focus`)).json();
    const response = await request.put(`${baseUrl}/agents/${agentKey}/focus`, {data:{revision:current.focus.revision,sections:[{title:"Review work",items:Array.from({length:count},(_,i)=>({title:`Review item ${i+1}`,subtitle:"Keep the header and composer visible. Only the Focus body should scroll."}))}]}});
    assert(response.ok(),await response.text());
  };
  const capture = async (page,name) => { if(captureDir){ fs.mkdirSync(captureDir,{recursive:true}); await page.screenshot({path:path.join(captureDir,`${name}-${browser.browserType().name()}.png`),animations:"disabled"}); } };
  const frames = page => page.evaluate(()=>new Promise(resolve=>requestAnimationFrame(()=>requestAnimationFrame(()=>requestAnimationFrame(resolve)))));
  for(const count of [3,60]) {
    const context=await browser.newContext({viewport:{width:1874,height:891}});
    await saveFocus(context.request,count);
    const page=await context.newPage();
    await page.goto(`${baseUrl}/ui#agent/${agentKey}`,{waitUntil:"networkidle"});
    await page.locator("[data-agent-focus]").waitFor({state:"visible"}); await frames(page);
    const geometry=await page.evaluate(()=>{
      const rect=s=>document.querySelector(s).getBoundingClientRect().toJSON();
      return {viewport:innerHeight,documentHeight:document.documentElement.scrollHeight,documentClient:document.documentElement.clientHeight,bodyHeight:document.body.scrollHeight,nav:rect("#bottom-nav"),header:rect(".app-header"),workspace:rect("[data-agent-workspace]"),pane:rect(".agent-detail-pane"),focus:rect("[data-agent-focus]"),inner:rect(".agent-focus-scroll"),dock:rect("[data-agent-dock]"),strips:document.querySelectorAll("[data-content-panel-heading]").length};
    });
    geometry.count=count;results.push({desktop:geometry});
    await capture(page,`desktop-focus-${count===3?"short":"long"}`);
    check(geometry.nav.width===144 && geometry.strips===2,"match expanded navigation and panel strips",geometry);
    check(geometry.documentHeight<=geometry.documentClient+1 && geometry.bodyHeight<=geometry.viewport+1,"outer document must fit the viewport",geometry);
    check(geometry.focus.bottom<=geometry.viewport+1 && Math.abs(geometry.focus.bottom-geometry.workspace.bottom)<2,"Focus outer container must fill its available height",geometry);
    check(geometry.dock.bottom<=geometry.viewport+1,"composer stays in viewport",geometry);
    const scroll=await page.evaluate(()=>{const inner=document.querySelector(".agent-focus-scroll");inner.scrollTop=300;return {inner:inner.scrollTop,window:scrollY,pane:document.querySelector(".agent-detail-pane").scrollTop,outer:document.querySelector("[data-agent-focus]").scrollTop};});
    if(count===60)check(scroll.inner>0 && scroll.window===0 && scroll.pane===0 && scroll.outer===0,"only Focus body scrolls",scroll);
    if(count===3)check(scroll.inner===0,"short Focus must not need scrolling",scroll);
    if(count===60)await capture(page,"desktop-focus-inner-scroll");
    assert.equal(await page.locator(".side-conversation-close,[data-close-agent-focus]").count(),0);
    // The shared Side Conversation path must give Focus the same inner scroll owner.
    await page.locator('.side-conversation-controls [data-side-conversation="summary"]').click();
    await page.locator('[data-side-workspace]').waitFor();
    await page.locator('.side-conversation-controls [data-side-conversation="summary"]').click();
    await frames(page);
    const shared=await page.evaluate(()=>{
      const outer=document.querySelector('[data-side-kind="focus"]'),inner=outer.querySelector('.agent-focus-scroll');
      inner.scrollTop=300;
      return {page:document.documentElement.scrollHeight,viewport:innerHeight,bottom:outer.getBoundingClientRect().bottom,inner:inner.scrollTop,body:outer.querySelector('.side-conversation-body').scrollTop,window:scrollY};
    });
    check(shared.page<=shared.viewport+1 && shared.bottom<=shared.viewport+1 && shared.body===0 && shared.window===0 && (count===3?shared.inner===0:shared.inner>0),"shared Focus keeps scrolling in its body",shared);
    results.push({sharedFocus:{count,...shared}});
    await context.close();
  }
  for(const [width,height] of [[320,740],[390,844],[844,390]]) {
    const context=await browser.newContext({viewport:{width,height},isMobile:true,hasTouch:true});
    const created=await context.request.post(`${baseUrl}/agents`,{data:{project_key:"web",template_key:"custom",name:"Stop layout fixture",prompt:"QUEUE_SMOKE_HOLD",start:false}});
    assert(created.ok(),await created.text());const key=(await created.json()).agent.key;
    const page=await context.newPage();
    try {
      await page.goto(`${baseUrl}/ui#agent/${key}/summary`,{waitUntil:"networkidle"});
      await page.locator("#prompt-input").fill("Keep this draft through Stop changes.");
      const measure=async stage=>{
        await frames(page);
        const g=await page.evaluate(()=>{const box=e=>e?.getBoundingClientRect().toJSON()||null; const tabs=document.querySelector(".side-conversation-controls"),stop=document.querySelector('[data-agent-floating-actions] [data-agent-action="stop"]');return {width:innerWidth,height:innerHeight,docWidth:document.documentElement.scrollWidth,form:box(document.querySelector("#composer")),dock:box(document.querySelector("[data-agent-dock]")),tabs:box(tabs),tabsWidth:tabs.clientWidth,tabsScrollWidth:tabs.scrollWidth,stop:box(stop)};});
        g.stage=stage;results.push({mobile:g});
        check(g.docWidth<=width+1 && g.form.right<=width+1 && g.form.width<=width,"page and prompt must not overflow horizontally",g);
        if(stage==="running")check(g.stop && Math.abs(g.stop.top-g.tabs.top)<3 && g.stop.right<=width && g.tabs.right<=g.stop.left+1,"tabs and fixed Stop share one constrained row",g);
        assert.equal(await page.locator("#prompt-input").inputValue(),"Keep this draft through Stop changes.");
        return g;
      };
      await measure("idle");
      const started=await context.request.post(`${baseUrl}/agents/${key}/start`,{data:{}});assert(started.ok(),await started.text());
      await page.evaluate(()=>refresh({force:true}));
      await page.locator('[data-agent-floating-actions] [data-agent-action="stop"]').waitFor({state:"visible"});
      const live=(await (await context.request.get(`${baseUrl}/agents/${key}`)).json()).agent;
      assert(live.running && live.pid>0,"fixture must run a real isolated harness process");
      const running=await measure("running"); await capture(page,`mobile-running-stop-${width}`);
      const after=await page.evaluate(()=>{const tabs=document.querySelector(".side-conversation-controls"),stop=document.querySelector('[data-agent-floating-actions] [data-agent-action="stop"]');tabs.scrollLeft=tabs.scrollWidth;const last=tabs.querySelector('[data-side-conversation="pull-requests"]');return {stop:stop.getBoundingClientRect().toJSON(),last:last.getBoundingClientRect().toJSON(),tabs:tabs.getBoundingClientRect().toJSON(),scroll:tabs.scrollLeft};});
      check(after.last.right<=after.tabs.right+1 && after.last.left>=after.tabs.left-1,"last tab can be reached by scrolling tabs",after);
      check(Math.abs(after.stop.left-running.stop.left)<1,"Stop must not move when tabs scroll",after);
      if(width<=390)check(after.scroll>0,"narrow tabs region actually scrolls",after);
      await capture(page,`mobile-running-tabs-end-${width}`);
      const prs=page.locator('.side-conversation-controls [data-side-conversation="pull-requests"]');
      await prs.tap();
      assert.equal(await prs.getAttribute("aria-pressed"),"true");
      await frames(page);
      await prs.focus();await page.keyboard.press("Enter");
      await page.waitForFunction(()=>document.querySelector('.side-conversation-controls [data-side-conversation="pull-requests"]')?.getAttribute("aria-pressed")==="false");
      assert.equal(await prs.getAttribute("aria-pressed"),"false");
      await measure("running");
      await page.locator('[data-agent-floating-actions] [data-agent-action="stop"]').click();
      await page.locator('[data-agent-floating-actions] [data-agent-action="stop"]').waitFor({state:"hidden"});
      const stopped=(await (await context.request.get(`${baseUrl}/agents/${key}`)).json()).agent;
      assert.equal(stopped.running,false,"Stop must end the isolated process");
      const idle=await measure("stopped");
      check(Math.abs(idle.tabs.height-running.tabs.height)<1,"Stop appearance must not wrap the tabs row",{idle,running});
    } finally { await context.request.post(`${baseUrl}/agents/${key}/stop`,{data:{}}); await context.close(); }
  }
  console.log(JSON.stringify({engine:browser.browserType().name(),results,failures},null,2));
  if(captureDir)fs.writeFileSync(path.join(captureDir,`bounds-${browser.browserType().name()}.json`),JSON.stringify({results,failures},null,2));
  assert.deepEqual(failures,[]);
};
