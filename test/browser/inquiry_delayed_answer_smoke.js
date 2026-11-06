const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");

module.exports = async ({browser, baseUrl, captureDir, waitForInquiryRuns}) => {
  assert.equal(new URL(baseUrl).hostname,"127.0.0.1");
  const selected=process.env.TYCHO_REMOTE_UI_INQUIRY_DELAYED_CASE;
  const results=[];
  const gate=()=>{let release;const promise=new Promise(resolve=>{release=resolve;});return {promise,release};};
  let index=0;
  const viewport=process.env.TYCHO_REMOTE_UI_INQUIRY_DELAYED_VIEWPORT;
  const widths=selected?[viewport==="mobile"?390:1440]:[1440,390];
  for(const width of widths) for(const theme of (selected?[width<500?"light":"dark"]:["dark","light"])) for(const peer of (selected?[false]:[false,true])) for(const scenario of (selected?[selected]:["detail","activity","mutation","retire"])) {
    const rawKey=`web-inquiry-recovery-${index++}`,key=peer?`fixture-peer/${rawKey}`:rawKey;
    const context=await browser.newContext({viewport:{width,height:900},isMobile:width<500,hasTouch:width<500});
    const page=await context.newPage();page.setDefaultTimeout(10000);
    const answer=gate(),captured=gate(),reads=gate();let holdReads=false,projection,writes=0,activityAgent,heldAt=0;const submittedIds=[];
    const errors=[];page.on("pageerror",error=>errors.push(error.message));
    console.log(`Delayed answer: ${width} ${theme} ${peer?"peer":"local"} ${scenario}`);
    try {
      await page.addInitScript(theme=>localStorage.setItem("hq.remote.appearance",theme),theme);
      await page.route("**/*",async route=>{
        const request=route.request(),url=new URL(request.url());
        const routed=url.pathname.startsWith("/servers/fixture-peer/");
        const pathname=routed?url.pathname.replace("/servers/fixture-peer",""):url.pathname;
        const fetchRoute=()=>route.fetch(routed?{url:`${baseUrl}${pathname}${url.search}`} : {});
        if(request.method()==="POST" && pathname.match(new RegExp(`/agents/${rawKey}/inquiries/[^/]+/answer$`))) {
          assert.equal(routed,peer);writes++;submittedIds.push(request.postDataJSON().client_request_id);
          const response=await fetchRoute();assert.equal(response.status(),200);
          projection=(await response.json()).agent;heldAt=Date.now();captured.release();await answer.promise;
          return route.fulfill({response});
        }
        if(holdReads && request.method()==="GET" && /^\/(agents|servers|setup|schedules|projects)(\/|$)/.test(pathname)) await reads.promise;
        const response=await fetchRoute();
        if(peer && url.pathname==="/servers/resources") {
          const data=await response.json(),local=data.servers.find(server=>server.local);
          data.servers.push({...local,key:"fixture-peer",name:"Synthetic peer",local:false,url:baseUrl});
          return route.fulfill({response,json:data});
        }
        if(url.pathname==="/servers/activity" && (peer || activityAgent)) {
          const data=await response.json(),local=data.servers.find(server=>server.key==="local");
          // Deliver the current real HTTP agent through the activity consumer without
          // waiting for the service's separate background snapshot refresh.
          if(local && activityAgent) {local.ready=true; local.agents=local.agents.map(agent=>agent.key===rawKey ? activityAgent : agent); data.revision="synthetic-newer-activity";}
          if(local && peer) data.servers.push({...local,key:"fixture-peer",name:"Synthetic peer",local:false,url:baseUrl});
          return route.fulfill({response,json:data});
        }
        return route.fulfill({response});
      });
      await page.goto(`${baseUrl}/ui#agent/${encodeURIComponent(key)}`,{waitUntil:"networkidle"});
      await page.waitForSelector("#inquiry-form",{state:"attached"});
      if(!await page.locator("#inquiry-form").isVisible()) await page.locator("details.mobile-inquiry > summary").click();
      if(scenario==="storage-delay") {
        await page.evaluate(()=>{
          const storage=inquiryAnswerStore().store, put=storage.put.bind(storage);
          globalThis.__storageWriteStarted=false;
          globalThis.__storageWrite=new Promise(resolve=>globalThis.__releaseStorageWrite=resolve);
          storage.put=entry=>{globalThis.__storageWriteStarted=true;return globalThis.__storageWrite.then(()=>put(entry));};
        });
      }
      await page.evaluate(()=>{clearTimeout(state.timer);clearTimeout(state.activityTimer);const original=refresh;globalThis.__answerRefreshes=0;refresh=async(...args)=>{globalThis.__answerRefreshes++;return original(...args);};});
      await page.locator('#inquiry-form input[type="text"]').fill("Synthetic delayed answer");
      if(scenario==="storage-delay") await page.evaluate(()=>{globalThis.__duplicateInquiryForm=document.querySelector("#inquiry-form").cloneNode(true);});
      await page.locator('#inquiry-form button[type="submit"]').click();
      if(scenario==="storage-delay") {
        await page.waitForFunction(()=>globalThis.__storageWriteStarted);
        await page.evaluate(()=>{
          const duplicate=globalThis.__duplicateInquiryForm;
          els.view.append(duplicate);
          duplicate.dispatchEvent(new SubmitEvent("submit",{bubbles:true,cancelable:true}));
          duplicate.remove();
        });
        assert.equal(await page.locator("#inquiry-form").count(),0,"reserved inquiry closes before delayed local storage completes");
        assert.equal(await page.locator("[data-inquiry-answer-recovery]").count(),0,"normal send has no composer recovery panel");
        assert.equal(await page.locator(".message.user.inquiry-response").count(),1,"in-memory reservation shows the existing answer block during delayed storage");
        const reservedId=await page.evaluate(key=>state.pendingInquirySubmissionEntries.get(key)?.id,key);
        await page.evaluate(()=>globalThis.__releaseStorageWrite());
        await captured.promise;
        assert.equal(writes,1,"a second submit during delayed storage sends one POST");
        assert.deepEqual(submittedIds,[reservedId],"the request uses the synchronously reserved idempotency key");
      }
      await captured.promise;
      assert.match(page.url(), /#agent\//, "answer submission should open the conversation before the POST returns");
      assert.equal(await page.locator("#inquiry-form").count(),0,"inquiry review form closes while the answer is pending");
      assert.equal(await page.locator("[data-inquiry-answer-recovery]").count(),0,"normal send has no composer recovery panel");
      assert.equal(await page.locator(".message.user.inquiry-response").count(),1,"the submitted answer uses the existing conversation answer block while pending");
      assert.match(await page.locator(".message.user.inquiry-response").innerText(),/Synthetic delayed answer/,
        "conversation shows the answer while the POST is held");
      assert.match(await page.locator(".message-send-status").innerText(),/Sending answer/,"pending message has a subtle send state");
      if(captureDir && process.env.TYCHO_REMOTE_UI_INQUIRY_CONTACT_SHEET==="1" && !peer && scenario==="detail") {
        fs.mkdirSync(captureDir,{recursive:true});
        for(const delay of [0,100,300,600,1000,2000,2500]) {
          const remaining=heldAt+delay-Date.now();
          if(remaining>0) await new Promise(resolve=>setTimeout(resolve,remaining));
          await page.screenshot({path:path.join(captureDir,`inquiry-${width}-${delay}.png`)});
        }
      }
      await page.keyboard.press("Tab");
      assert.equal(await page.evaluate(()=>document.activeElement !== document.body),true,"conversation keeps keyboard focus available after navigation");
      if(captureDir && !peer && scenario==="detail") await page.screenshot({path:path.join(captureDir,`pending-${width}-${theme}.png`)});
      if(waitForInquiryRuns) console.log(waitForInquiryRuns());
      if(scenario==="retire") {
        const response=await context.request.post(`${baseUrl}/agents/${rawKey}/archive`,{data:{}});assert.equal(response.status(),200);
        await page.evaluate(key=>retireArchivedAgent(key),key);
      } else if(["detail","activity","mutation"].includes(scenario)) {
        const response=await context.request.patch(`${baseUrl}/agents/${rawKey}`,{data:{name:"Newer canonical name"}});assert.equal(response.status(),200);
        const changed=await response.json();
        if(scenario==="detail") await page.evaluate(key=>ensureAgentDetail(key,true),key);
        if(scenario==="activity") {activityAgent=changed.agent; await page.evaluate(()=>pollAgentActivity({manual:true}));}
        if(scenario==="mutation") await page.evaluate(({key,agent})=>upsertAgent(normalizeAgentResource(agent,resourceRequest(`/agents/${encodeURIComponent(key)}`).server)),{key,agent:changed.agent});
      }
      // Exercise retained canonical state through navigation while POST is still held.
      if(scenario!=="activity") {
        await page.evaluate(()=>navigate({type:"tab",tab:"agents"}));
        await page.evaluate(key=>navigate({type:"agent",key}),key);
      }
      const snapshot=()=>page.evaluate(key=>({name:state.agentDetails[key]?.name,status:state.agentDetails[key]?.status,running:state.agentDetails[key]?.running,
        archived:state.agentDetails[key]?.archived,active:state.agents.some(agent=>agent.key===key),retired:state.archivedAgentKeys.has(key),
        pending:inquiryAnswerStore().entries.size,refreshes:globalThis.__answerRefreshes}),key);
      const before=await snapshot();
      if(scenario==="refresh-pending") {
        const response=await context.request.get(`${baseUrl}/agents/${encodeURIComponent(rawKey)}/conversation?limit=100`);
        assert.equal(response.status(),200,"conversation refresh succeeds while the answer POST response is held");
        const conversation=await response.json();
        const intentId=await page.evaluate(key=>state.pendingInquirySubmissionEntries.get(key)?.id || inquiryAnswerStore().entries.get(key)?.id,key);
        assert(conversation.conversation.some(block=>block.metadata?.inquiry_intent_id===intentId),"server conversation contains the accepted answer intent");
        await page.evaluate(({key,conversation})=>{
          state.conversations[key]={blocks:conversation.conversation,revision:conversation.conversation_revision,loaded:true};
          state.pendingConversationUpdates[key]={blocks:conversation.conversation,revision:conversation.conversation_revision};
          render();
        },{key,conversation});
        const shown=await page.locator(".message-list").innerText();
        assert.equal((shown.match(/Synthetic delayed answer/g)||[]).length,1,"refresh replaces the optimistic preview with one server answer");
        assert.equal(await page.locator(".message.user.inquiry-response").count(),1,"refresh keeps one answer message");
        assert.equal(await page.locator("[data-inquiry-answer-recovery]").count(),0,"normal send has no composer recovery panel while the server answer loads");
      }
      if(scenario==="retire") {assert.equal(before.active,false);assert.equal(before.archived,true);}
      else if(!["refresh-pending","storage-delay"].includes(scenario)) {assert.equal(before.name,"Newer canonical name");assert.equal(before.running,false);}
      holdReads=true;answer.release();
      await page.waitForFunction(()=>inquiryAnswerStore().entries.size===0);
      if(captureDir && process.env.TYCHO_REMOTE_UI_INQUIRY_CONTACT_SHEET==="1" && !peer && scenario==="detail") {
        await page.screenshot({path:path.join(captureDir,`inquiry-${width}-after-response.png`)});
      }
      const after=await snapshot();
      assert.equal(await page.locator(".message.user.inquiry-response").count(),1,"confirmed answer remains once in the conversation");
      assert.equal(await page.locator("[data-inquiry-answer-recovery]").count(),0,"sending information closes after confirmation");
      assert.equal(after.name,before.name,"delayed POST must preserve newer canonical name");
      if(!["storage-delay","refresh-pending"].includes(scenario)) assert.equal(after.status,before.status,"delayed POST must preserve completion");
      if(!["storage-delay","refresh-pending"].includes(scenario)) assert.equal(after.running,before.running,"delayed POST must preserve running state");
      assert.equal(after.archived,before.archived,"delayed POST must preserve archive state");
      assert.equal(after.active,before.active,"delayed POST must not reinsert retired agent");
      assert.equal(after.retired,before.retired);assert.equal(after.pending,0);
      if(process.env.TYCHO_REMOTE_UI_INQUIRY_CONTACT_SHEET!=="1") assert.equal(after.refreshes,1);
      assert.equal(writes,1);
      const persisted=(await (await context.request.get(`${baseUrl}/agents/${rawKey}`)).json()).agent;
      assert.equal(persisted.archived,scenario==="retire");
      assert.equal(after.name,persisted.name);if(!["storage-delay","refresh-pending"].includes(scenario)) assert.equal(after.running,persisted.running);
      reads.release();await page.waitForFunction(()=>!state.refreshInFlight);
      assert.deepEqual(errors,[]);results.push({width,theme,peer,scenario,before,projection:{name:projection.name,status:projection.status,running:projection.running,archived:projection.archived},after,writes,passed:true});
    } catch(error) {
      if(captureDir) fs.writeFileSync(path.join(captureDir,`delayed-failure-${scenario}.json`),JSON.stringify({scenario,errors,message:error.message},null,2));
      throw error;
    } finally {answer.release();reads.release();await page.unrouteAll({behavior:"ignoreErrors"});await context.close();}
  }
  if(captureDir) fs.writeFileSync(path.join(captureDir,"inquiry-delayed.json"),JSON.stringify({synthetic:true,results},null,2));
  if(waitForInquiryRuns) console.log(waitForInquiryRuns());console.log("inquiry_delayed_answer_smoke: ok");
};
