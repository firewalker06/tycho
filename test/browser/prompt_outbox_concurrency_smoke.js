const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");

module.exports = async ({browser, baseUrl, agentKey, captureDir}) => {
  assert.equal(new URL(baseUrl).hostname,"127.0.0.1");
  const source=fs.readFileSync(process.env.TYCHO_REMOTE_UI_PROMPT_OUTBOX_BASELINE || path.join(__dirname,"../../lib/hq/remote_ui/assets/prompt_submissions.js"),"utf8");
  const selected=process.env.TYCHO_REMOTE_UI_PROMPT_CONCURRENCY_CASE;
  const results=[];
  const fixture=`${baseUrl}/outbox-concurrency-fixture`;
  const setup=async page=>{
    await page.route(fixture,route=>route.fulfill({contentType:"text/html",body:`<!doctype html><title>Synthetic outbox concurrency</title><script>${source}</script>`}));
    await page.goto(fixture);
    await page.evaluate(()=>{
      window.sent=[];window.accepted=[];window.cancelled=[];window.errors=[];window.replies={};
      window.destination={agent_key:"agent",server_id:"server"};
      window.make=id=>({id,key:"agent",destination,payload:{prompt:"Equal synthetic text",attachments:[]},encoded:true,files:[],order:Date.now(),status:"uncertain",saved:true});
      window.valid=id=>({accepted:true,queued:false,receipt:{version:1,accepted:true,client_request_id:id,agent_key:"agent",server_id:"server",outcome:"accepted",replayed:false,accepted_at:"2026-11-03T03:00:00Z",revision:"1",running:false,source:"user",authority:null,queue_entry:null}});
      window.store=TychoPromptSubmissions.browserStorage();
      window.createBox=(storage=store)=>new TychoPromptSubmissions.Outbox({storage,
        send:entry=>{sent.push(entry.id);return new Promise((resolve,reject)=>{replies[entry.id]={resolve,reject};});},
        onAccepted:entry=>accepted.push(entry.id),onCancelled:entry=>cancelled.push(entry.id),onError:entry=>errors.push(entry.id)});
    });
  };
  if(!selected || selected==="lane") for(const late of ["success","error","invalid"]) for(const proofFirst of [false,true]) for(const latePhase of ["B","C"]) {
    const context=await browser.newContext(),page=await context.newPage();
    try {
      await setup(page);
      await page.evaluate(async()=>{window.box=createBox();await box.ready;await box.add(make("client-a"));});
      await page.waitForFunction(()=>sent.length===1);
      if(!proofFirst)await page.evaluate(()=>box.add(make("client-b")));
      await page.evaluate(()=>box.reconcile("agent",[valid("client-a")]));
      if(proofFirst)await page.evaluate(()=>box.add(make("client-b")));
      await page.waitForFunction(()=>sent.length===2);
      await page.evaluate(()=>box.add(make("client-c")));
      if(latePhase==="C") {
        await page.evaluate(()=>replies["client-b"].resolve(valid("client-b")));
        await page.waitForFunction(()=>sent.length===3);
        await page.evaluate(()=>box.add(make("client-d")));
      }
      await page.evaluate(late=>{if(late==="error")replies["client-a"].reject(Error("Synthetic late error"));else replies["client-a"].resolve(late==="invalid"?{}:valid("client-a"));},late);
      await page.waitForTimeout(50);
      const expected=latePhase==="B"?["client-a","client-b"]:["client-a","client-b","client-c"];
      assert.deepEqual(await page.evaluate(()=>sent),expected,"late A cannot unlock a newer lane");
      if(latePhase==="B") {
        await page.evaluate(()=>replies["client-b"].resolve(valid("client-b")));
        await page.waitForFunction(()=>sent.length===3);
      }
      await page.evaluate(()=>replies["client-c"].resolve(valid("client-c")));
      if(latePhase==="C") {
        await page.waitForFunction(()=>sent.length===4);
        await page.evaluate(()=>replies["client-d"].resolve(valid("client-d")));
      }
      await page.waitForFunction(()=>box.entries.size===0&&box.lanes.size===0);
      const facts=await page.evaluate(()=>({sent,accepted,errors}));
      assert.deepEqual(facts.accepted,facts.sent);
      assert.deepEqual(facts.errors,[]);
      results.push({case:"proof-releases-owned-lane",late,proofFirst,latePhase,...facts});
    } finally {await context.close();}
  }
  if(!selected || selected==="tabs") for(const cancellationOrder of ["waiting","stale-retry"]) for(const hints of [false,true]) {
    const context=await browser.newContext(),one=await context.newPage(),two=await context.newPage();
    try {
      await setup(one);await setup(two);
      await one.evaluate(async()=>{await store.put({...make("client-a"),order:1});await store.put({...make("client-b"),order:2});window.box=createBox();await box.ready;});
      await two.evaluate(async hints=>{window.box=createBox(hints?store:{...store,subscribe:()=>()=>{}});await box.ready;window.stale=structuredClone(box.entries.get("client-b"));await box.retry("client-a");await box.retry("client-b");},hints);
      await two.waitForFunction(()=>sent.length===1);
      await one.evaluate(()=>box.cancel("client-b"));
      if(hints)await two.waitForFunction(()=>!box.entries.has("client-b"));
      const put=await two.evaluate(()=>store.put(stale));
      assert.equal(put,false,"atomic put cannot overwrite a saved stop");
      assert.equal(await two.evaluate(()=>store.remove("client-b")),false,"late cleanup cannot erase stop authority");
      if(cancellationOrder==="stale-retry")await two.evaluate(async()=>{if(!box.entries.has(stale.id))box.entries.set(stale.id,{...stale,status:"uncertain"});await box.retry(stale.id);});
      await two.evaluate(()=>replies["client-a"].resolve(valid("client-a")));
      await two.waitForFunction(()=>box.entries.size===0&&box.lanes.size===0);
      assert.deepEqual(await two.evaluate(()=>sent),["client-a"],"cancelled B cannot silently dispatch after A");
      await one.reload();
      const recovered=await one.evaluate(async()=>{const box=new TychoPromptSubmissions.Outbox({storage:TychoPromptSubmissions.browserStorage(),send:()=>{throw Error("No reload replay");}});await box.ready;return [...box.entries.keys()];});
      assert(!recovered.includes("client-b"),"reload excludes stopped intent");
      results.push({case:"two-tab-stop",cancellationOrder,hints,stale_put:put,sent:["client-a"]});
    } finally {await context.close();}
  }
  if(!selected) {
    const context=await browser.newContext(),page=await context.newPage();
    try {
      await setup(page);
      await page.evaluate(async()=>{window.box=createBox();await box.add(make("client-a"));});
      await page.waitForFunction(()=>sent.length===1);
      await page.evaluate(async()=>{await box.add(make("client-b"));await box.cancel("client-a");});
      assert.deepEqual(await page.evaluate(()=>sent),["client-a"],"unknown cancelled HTTP still owns its lane");
      await page.evaluate(()=>box.reconcile("agent",[valid("client-a")]));
      await page.waitForFunction(()=>sent.length===2);
      await page.evaluate(()=>replies["client-a"].resolve({}));
      await page.waitForTimeout(30);
      assert.equal(await page.evaluate(()=>box.lanes.get("agent").entry.id),"client-b");
      await page.evaluate(()=>replies["client-b"].resolve(valid("client-b")));
      await page.waitForFunction(()=>box.entries.size===0&&box.lanes.size===0);
      assert.deepEqual(await page.evaluate(()=>accepted),["client-b"],"proof does not apply cancelled composer effects");
      assert.equal(await page.evaluate(()=>store.put(make("client-a"))),false,"late proof cleanup keeps stop fence");
      results.push({case:"cancel-inflight-then-proof",late:"invalid",accepted:["client-b"]});
    } finally {await context.close();}
  }
  // Both explicit transaction orders, followed by concurrent attempts. No hints
  // are needed: the read/write transaction is the dispatch/cancel authority.
  if(!selected) for(const order of ["cancel-first","dispatch-first","race"]) {
    const context=await browser.newContext(),one=await context.newPage(),two=await context.newPage();
    try {
      await setup(one);await setup(two);
      const iterations=order==="race"?20:1;
      for(let i=0;i<iterations;i++) {
        const id=`client-race-${i}`;
        await one.evaluate(id=>store.put(make(id)),id);
        const start=()=>two.evaluate(async id=>{const result=await store.start(id,()=>{sent.push(id);return Promise.resolve({data:valid(id)});});return result.started;},id);
        const cancel=()=>one.evaluate(id=>store.cancel(id),id);
        let started;
        if(order==="cancel-first"){await cancel();started=await start();assert.equal(started,false);}
        else if(order==="dispatch-first"){started=await start();await cancel();assert.equal(started,true);}
        else {[started]=await Promise.all([start(),cancel()]);}
        const later=await start();assert.equal(later,false,"no request can start after the saved stop");
        assert.equal(await two.evaluate(id=>store.put(make(id)),id),false);
        results.push({case:"cancel-dispatch-transaction",order,iteration:i,started,later});
      }
    } finally {await context.close();}
  }
  // Cancellation while attachment preparation is held must prevent dispatch.
  if(!selected) {
    const context=await browser.newContext(),one=await context.newPage(),two=await context.newPage();
    try {
      await setup(one);await setup(two);
      await one.evaluate(()=>store.put(make("client-preparing")));
      await two.evaluate(async()=>{window.releasePrepare=null;window.box=new TychoPromptSubmissions.Outbox({storage:store,prepare:()=>new Promise(resolve=>{releasePrepare=resolve;}),send:()=>{sent.push("unsafe");}});await box.ready;await box.retry("client-preparing");});
      await two.waitForFunction(()=>Boolean(releasePrepare));
      await one.evaluate(()=>store.cancel("client-preparing"));
      await two.evaluate(()=>releasePrepare());
      await two.waitForFunction(()=>box.entries.size===0&&box.lanes.size===0);
      assert.deepEqual(await two.evaluate(()=>sent),[]);
      results.push({case:"cancel-during-preparation",sent:[]});
    } finally {await context.close();}
  }
  // Real UI controllers in two tabs share the corrected store. A cross-tab
  // stop must leave the second tab's newer composer input and file intact.
  if(!selected) for(const width of [1440,390]) for(const theme of ["dark","light"]) {
    const context=await browser.newContext({viewport:{width,height:900},isMobile:width<500,hasTouch:width<500});
    const one=await context.newPage(),two=await context.newPage();
    try {
      const created=await context.request.post(`${baseUrl}/agents`,{data:{project_key:"web",name:"Cross-tab retry",prompt:"QUEUE_SMOKE_HOLD",start:true}});
      assert.equal(created.status(),201);const agent=(await created.json()).agent,key=agent.key;
      await context.addInitScript(theme=>localStorage.setItem("hq.remote.appearance",theme),theme);
      let writes=0;
      await context.route(new RegExp(`/agents/${key}/messages$`),async route=>{writes++;return route.fulfill({status:401,json:{error:"Synthetic auth loss"}});});
      for(const page of [one,two]){await page.goto(`${baseUrl}/ui#agent/${encodeURIComponent(key)}`,{waitUntil:"networkidle"});await page.waitForSelector("#composer");}
      await one.locator("#prompt-input").fill("Unproven cross-tab intent");
      await one.locator("#composer").evaluate(form=>form.requestSubmit());
      await one.locator("[data-retry-prompt]").waitFor();
      await one.evaluate(()=>document.querySelector("#auth-panel").classList.add("hidden"));
      await two.reload({waitUntil:"networkidle"});await two.locator("[data-retry-prompt]").waitFor();
      await two.locator("#prompt-input").fill("Keep this newer draft");
      await two.locator("[data-prompt-attachment-input]").setInputFiles({name:"keep.txt",mimeType:"text/plain",buffer:Buffer.from("Synthetic newer file")});
      await one.locator("[data-cancel-prompt]").focus();await one.locator("[data-cancel-prompt]").press("Enter");
      await two.waitForFunction(()=>state.promptOutbox.entries.size===0);
      assert.equal(await two.locator("[data-retry-prompt]").count(),0);
      assert.equal(await two.locator("#prompt-input").inputValue(),"Keep this newer draft");
      assert.equal(await two.evaluate(key=>pendingAttachmentsFor(key).length,key),1);
      assert.equal(writes,1);
      if(captureDir)await two.screenshot({path:path.join(captureDir,`cross-tab-${width}-${theme}.png`)});
      await two.reload({waitUntil:"networkidle"});await two.waitForSelector("#composer");
      assert.equal(await two.locator("[data-retry-prompt]").count(),0);
      results.push({case:"two-tab-ui",width,theme,writes,newer_draft_and_file_preserved:true});
    } finally {await context.close();}
  }
  if(captureDir)fs.writeFileSync(path.join(captureDir,"prompt-outbox-concurrency.json"),JSON.stringify(results,null,2));
  console.log(JSON.stringify(results,null,2));
  console.log("prompt_outbox_concurrency_smoke: ok");
};
