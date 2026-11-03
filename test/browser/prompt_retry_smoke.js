const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");

module.exports = async ({browser, baseUrl, captureDir}) => {
  assert.equal(new URL(baseUrl).hostname,"127.0.0.1");
  const evidence=[];
  const baseline=process.env.TYCHO_REMOTE_UI_PROMPT_RETRY_BASELINE;
  const gate=()=>{let release;const promise=new Promise(resolve=>{release=resolve;});return {promise,release};};
  for(const width of (baseline?[390]:[1440,390])) for(const theme of (baseline?["dark"]:["dark","light"])) for(const peer of (baseline?[false]:[false,true])) for(const delivery of (baseline?["queued"]:["queued","immediate"])) {
    const context=await browser.newContext({viewport:{width,height:900},isMobile:width<500,hasTouch:width<500});
    const page=await context.newPage();page.setDefaultTimeout(12000);
    let late=gate();const errors=[];page.on("pageerror",e=>errors.push(e.message));
    let writes=0,mode="lost", readFailure=false, captured, allowProof=false, baselineServed=false;
    const created=await context.request.post(`${baseUrl}/agents`,{data:{project_key:"web",name:"Retry fixture",prompt:delivery==="queued"?"QUEUE_SMOKE_HOLD":"Synthetic idle",start:delivery==="queued"}});
    assert.equal(created.status(),201);
    const agent=(await created.json()).agent, raw=agent.key, key=peer?`fixture-peer/${raw}`:raw;
    console.log(`Retry case: ${width} ${theme} ${peer?"peer":"local"} ${delivery}`);
    try {
      await page.addInitScript(value=>localStorage.setItem("hq.remote.appearance",value),theme);
      await page.route("**/*",async route=>{
        const request=route.request(),url=new URL(request.url());
        if(baseline && url.pathname==="/ui.js"){baselineServed=true;return route.fulfill({contentType:"application/javascript",body:fs.readFileSync(baseline,"utf8")});}
        const routed=url.pathname.startsWith("/servers/fixture-peer/");
        const pathname=routed?url.pathname.replace("/servers/fixture-peer",""):url.pathname;
        const fetchRoute=()=>route.fetch(routed?{url:`${baseUrl}${pathname}${url.search}`} : {});
        if(url.pathname==="/servers/resources" && peer){
          const response=await route.fetch(),data=await response.json(),local=data.servers.find(s=>s.local);
          data.servers.push({...local,key:"fixture-peer",name:"Synthetic peer",local:false,url:baseUrl});
          return route.fulfill({response,json:data});
        }
        if(pathname===`/agents/${raw}` && request.method()==="GET"){
          if(readFailure)return route.fulfill({status:503,json:{error:"Synthetic read failure"}});
          const response=await fetchRoute(),data=await response.json();
          if(!allowProof) delete data.agent.prompt_acceptances;
          return route.fulfill({response,json:data});
        }
        if(pathname===`/agents/${raw}/messages`){
          writes++;assert.equal(routed,peer);captured=request.postDataJSON();
          assert.equal(captured.expected_server_id,agent.delegation.server_id);
          if(mode==="auth")return route.fulfill({status:401,json:{error:"Synthetic auth error"}});
          if(mode==="unbound")return route.fulfill({status:409,json:{error:"Synthetic unbound conflict"}});
          const response=await fetchRoute();assert([200,202].includes(response.status()));
          if(mode==="lost")return route.abort("connectionreset");
          if(mode==="malformed")return route.fulfill({status:200,body:"invalid",contentType:"application/json"});
          if(mode==="held")await late.promise;
          return route.fulfill({response});
        }
        if(routed)return route.fulfill({response:await fetchRoute()});
        return route.continue();
      });
      await page.goto(`${baseUrl}/ui#agent/${encodeURIComponent(key)}`,{waitUntil:"networkidle"});
      await page.waitForSelector("#composer");
      if(baseline)assert(baselineServed,"pinned baseline bundle was served");
      await page.evaluate(()=>clearTimeout(state.timer));
      const send=async text=>{
        if(!await page.locator("#prompt-input").isVisible())await page.locator("details.focused-composer > summary").click();
        await page.locator("#prompt-input").fill(text);
        await page.locator("#composer").evaluate(form=>form.requestSubmit());
      };
      const refresh=()=>page.evaluate(key=>ensureAgentDetail(key,true),key);
      await send("Same synthetic message");
      await page.locator("[data-retry-prompt]").waitFor();
      const firstId=captured.client_request_id;
      const accepted=await (await context.request.get(`${baseUrl}/agents/${raw}`)).json();
      assert.equal(accepted.agent.prompt_acceptances.filter(p=>p.receipt.client_request_id===firstId).length,1,"one durable acceptance");
      assert.equal(accepted.agent.prompt_queue.entries.filter(e=>e.id===firstId).length,delivery==="queued"?1:0,"queued acceptance is distinct from immediate delivery");
      // Consume through the real service so conversation now proves original delivery.
      if(delivery==="queued"){
        const read=await context.request.post(`${baseUrl}/agents/${raw}/prompt-queue/read`,{data:{}});
        assert.equal(read.status(),200);
      }
      const conversation=await (await context.request.get(`${baseUrl}/agents/${raw}/conversation`)).json();
      assert(JSON.stringify(conversation).includes(firstId),"delivered queue identity is in conversation");
      await page.locator("#prompt-input").fill("Keep newer draft");
      readFailure=true;await refresh().catch(()=>{});
      assert.equal(await page.locator("[data-retry-prompt]").count(),1,"read failure keeps uncertainty");
      readFailure=false;allowProof=true;
      await refresh();
      await page.waitForFunction(()=>state.promptOutbox.entries.size===0);
      assert.equal(writes,1,"proof uses no replay POST");
      assert.equal(await page.locator("[data-retry-prompt]").count(),0,"delivered message leaves retry UI");
      assert.equal(await page.locator("#prompt-input").inputValue(),"Keep newer draft");
      await page.evaluate(async()=>{await refresh({force:true,forceConversation:true});});
      assert.equal(await page.locator("article.message.pending[aria-busy=true]").count(),0,"proof clears unsent state before loading newer conversation");
      if(await page.locator("[data-load-pending-conversation]").count()) {
        await page.locator("[data-load-pending-conversation]").first().click();
        await page.waitForFunction(key=>!pendingConversationUpdate(key),key);
      }
      if(delivery==="immediate")assert.equal(await page.locator("article.message.user").filter({hasText:"Same synthetic message"}).count(),1,"one delivered conversation entry, no local duplicate");
      assert.equal(await page.locator("article.message.pending").count(),0,"no unsent conversation duplicate after proof");
      await page.reload({waitUntil:"networkidle"});
      await page.waitForSelector("#composer");
      assert.equal(await page.locator("[data-retry-prompt]").count(),0,"proof survives reload");
      assert.equal(writes,1);
      // Same content is a second intent. Its malformed response must stay uncertain
      // until the matching proof arrives, regardless of the first delivered message.
      mode="malformed";allowProof=false;
      await send("Same synthetic message");
      await page.locator("[data-retry-prompt]").waitFor();
      const secondId=captured.client_request_id;
      assert.notEqual(firstId,secondId);
      await page.evaluate(async ({key,proof})=>{const agent=findAgent(key);reconcilePromptSubmissions({...agent,prompt_acceptances:[proof]});},{key,proof:accepted.agent.prompt_acceptances.find(p=>p.receipt.client_request_id===firstId)});
      assert.equal(await page.locator("[data-retry-prompt]").count(),1,"same text remains a distinct intent");
      // Exact in-flight retry is cancelled with the keyboard, while a newer draft/file stays.
      mode="held";
      await page.locator("[data-retry-prompt]").click();
      await page.waitForFunction(()=>[...state.promptOutbox.entries.values()][0]?.status==="sending");
      await page.locator("#prompt-input").fill("Preserve newer cancel draft");
      await page.locator("[data-prompt-attachment-input]").setInputFiles({name:"newer.txt",mimeType:"text/plain",buffer:Buffer.from("Synthetic newer file")});
      const cancel=page.locator("[data-cancel-prompt]");await cancel.focus();
      assert.equal(await cancel.getAttribute("type"),"button");
      if(captureDir)await page.screenshot({path:path.join(captureDir,`retry-${width}-${theme}-${peer?"peer":"local"}-${delivery}.png`)});
      await cancel.press("Enter");
      await page.waitForFunction(()=>state.promptOutbox.entries.size===0);
      late.release();
      await page.waitForTimeout(100);
      assert.equal(await page.locator("[data-retry-prompt]").count(),0);
      assert.equal(await page.locator("#prompt-input").inputValue(),"Preserve newer cancel draft");
      assert.equal(await page.evaluate(key=>pendingAttachmentsFor(key).length,key),1);
      const after=await (await context.request.get(`${baseUrl}/agents/${raw}`)).json();
      assert.equal(after.agent.prompt_acceptances.filter(p=>p.receipt.client_request_id===secondId).length,1,"cancel preserves accepted work and exact retry does not duplicate");
      if(delivery==="queued")assert.equal(after.agent.prompt_queue.entries.filter(e=>e.id===secondId).length,1,"server queue is kept");
      await page.evaluate(()=>{location.hash="#settings";});
      await page.waitForTimeout(50);
      await page.evaluate(key=>{location.hash=`#agent/${encodeURIComponent(key)}`;},key);
      await page.waitForSelector("#composer");
      await page.reload({waitUntil:"networkidle"});
      await page.waitForSelector("#composer");
      assert.equal(await page.locator("[data-cancel-prompt]").count(),0,"cancel stays removed through navigation and reload");
      // A current proof can arrive while the original accepted POST is held.
      // Queue a second local intent behind it, then cancel only that waiting intent.
      late=gate();mode="held";allowProof=false;
      const beforeHeld=writes;
      await send("Held accepted response");
      await page.waitForFunction(()=>[...state.promptOutbox.entries.values()][0]?.status==="sending");
      await send("Waiting distinct message");
      await page.waitForFunction(()=>state.promptOutbox.entries.size===2);
      const waitingId=await page.evaluate(()=>[...state.promptOutbox.entries.values()].find(e=>e.status==="waiting").id);
      await page.evaluate(id=>promptSubmissionOutbox().cancel(id),waitingId);
      await page.waitForFunction(()=>state.promptOutbox.entries.size===1);
      allowProof=true;await refresh();
      await page.waitForFunction(()=>state.promptOutbox.entries.size===0);
      assert.equal(writes,beforeHeld+1,"waiting cancellation does not send a new message");
      assert.equal(await page.locator("[data-retry-prompt]").count(),0);
      late.release();
      await page.waitForTimeout(50);
      for(const failure of ["auth","unbound"]){
        mode=failure;await send(`Unproven ${failure}`);
        await page.locator("[data-retry-prompt]").waitFor();
        await page.evaluate(key=>ensureAgentDetail(key,true),key);
        assert.equal(await page.locator("[data-retry-prompt]").count(),1,"no proof means no invented acceptance");
        await page.locator("[data-cancel-prompt]").click();
        await page.waitForFunction(()=>state.promptOutbox.entries.size===0);
        await page.evaluate(()=>document.querySelector("#auth-panel").classList.add("hidden"));
      }
      assert(await page.evaluate(()=>document.documentElement.scrollWidth<=innerWidth+1),"no horizontal overflow");
      assert.deepEqual(errors,[]);
      evidence.push({width,theme,peer,delivery,writes,firstId,secondId,proof_without_replay:true,cancel_kept_server_queue:true});
    } catch(error){
      if(captureDir)await page.screenshot({path:path.join(captureDir,`retry-failure-${width}-${theme}-${peer}-${delivery}.png`)}).catch(()=>{});
      throw error;
    } finally {late.release();await context.close();}
  }
  if(captureDir)fs.writeFileSync(path.join(captureDir,"prompt-retry-browser.json"),JSON.stringify(evidence,null,2));
  console.log(JSON.stringify(evidence,null,2));
};
