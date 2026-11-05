const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
module.exports = async ({browser, baseUrl, captureDir, advanceInquiry, waitForInquiryRuns}) => {
  assert.equal(new URL(baseUrl).hostname,"127.0.0.1");
  const baseline = process.env.TYCHO_REMOTE_UI_INQUIRY_BASELINE;
  const selectedCase = process.env.TYCHO_REMOTE_UI_INQUIRY_RECEIPT_CASE;
  const evidence = [];
  let fixtureIndex = 0;
  for (const width of (selectedCase ? [1440] : process.env.TYCHO_REMOTE_UI_INQUIRY_CORRECTION_CASE ? [] : baseline ? [1440] : [1440,390])) for (const theme of (selectedCase || baseline ? ["dark"] : ["dark","light"])) {
    for (const scenario of (selectedCase ? [selectedCase] : baseline ? ["lost"] : ["lost", "malformed", "empty", "wrong-server", "wrong-inquiry", "auth", "unbound-conflict", "rejection"])) {
      console.log(`Inquiry recovery: ${width} ${theme} ${scenario}`);
      const context = await browser.newContext({viewport:{width,height:900},isMobile:width<500,hasTouch:width<500});
      const page = await context.newPage();
      page.setDefaultTimeout(10000);
      const errors = [], payloads = [], receipts = [];
      let releaseRetryResponse, markRetryDispatched;
      const retryResponse = new Promise(resolve => { releaseRetryResponse = resolve; });
      const retryDispatched = new Promise(resolve => { markRetryDispatched = resolve; });
      page.on("pageerror",e=>errors.push(e.message));
      try {
        if (baseline) await page.route(/\/ui.js(?:\?|$)/, route => route.fulfill({status:200, contentType:"application/javascript", body:fs.readFileSync(baseline,"utf8")}));
        await page.addInitScript(value => localStorage.setItem("hq.remote.appearance",value),theme);
        const key = `web-inquiry-recovery-${fixtureIndex++}`;
        const current = await (await context.request.get(`${baseUrl}/agents/${key}`)).json();
        const agent = current.agent;
        const inquiryId = agent?.latest_inquiry?.id;
        assert(inquiryId,"real synthetic inquiry must exist");
        await page.route(new RegExp(`/agents/${agent.key}/inquiries/[^/]+/answer$`),async route=>{
          const payload = route.request().postDataJSON();
          payloads.push(JSON.stringify(payload));
          if (!baseline) assert.equal(payload.response_mode,"answer_receipt");
          if(payloads.length===1 && scenario==="failed-reload") {
            return route.fulfill({status:503,contentType:"application/json",body:JSON.stringify({error:"Synthetic failure before acceptance"})});
          }
          if(payloads.length===1 && scenario==="auth") return route.fulfill({status:401,contentType:"application/json",body:JSON.stringify({error:"Synthetic authentication needed"})});
          if(payloads.length===1 && scenario==="unbound-conflict") return route.fulfill({status:409,contentType:"application/json",body:JSON.stringify({error:"Synthetic unbound conflict"})});
          if(payloads.length===1 && scenario==="rejection") {
            const dismissed=await context.request.post(`${baseUrl}/agents/${agent.key}/inquiries/${inquiryId}/dismiss`,{data:{}});
            assert.equal(dismissed.status(),200);
          }
          const response=await route.fetch();
          assert.equal(response.status(),200);
          const data=await response.json();
          if(payloads.length===2 && scenario==="failed-reload") {
            markRetryDispatched();
            await retryResponse;
          }
          receipts.push(data.answer_receipt || data.answer_rejection);
          if(payloads.length===1) {
            if(scenario==="lost") return route.abort("connectionreset");
            if(scenario==="malformed") return route.fulfill({status:200,contentType:"application/json",body:"invalid"});
            if(scenario==="empty") return route.fulfill({status:200,contentType:"application/json",body:"{}"});
            if(scenario==="wrong-server" || scenario==="wrong-inquiry") return route.fulfill({status:200,contentType:"application/json",body:JSON.stringify({...data,answer_receipt:{...data.answer_receipt,[scenario==="wrong-server"?"server_id":"inquiry_id"]:"different"}})});
          }
          return route.fulfill({response});
        });
        await page.goto(`${baseUrl}/ui#agent/${agent.key}`,{waitUntil:"networkidle"});
        await page.waitForSelector("#inquiry-form",{state:"attached"});
        if (!await page.locator("#inquiry-form").isVisible()) await page.locator("details.mobile-inquiry > summary").click();
        await page.locator('#inquiry-form input[type="text"]').fill("Synthetic answer retained");
        await page.locator('#inquiry-form [name="feedback"]').fill("Synthetic feedback retained");
        // Use the actual attachment picker. File bytes must survive exact retry and reload.
        await page.locator('input[type="file"]').first().setInputFiles({name:"synthetic.txt",mimeType:"text/plain",buffer:Buffer.from("Synthetic attachment only")});
        await page.locator('#inquiry-form button[type="submit"]').click();
        await page.waitForFunction(key => {
          const entry=state.pendingInquirySubmissionEntries.get(key) || inquiryAnswerStore().entries.get(key);
          return entry && !["storing","sending"].includes(entry.status);
        },agent.key);
        await page.waitForSelector("[data-inquiry-answer-recovery]");
        if(scenario==="rejection") {
          assert.match(await page.locator("[data-inquiry-answer-recovery]").innerText(),/Answer not sent/);
          await context.request.post(`${baseUrl}/agents/${agent.key}/inquiries/${inquiryId}/restore`,{data:{}});
          await page.reload({waitUntil:"networkidle"});
          await page.waitForSelector("#inquiry-form",{state:"attached"});
          if (!await page.locator("#inquiry-form").isVisible()) await page.locator("details.mobile-inquiry > summary").click();
          assert.equal(await page.locator('#inquiry-form input[type="text"]').inputValue(),"Synthetic answer retained");
          assert.equal(await page.locator('#inquiry-form [name="feedback"]').inputValue(),"Synthetic feedback retained");
          await page.locator('#inquiry-form input[type="text"]').fill("Corrected synthetic answer");
          assert.equal(await page.locator("#inquiry-form [data-remove-prompt-attachment]").count(),1,"rejected attachment is restored after reload");
          await page.locator('#inquiry-form button[type="submit"]').click();
          await page.waitForFunction(()=>inquiryAnswerStore().entries.size===0);
          assert.notEqual(JSON.parse(payloads[0]).client_request_id,JSON.parse(payloads[1]).client_request_id);
        } else {
          if (scenario==="failed-reload") {
            await page.reload({waitUntil:"networkidle"});
          } else {
            await page.evaluate(()=>navigate({type:"tab",tab:"agents"}));
            await page.goto(`${baseUrl}/ui#agent/${agent.key}`,{waitUntil:"networkidle"});
          }
          await page.waitForSelector("[data-retry-inquiry-answer]");
          assert.equal(payloads.length,1,"reload/navigation does not write automatically");
          if (scenario==="failed-reload") {
            const recovered = await page.evaluate(key=>({
              entries: [...inquiryAnswerStore().entries.values()].map(entry=>({id:entry.id,status:entry.status})),
              pending: (state.pendingConversationMessages[key] || []).map(block=>({id:block.id,intent:block.metadata?.inquiry_intent_id})),
            }),agent.key);
            assert.equal(recovered.entries.length,1,"failed answer remains saved after reload");
            assert.deepEqual(recovered.pending.map(block=>block.intent),[JSON.parse(payloads[0]).client_request_id],"saved entry restores its original inquiry intent block");
            assert.equal(await page.locator(".message.user.inquiry-response").count(),1,"failed answer is restored to the conversation after reload");
            assert.match(await page.locator(".message.user.inquiry-response").innerText(),/Synthetic answer retained/);
            assert.match(await page.locator(".message-send-status").innerText(),/Answer not confirmed/);
            const retryClick = page.locator("[data-retry-inquiry-answer]").click();
            await retryDispatched;
            const response = await context.request.get(`${baseUrl}/agents/${agent.key}/conversation?limit=100`);
            assert.equal(response.status(),200);
            const conversation = await response.json();
            assert(conversation.conversation.some(block=>block.metadata?.inquiry_intent_id===JSON.parse(payloads[0]).client_request_id),"retry stores the original answer on the server");
            await page.evaluate(({key,conversation})=>{
              receiveConversationSnapshot(key,conversation.conversation,conversation.conversation_revision,{initial:true,digest:conversation.conversation_digest,
                totalBlockCount:conversation.conversation_block_count,hasOlder:conversation.conversation_has_older===true});
              render();
            },{key:agent.key,conversation});
            assert.equal(await page.locator(".message.user.inquiry-response").count(),1,"server copy replaces the restored answer block once");
            assert.equal((await page.locator(".message-list").innerText()).split("Synthetic answer retained").length-1,1,"answer text appears once when the server copy arrives");
            releaseRetryResponse();
            await retryClick;
            await page.waitForFunction(()=>inquiryAnswerStore().entries.size===0);
            assert.equal(await page.locator(".message.user.inquiry-response").count(),1,"successful retry leaves one conversation answer");
            assert.equal(payloads.length,2);
            assert.equal(payloads[0],payloads[1],"retry after reload uses the exact saved request");
            evidence.push({width,theme,scenario,writes:payloads.length,exactRetry:true,outcome:receipts.at(-1)?.accepted});
            continue;
          }
          await page.locator("[data-inquiry-answer-recovery] summary").click();
          const text = await page.locator("[data-inquiry-answer-recovery]").innerText();
          assert.match(text,/Your answer/);
          assert.match(text,/Synthetic answer retained/);
          assert(!text.includes("user_feedback"),"saved preview uses field labels instead of serialized payload keys");
          assert.match(text,/Synthetic feedback retained/);
          assert.match(text,/synthetic.txt/);
          assert(await page.evaluate(()=>document.documentElement.scrollWidth<=innerWidth),"no horizontal overflow");
          if(scenario==="lost" && captureDir) {
            fs.mkdirSync(captureDir,{recursive:true});
            await page.screenshot({path:path.join(captureDir,`inquiry-${width}-${theme}.png`)});
          }
          await page.locator("[data-retry-inquiry-answer]").click();
          await page.waitForFunction(()=>inquiryAnswerStore().entries.size===0);
          assert.equal(payloads.length,2);
          assert.equal(payloads[0],payloads[1],"exact payload and intent survive reload");
          if(!["auth","unbound-conflict"].includes(scenario)) assert.equal(receipts.at(-1).replayed,true);
        }
        await page.waitForFunction(()=>!document.querySelector("[data-inquiry-answer-recovery]"));
        assert.deepEqual(errors,[]);
        evidence.push({width,theme,scenario,writes:payloads.length,exactRetry:scenario!=="rejection",outcome:receipts.at(-1)?.accepted});
      } finally {await context.close();}
    }
  }
  if(captureDir) fs.writeFileSync(path.join(captureDir,"inquiry-browser.json"),JSON.stringify(evidence,null,2));
  if (!baseline && !selectedCase) await require("./inquiry_recovery_corrections_smoke")({browser, baseUrl, captureDir, advanceInquiry});
  if (waitForInquiryRuns) console.log(waitForInquiryRuns());
  console.log("inquiry_receipt_smoke: ok");
};
