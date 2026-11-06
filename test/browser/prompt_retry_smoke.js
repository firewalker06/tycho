const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");

module.exports = async ({browser, baseUrl, captureDir}) => {
  assert.equal(new URL(baseUrl).hostname,"127.0.0.1");
  const evidence=[];
  const baseline=process.env.TYCHO_REMOTE_UI_PROMPT_RETRY_BASELINE;
  const gate=()=>{let release;const promise=new Promise(resolve=>{release=resolve;});return {promise,release};};
  const repeats=Number(process.env.TYCHO_REMOTE_UI_PROMPT_RETRY_REPEATS||1);
  assert(Number.isInteger(repeats)&&repeats>=1&&repeats<=20);
  for(let repeat=0;repeat<repeats;repeat++) for(const width of (baseline?[390]:[1440,390])) for(const theme of (baseline?["dark"]:["dark","light"])) for(const peer of (baseline?[false]:[false,true])) for(const delivery of (baseline?["queued"]:["queued","immediate"])) {
    const selected=process.env.TYCHO_REMOTE_UI_PROMPT_RETRY_CASE;
    if(selected && selected!==`${width}:${theme}:${peer?"peer":"local"}:${delivery}`) continue;
    const context=await browser.newContext({viewport:{width,height:900},isMobile:width<500,hasTouch:width<500});
    const page=await context.newPage();page.setDefaultTimeout(12000);
    let late=gate();const errors=[];page.on("pageerror",e=>errors.push(e.message));
    let writes=0,mode="held", readFailure=false, captured, allowProof=false, baselineServed=false;
    const trace=[];
    const acceptedGates=new Map();
    const acceptanceFor=id=>{if(!acceptedGates.has(id))acceptedGates.set(id,gate());return acceptedGates.get(id);};
    const note=(event,fields={})=>trace.push({event,elapsed_ms:Date.now(),...fields});
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
          note("detail",{allowProof,proof_ids:(data.agent.prompt_acceptances||[]).map(p=>p.receipt?.client_request_id),revision:data.agent.revision});
          if(!allowProof) delete data.agent.prompt_acceptances;
          return route.fulfill({response,json:data});
        }
        if(pathname===`/agents/${raw}/messages`){
          writes++;assert.equal(routed,peer);captured=request.postDataJSON();
          await page.evaluate(() => {window.__retryPostStarted=true;});
          note("post-start",{id:captured.client_request_id,mode});
          assert.equal(captured.expected_server_id,agent.delegation.server_id);
          if(mode==="auth")return route.fulfill({status:401,json:{error:"Synthetic auth error"}});
          if(mode==="unbound")return route.fulfill({status:409,json:{error:"Synthetic unbound conflict"}});
          const response=await fetchRoute();assert([200,202].includes(response.status()));
          note("post-accepted",{id:request.postDataJSON().client_request_id,mode,status:response.status()});
          acceptanceFor(request.postDataJSON().client_request_id).release();
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
      if(delivery==="queued") await page.waitForFunction(key=>findAgent(key)?.running===true,key);
      const send=async text=>{
        await page.evaluate(()=>{
          if(globalThis.__retryEvents) return;
          globalThis.__retryEvents=[];
          const original=showGrowl;
          showGrowl=(message,...args)=>{__retryEvents.push({event:"growl",message});return original(message,...args);};
          document.addEventListener("submit",event=>{if(event.target.id==="composer")__retryEvents.push({event:"submit",submitting:event.target.dataset.submitting});},true);
        });
        if(!await page.locator("#prompt-input").isVisible())await page.locator("details.focused-composer > summary").click();
        await page.locator("#prompt-input").fill(text);
        await page.locator("#composer").evaluate(form=>{
          __retryEvents.push({event:"request-submit",connected:form.isConnected,valid:form.checkValidity(),invalid_fields:[...form.elements].filter(field=>field.validity&&!field.validity.valid).map(field=>({name:field.name,type:field.type}))});
          form.requestSubmit();
        });
      };
      const refresh=()=>page.evaluate(key=>ensureAgentDetail(key,true),key);
      await send("Same synthetic message");
      await page.waitForFunction(() => [...state.promptOutbox.entries.values()][0]?.status === "sending");
      await page.waitForFunction(() => window.__retryPostStarted === true);
      const firstId=captured.client_request_id;
      assert.equal(await page.locator("[data-composer-submission-error]").count(),0,"a normal send has no composer recovery panel");
      if(delivery==="queued"){
        const summary=page.locator("details[data-prompt-queue] > summary");
        await summary.filter({hasText:/queueing/i}).waitFor();
        await summary.click();
        await page.locator(".prompt-queue-entry-meta").filter({hasText:/Queueing/}).last().waitFor();
      }else{
        await page.locator(".message-send-status").filter({hasText:"Sending"}).waitFor();
      }
      await acceptanceFor(firstId).promise;
      const accepted=await (await context.request.get(`${baseUrl}/agents/${raw}`)).json();
      assert.equal(accepted.agent.prompt_acceptances.filter(p=>p.receipt.client_request_id===firstId).length,1,"one durable acceptance");
      assert.equal(accepted.agent.prompt_queue.entries.filter(e=>e.id===firstId).length,delivery==="queued"?1:0,"queued acceptance is distinct from immediate delivery");
      const timingCapture = captureDir && repeat === 0 && theme === "dark" && !peer && delivery === "immediate";
      const timedFrames = [];
      if (timingCapture) {
        const started = Date.now();
        for (const target of [0, 100, 300, 600, 1000, 2000]) {
          if (target) await page.waitForTimeout(Math.max(0, target - (Date.now() - started)));
          const image = await page.screenshot({path:path.join(captureDir,`prompt-send-${width}-${target}ms.png`)});
          timedFrames.push({label:`${target} ms`, image:image.toString("base64")});
        }
        await page.waitForTimeout(Math.max(0, 2500 - (Date.now() - started)));
      }
      allowProof=true;
      await refresh();
      await page.waitForFunction(()=>state.promptOutbox.entries.size===0);
      late.release();
      if (timingCapture) {
        await page.waitForFunction(()=>!document.querySelector("[data-composer-submission-error]") && document.querySelector(".message-send-status")?.textContent.includes("Sent"));
        const image = await page.screenshot({path:path.join(captureDir,`prompt-send-${width}-after-response.png`)});
        timedFrames.push({label:"After response (2.5 s hold)", image:image.toString("base64")});
        const sheet = await context.newPage();
        await sheet.setViewportSize({width:Math.max(390,width),height:1000});
        const columns = width < 500 ? 1 : 2;
        await sheet.setContent(`<meta name="viewport" content="width=device-width,initial-scale=1"><style>body{margin:0;padding:12px;font:13px system-ui;background:#f3f4f6;color:#111}.grid{display:grid;grid-template-columns:repeat(${columns},minmax(0,1fr));gap:12px}.frame{min-width:0}.frame strong{display:block;padding:5px 2px}.frame img{display:block;width:100%;height:auto;border:1px solid #ccd0d5;border-radius:4px}</style><main class="grid">${timedFrames.map(frame=>`<section class="frame"><strong>${frame.label}</strong><img src="data:image/png;base64,${frame.image}"></section>`).join("")}</main>`);
        await sheet.screenshot({path:path.join(captureDir,`prompt-send-${width}-contact-sheet.png`),fullPage:true});
        await sheet.close();
      }
      // Consume through the real service so conversation now proves original delivery.
      if(delivery==="queued"){
        const read=await context.request.post(`${baseUrl}/agents/${raw}/prompt-queue/read`,{data:{}});
        assert.equal(read.status(),200);
      }
      const conversation=await (await context.request.get(`${baseUrl}/agents/${raw}/conversation`)).json();
      assert(JSON.stringify(conversation).includes(firstId),"delivered queue identity is in conversation");
      await page.locator("#prompt-input").fill("Keep newer draft");
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
      if(delivery==="queued"){
        const queue=page.locator("details[data-prompt-queue]");
        const summary=queue.locator(":scope > summary");
        await summary.filter({hasText:/not confirmed/i}).waitFor();
        if(!await queue.evaluate(element=>element.open)) await summary.click();
        await page.locator(".prompt-queue-entry-meta").filter({hasText:/Not confirmed/i}).last().waitFor();
      }
      const secondId=captured.client_request_id;
      assert.notEqual(firstId,secondId);
      assert.equal(await page.locator("[data-composer-submission-error][data-state=failed]").count(),1,"an uncertain send has one recovery notice");
      assert.equal(await page.locator("[data-retry-prompt]").count(),1,"an uncertain send can retry");
      assert.equal(await page.locator("[data-cancel-prompt]").count(),1,"an uncertain send can be cancelled");
      readFailure=true;await refresh().catch(()=>{});
      assert.equal(await page.locator("[data-retry-prompt]").count(),1,"read failure keeps uncertainty");
      readFailure=false;
      await page.evaluate(async ({key,proof})=>{const agent=findAgent(key);reconcilePromptSubmissions({...agent,prompt_acceptances:[proof]});},{key,proof:accepted.agent.prompt_acceptances.find(p=>p.receipt.client_request_id===firstId)});
      assert.equal(await page.locator("[data-retry-prompt]").count(),1,"same text remains a distinct intent");
      // Exact in-flight retry is cancelled with the keyboard, while a newer draft/file stays.
      late=gate();mode="held";
      await page.locator("[data-retry-prompt]").click();
      await page.waitForFunction(()=>[...state.promptOutbox.entries.values()][0]?.status==="sending");
      assert.equal(await page.locator("[data-composer-submission-error][data-state=retrying]").count(),1,"an active retry has one recovery notice");
      assert.equal((await page.locator("[data-composer-submission-error]").innerText()).replace(/\s+/g," ").trim(),"Retrying message Cancel retry");
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
      const heldId=await page.evaluate(()=>[...state.promptOutbox.entries.values()][0].id);
      // Sending status precedes server acceptance. Test a proof only after the
      // server commits it, while the browser's HTTP response is still held.
      let acceptanceTimeout;
      await Promise.race([acceptanceFor(heldId).promise,new Promise((_,reject)=>{acceptanceTimeout=setTimeout(()=>reject(Error("Synthetic acceptance was not reached")),12000);})]).finally(()=>clearTimeout(acceptanceTimeout));
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
      evidence.push({repeat,width,theme,peer,delivery,writes,firstId,secondId,proof_without_replay:true,cancel_kept_server_queue:true});
    } catch(error){
      note("failure-state",await page.evaluate(()=>({entries:[...(state.promptOutbox?.entries.values()||[])].map(e=>({id:e.id,status:e.status})),lanes:[...(state.promptOutbox?.lanes.keys()||[])],detail_proofs:Object.values(state.agentDetails).flatMap(a=>(a.prompt_acceptances||[]).map(p=>p.receipt?.client_request_id)),events:globalThis.__retryEvents,form:document.querySelector("#composer")?.dataset,pending_composer:[...state.pendingComposerKeys],pending_comments:[...state.pendingPullRequestCommentKeys]})).catch(()=>({unavailable:true})));
      note("page-errors",{errors});
      if(captureDir)fs.writeFileSync(path.join(captureDir,`retry-trace-${width}-${theme}-${peer}-${delivery}.json`),JSON.stringify(trace,null,2));
      if(captureDir)await page.screenshot({path:path.join(captureDir,`retry-failure-${width}-${theme}-${peer}-${delivery}.png`)}).catch(()=>{});
      throw error;
    } finally {late.release();await context.close();}
  }
  if(captureDir)fs.writeFileSync(path.join(captureDir,"prompt-retry-browser.json"),JSON.stringify(evidence,null,2));
  console.log(JSON.stringify(evidence,null,2));
};
