const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");

module.exports = async ({browser, baseUrl, captureDir, waitForInquiryRuns}) => {
  assert.equal(new URL(baseUrl).hostname, "127.0.0.1");
  const baseline = process.env.TYCHO_REMOTE_UI_INQUIRY_DISPLAY_BASELINE;
  const evidence = [];
  const gate = () => {let release; const promise = new Promise(resolve => {release=resolve;}); return {promise,release};};
  let index = 48;
  for (const width of (baseline ? [1440] : [1440,390])) for (const theme of (baseline ? ["dark"] : ["dark","light"])) for (const peer of (baseline ? [false] : [false,true])) {
    const rawKey = `web-inquiry-recovery-${index++}`, key = peer ? `fixture-peer/${rawKey}` : rawKey;
    const context = await browser.newContext({viewport:{width,height:900},isMobile:width<500,hasTouch:width<500});
    const page = await context.newPage(); page.setDefaultTimeout(10000);
    const staleGate=gate(), displayGate=gate(), catalogGate=gate();
    let phase="initial", writes=0, detailReads=0, catalogs=0, shellReads=0, responseAt, doneAt, staleReady=false;
    const errors=[];
    page.on("pageerror", error=>errors.push(error.message));
    console.log(`Inquiry display: ${width} ${theme} ${peer?"routed-peer":"local"}`);
    try {
      await page.addInitScript(value=>localStorage.setItem("hq.remote.appearance",value),theme);
      await page.route("**/*", async route => {
        const request=route.request(), url=new URL(request.url());
        if(baseline && url.pathname==="/ui.js") return route.fulfill({status:200,contentType:"application/javascript",body:fs.readFileSync(baseline,"utf8")});
        const routed=url.pathname.startsWith("/servers/fixture-peer/");
        const pathname=routed?url.pathname.replace("/servers/fixture-peer",""):url.pathname;
        // A synthetic broker forwards peer routes to the same isolated HTTP service.
        const fetchRoute=()=>route.fetch(routed?{url:`${baseUrl}${pathname}${url.search}`} : {});
        if(pathname===`/agents/${rawKey}` && request.method()==="GET" && phase!=="initial") {
          detailReads++;
          const staleRead=phase==="stale";
          const response=await fetchRoute();
          if(staleRead) {staleReady=true; await staleGate.promise;}
          else await displayGate.promise;
          return route.fulfill({response});
        }
        if(url.pathname==="/servers/resources") {
          if(phase!=="initial") {catalogs++; await catalogGate.promise;}
          const response=await route.fetch();
          if(!peer) return route.fulfill({response});
          const data=await response.json(), local=data.servers.find(server=>server.local);
          data.servers.push({...local,key:"fixture-peer",name:"Synthetic peer",local:false,url:baseUrl});
          return route.fulfill({response,json:data});
        }
        if(phase!=="initial" && ["/setup","/setup/summary","/schedules"].includes(pathname)) {shellReads++; await displayGate.promise;}
        if(pathname.match(new RegExp(`/agents/${rawKey}/inquiries/[^/]+/answer$`))) {
          assert.equal(routed,peer,"correct local/peer write route"); writes++;
          const response=await fetchRoute(); assert.equal(response.status(),200);
          responseAt=Date.now(); phase="accepted";
          return route.fulfill({response});
        }
        if(routed) return route.fulfill({response:await fetchRoute()});
        return route.continue();
      });
      await page.goto(`${baseUrl}/ui#agent/${encodeURIComponent(key)}`,{waitUntil:"networkidle"});
      await page.waitForSelector("#inquiry-form",{state:"attached"});
      if(!await page.locator("#inquiry-form").isVisible()) await page.locator("details.mobile-inquiry > summary").click();
      await page.locator('#inquiry-form input[type="text"]').fill("Synthetic confirmed answer");
      await page.evaluate(key=>{clearTimeout(state.timer); const original=refresh; globalThis.__displayRefreshes=0;
        refresh=async (...args)=>{globalThis.__displayRefreshes++; return original(...args);};
        },key);
      // Hold the exact pre-answer detail body until acceptance has been applied.
      phase="stale";
      await page.evaluate(key=>{globalThis.__oldDetail=ensureAgentDetail(key,true);},key);
      await page.waitForFunction(()=>Boolean(globalThis.__oldDetail));
      for(let attempt=0; !staleReady && attempt<100; attempt++) await page.waitForTimeout(20);
      assert(staleReady,"pre-answer detail body was captured before POST");
      const answerResponse=page.waitForResponse(response=>response.request().method()==="POST" && response.url().endsWith("/answer"));
      await page.locator('#inquiry-form button[type="submit"]').click();
      await answerResponse;
      await page.waitForFunction(()=>inquiryAnswerStore().entries.size===0);
      doneAt=Date.now();
      const held=await page.evaluate(key=>({inquiry:state.agentDetails[key]?.latest_inquiry?.id || null,
        pending:inquiryAnswerStore().entries.size,refreshes:globalThis.__displayRefreshes}),key);
      const readsWhileHeld=detailReads;
      if(!baseline) {assert.equal(held.inquiry,null,"canonical accepted answer before display reads"); assert.equal(held.refreshes,1); assert.equal(detailReads,1,"only pre-answer read; reconciliation waits on held catalog");}
      catalogGate.release();
      if(!baseline) {
        for(let attempt=0; (detailReads<2 || shellReads<2) && attempt<100; attempt++) await page.waitForTimeout(20);
        assert.equal(detailReads,2,"one reconciliation detail is deliberately held");
        assert.equal(shellReads,2,"setup and schedules are deliberately held");
        assert.equal(await page.locator("[data-inquiry-answer-recovery]").count(),0,"pending ends while detail and shell are held");
      }
      staleGate.release(); await page.evaluate(()=>globalThis.__oldDetail);
      if(!baseline) assert.equal(await page.evaluate(key=>state.agentDetails[key].latest_inquiry,key),null,"stale detail cannot restore A");
      assert(await page.evaluate(()=>document.documentElement.scrollWidth<=innerWidth),"no horizontal viewport overflow");
      if(captureDir) await page.screenshot({path:path.join(captureDir,`display-${width}-${theme}-${peer?"peer":"local"}.png`)});
      phase="reconcile"; displayGate.release();
      await page.waitForFunction(()=>globalThis.__displayRefreshes===1 && !state.refreshInFlight);
      assert.equal(detailReads,baseline?3:2,"exact detail read count includes one deliberate pre-answer stale read");
      assert.equal(catalogs,1,"one catalog pass");
      await page.evaluate(()=>navigate({type:"tab",tab:"agents"}));
      await page.evaluate(key=>navigate({type:"agent",key}),key);
      await page.waitForFunction(key=>!state.agentDetails[key]?.latest_inquiry,key);
      assert.equal(await page.locator("#inquiry-form").count(),0);
      assert.equal(writes,1); assert.deepEqual(errors,[]);
      evidence.push({width,theme,peer,writes,detailReads,catalogs,shellReads,readsWhileHeld,held,pendingAfterResponseMs:doneAt-responseAt});
    } catch(error) {
      if(captureDir) {await page.screenshot({path:path.join(captureDir,"failure.png")}); fs.writeFileSync(path.join(captureDir,"failure.json"),JSON.stringify({url:page.url(),errors,text:await page.locator("body").innerText()},null,2));}
      throw error;
    } finally {staleGate.release();displayGate.release();catalogGate.release();await page.unrouteAll({behavior:"ignoreErrors"});await context.close();}
  }
  if(captureDir) fs.writeFileSync(path.join(captureDir,"inquiry-display.json"),JSON.stringify({synthetic:true,cases:evidence},null,2));
  if(waitForInquiryRuns) console.log(waitForInquiryRuns());
  console.log("inquiry_display_smoke: ok");
};
