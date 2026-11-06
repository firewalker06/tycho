const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");

module.exports = async ({browser, baseUrl, captureDir, advanceInquiry}) => {
  const selected = process.env.TYCHO_REMOTE_UI_INQUIRY_CORRECTION_CASE;
  const results = [];
  let index = 32;
  const png = Buffer.from("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVQIHWP4z8DwHwAFgAI/ScL7NwAAAABJRU5ErkJggg==", "base64");
  for (const width of (selected ? [1440] : [1440,390])) for (const theme of (selected ? ["dark"] : ["dark","light"])) {
    for (const scenario of (selected ? [selected] : ["correction", "stale-newer"])) {
      const key = `web-inquiry-recovery-${index++}`;
      console.log(`Inquiry correction: ${width} ${theme} ${scenario}`);
      const context = await browser.newContext({viewport:{width,height:900},isMobile:width<500,hasTouch:width<500});
      const page = await context.newPage();
      page.setDefaultTimeout(10000);
      const errors = [], writes = [];
      page.on("pageerror",error=>errors.push(error.message));
      const openForm = async () => {
        await page.waitForSelector("#inquiry-form",{state:"attached"});
        if (!await page.locator("#inquiry-form").isVisible()) await page.locator("details.mobile-inquiry > summary").click();
      };
      const values = async () => [await page.locator('#inquiry-form input[type="text"]').inputValue(),await page.locator('#inquiry-form [name="feedback"]').inputValue()];
      const edit = async (answer,feedback) => {
        await page.locator('#inquiry-form input[type="text"]').fill(answer);
        await page.locator('#inquiry-form [name="feedback"]').fill(feedback);
      };
      try {
        await page.addInitScript(value=>localStorage.setItem("hq.remote.appearance",value),theme);
        const first = (await (await context.request.get(`${baseUrl}/agents/${key}`)).json()).agent;
        const inquiryA = first.latest_inquiry.id;
        await page.route("**/*",async route=>{
          const request=route.request(), url=new URL(request.url());
          if(request.method()!=="POST" || !url.pathname.match(new RegExp(`/agents/${key}/inquiries/[^/]+/answer$`))) return route.continue();
          const payload=request.postDataJSON();
          writes.push({inquiry:decodeURIComponent(url.pathname.split("/").at(-2)),payload});
          if(scenario==="correction" && writes.length===1) {
            assert.equal((await context.request.post(`${baseUrl}/agents/${key}/inquiries/${inquiryA}/dismiss`,{data:{}})).status(),200);
          }
          const response=await route.fetch();
          assert.equal(response.status(),200);
          const data=await response.json();
          if(scenario!=="correction" && writes.length===1) return route.abort("connectionreset");
          if(writes.length===2 && scenario!=="correction" && writes[1].inquiry===inquiryA) assert.equal(data.answer_receipt.replayed,true,"A replay resolves original acceptance");
          return route.fulfill({response});
        });
        await page.goto(`${baseUrl}/ui#agent/${key}`,{waitUntil:"networkidle"});
        await openForm();
        await edit("Original answer A","Original feedback A");
        await page.locator('input[type="file"]').first().setInputFiles({name:"original-A.png",mimeType:"image/png",buffer:png});
        await page.locator('#inquiry-form button[type="submit"]').click();
        await page.waitForFunction(key=>["rejected","uncertain"].includes(inquiryAnswerStore().entries.get(key)?.status),key);
        if(scenario==="correction") {
          assert.equal(await page.evaluate(key=>inquiryAnswerStore().entries.get(key).status,key),"rejected");
          assert.equal((await context.request.post(`${baseUrl}/agents/${key}/inquiries/${inquiryA}/restore`,{data:{}})).status(),200);
          await page.reload({waitUntil:"networkidle"});
          await openForm();
          await edit("Reload correction","Reload feedback");
          await page.reload({waitUntil:"networkidle"});
          await openForm();
          await page.evaluate(async()=>{await inquiryAnswerStore().ready;restoreFormDrafts();});
          assert.deepEqual(await values(),["Reload correction","Reload feedback"],"S1/SP1: reload preserves newer editable answer and feedback");
          await edit("Navigation correction","Navigation feedback");
          await page.evaluate(()=>navigate({type:"tab",tab:"agents"}));
          await page.evaluate(key=>navigate({type:"agent",key}),key);
          await openForm();
          assert.deepEqual(await values(),["Navigation correction","Navigation feedback"],"S1/SP1: navigation preserves newer editable answer and feedback");
          assert.equal(await page.locator('[data-remove-prompt-attachment]').count(),1);
          if(captureDir) await page.screenshot({path:path.join(captureDir,`correction-${width}-${theme}.png`)});
          await page.locator('#inquiry-form button[type="submit"]').click();
          await page.waitForFunction(()=>inquiryAnswerStore().entries.size===0);
          assert.notEqual(writes[0].payload.client_request_id,writes[1].payload.client_request_id);
          assert.equal(JSON.parse(writes[1].payload.answer).choice,"Navigation correction");
          assert.equal(writes[1].payload.feedback,"Navigation feedback");
          assert.equal(writes[1].payload.attachments[0].filename,"original-A.png");
        } else {
          const inquiryB = advanceInquiry(key);
          assert.notEqual(inquiryB,inquiryA);
          await page.evaluate(async ({key,inquiryB,png})=>{
            await ensureAgentDetail(key,true);
            const agent=findAgent(key);
            if(agent.latest_inquiry.id!==inquiryB) throw Error("Real server inquiry B required");
            // Seed an editable B draft through the production renderer/storage while A recovery is shown.
            const holder=document.createElement("div");holder.hidden=true;holder.innerHTML=renderInquiryForm(agent);els.view.append(holder);
            const form=holder.querySelector("#inquiry-form");
            form.querySelector('input[type="text"]').value="Newer answer B";
            form.querySelector('[name="feedback"]').value="Newer feedback B";
            saveFormDraft(form);holder.remove();
            globalThis.__revokedInquiryUrls=[];
            const revoke=URL.revokeObjectURL.bind(URL);
            URL.revokeObjectURL=url=>{globalThis.__revokedInquiryUrls.push(url);revoke(url);};
            globalThis.__fileA={...pendingAttachmentsFor(key)[0]};
            const bytes=Uint8Array.from(atob(png),char=>char.charCodeAt(0));
            handlePromptAttachmentFiles(key,[new File([bytes],"new-B.png",{type:"image/png"})]);
            globalThis.__fileB={...pendingAttachmentsFor(key).find(file=>file.filename==="new-B.png")};
          },{key,inquiryB,png:png.toString("base64")});
          await page.waitForFunction(()=>inquiryAnswerStore().entries.size===0,"stale answer entry is cleared when inquiry B replaces A");
          assert.equal(await page.locator("[data-inquiry-answer-recovery]").count(),0,"stale answer A has no recovery panel");
          assert.equal(await page.locator(".message.user.inquiry-response").count(),0,"stale answer A is removed from the conversation");
          assert.equal(writes.length,1,"clearing stale answer A does not send a duplicate request");
          await page.waitForFunction(({key,inquiryB})=>state.agentDetails[key]?.latest_inquiry?.id===inquiryB,{key,inquiryB});
          const snapshot=await page.evaluate(key=>({id:state.agentDetails[key]?.latest_inquiry?.id,awaiting:state.agentDetails[key]?.awaiting_input,
            files:pendingAttachmentsFor(key).map(file=>file.filename),revoked:globalThis.__revokedInquiryUrls,
            a:globalThis.__fileA.previewUrl,b:globalThis.__fileB.previewUrl}),key);
          assert.equal(snapshot.id,inquiryB,"stale answer cleanup preserves inquiry B");
          assert.equal(snapshot.awaiting,true,"S2: B remains awaiting input");
          assert.deepEqual(snapshot.files,["new-B.png"],"SP2: only A's consumed files leave shared selection");
          assert.deepEqual(snapshot.revoked,[snapshot.a],"SP2: revoke only consumed A preview, retain B preview");
          await openForm();
          assert.deepEqual(await values(),["Newer answer B","Newer feedback B"],"B draft survives stale answer cleanup");
          // A later normal poll must preserve the newer editable B draft.
          await page.evaluate(async()=>{
            await refresh({force:true}); state.pollDeferredUntil=0; await refresh(); await pollAgentActivity({manual:true});
          });
          await openForm();
          assert.deepEqual(await values(),["Newer answer B","Newer feedback B"]);
          await page.evaluate(()=>navigate({type:"tab",tab:"agents"}));
          await page.evaluate(key=>navigate({type:"agent",key}),key);
          await openForm();
          assert.deepEqual(await values(),["Newer answer B","Newer feedback B"]);
          const bResponse = page.waitForResponse(response=>response.request().method()==="POST" && response.url().endsWith(`/inquiries/${inquiryB}/answer`));
          await page.locator('#inquiry-form button[type="submit"]').click();
          assert.equal((await bResponse).status(),200);
          await page.waitForFunction(()=>inquiryAnswerStore().entries.size===0);
          assert.equal(writes.length,2,"stale A is not replayed when B is current");
          assert.equal(writes[1].inquiry,inquiryB);
          assert.deepEqual(writes[1].payload.attachments.map(file=>file.filename),["new-B.png"],"B payload excludes stale A file");
          assert.equal(writes[1].payload.feedback,"Newer feedback B");
        }
        assert.deepEqual(errors,[]);
        results.push({width,theme,scenario,passed:true,writes:writes.length});
      } finally {await context.close();}
    }
  }
  if(captureDir) fs.writeFileSync(path.join(captureDir,"inquiry-corrections.json"),JSON.stringify(results,null,2));
  console.log("inquiry_recovery_corrections_smoke: ok");
};
