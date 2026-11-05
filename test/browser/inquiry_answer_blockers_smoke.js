const assert = require("node:assert/strict");

module.exports = async ({browser, baseUrl}) => {
  const scenario = process.env.TYCHO_REMOTE_UI_INQUIRY_BLOCKER_CASE;
  assert.match(scenario || "", /^blocker-/);
  const context = await browser.newContext({viewport:{width:1440,height:900}});
  const page = await context.newPage();
  page.setDefaultTimeout(10000);
  const writes = [];
  const writeWaiters = [];
  const waitForWriteCount = count => writes.length >= count ? Promise.resolve() : new Promise(resolve => writeWaiters.push({count,resolve}));
  try {
    const key = "web-inquiry-recovery-0";
    const original = (await (await context.request.get(`${baseUrl}/agents/${key}`)).json()).agent;
    const inquiryId = original.latest_inquiry.id;
    await page.route(new RegExp(`/agents/${key}/inquiries/[^/]+/answer$`), async route => {
      const payload = route.request().postDataJSON();
      writes.push(payload);
      writeWaiters.filter(waiter => writes.length >= waiter.count).forEach(waiter => waiter.resolve());
      if (scenario === "blocker-cancel-race" && writes.length === 1) {
        return route.fulfill({status:503,contentType:"application/json",body:JSON.stringify({error:"Synthetic failure before acceptance"})});
      }
      if (scenario === "blocker-cancel-race" && writes.length === 2) {
        return route.fulfill({status:503,contentType:"application/json",body:JSON.stringify({error:"Synthetic failure before acceptance"})});
      }
      if (scenario === "blocker-lost-edited" || scenario === "blocker-refresh-fields") {
        if (writes.length > 1 && JSON.stringify(payload) !== JSON.stringify(writes[0])) {
          return route.fulfill({status:409,contentType:"application/json",body:JSON.stringify({error:"Answer intent does not match"})});
        }
        const response = await route.fetch();
        if (writes.length === 1) return route.abort("connectionreset");
        return route.fulfill({response});
      }
      if (scenario === "blocker-schema-correction" && writes.length === 1) {
        const response = await route.fetch();
        assert.equal(response.status(),200,"server accepts the original answer before its reply is lost");
        return route.abort("connectionreset");
      }
      if (["blocker-retry-label", "blocker-attachment-correction", "blocker-file-add", "blocker-clear-feedback", "blocker-remove-rejected", "blocker-complete-draft"].includes(scenario) && writes.length === 1) {
        return route.fulfill({status:503,contentType:"application/json",body:JSON.stringify({error:"Synthetic failure before acceptance"})});
      }
      if (["blocker-retry-label", "blocker-attachment-correction", "blocker-remove-rejected", "blocker-complete-draft"].includes(scenario) && writes.length === 2) {
        const response = await context.request.post(`${baseUrl}/agents/${key}/inquiries/${inquiryId}/dismiss`,{data:{}});
        assert.equal(response.status(),200,"the same inquiry is dismissed before the retry reaches the server");
      }
      if (["blocker-multiselect-comma", "blocker-durable-rejection-correction"].includes(scenario) && writes.length === 1) {
        return route.fulfill({status:503,contentType:"application/json",body:JSON.stringify({error:"Synthetic failure before acceptance"})});
      }
      if (scenario === "blocker-durable-rejection-correction" && writes.length === 2) {
        const response = await context.request.post(`${baseUrl}/agents/${key}/inquiries/${inquiryId}/dismiss`,{data:{}});
        assert.equal(response.status(),200,"the same inquiry is dismissed before the retry reaches the server");
      }
      const response = await route.fetch();
      return route.fulfill({response});
    });

    await page.goto(`${baseUrl}/ui#agent/${key}`,{waitUntil:"networkidle"});
    await page.waitForSelector("#inquiry-form",{state:"attached"});
    if (!await page.locator("#inquiry-form").isVisible()) await page.locator("details.mobile-inquiry > summary").click();
    if (["blocker-multiselect-comma", "blocker-schema-correction", "blocker-attachment-correction", "blocker-file-add", "blocker-remove-rejected", "blocker-complete-draft"].includes(scenario)) {
      await page.locator('#inquiry-form input[type="checkbox"]').first().check();
      if (scenario !== "blocker-multiselect-comma") {
        await page.locator('#inquiry-form input[name="choice"]').fill("Original answer");
      }
      if (scenario === "blocker-multiselect-comma") {
        await page.locator('input[type="file"]').first().setInputFiles({name:"regions.png",mimeType:"image/png",buffer:Buffer.from("synthetic image")});
      }
      if (["blocker-attachment-correction", "blocker-remove-rejected", "blocker-complete-draft"].includes(scenario)) {
        await page.locator('input[type="file"]').first().setInputFiles({name:"removed.txt",mimeType:"text/plain",buffer:Buffer.from("remove me")});
      }
      if (scenario === "blocker-complete-draft") {
        await page.locator('#inquiry-form [name="response"]').fill("Original response");
        await page.locator('#inquiry-form [name="count"]').fill("1");
      }
    } else if (scenario === "blocker-durable-rejection-correction") {
      await page.locator('#inquiry-form input[type="text"]').fill("Original answer");
      await page.locator('#inquiry-form input[type="checkbox"]').first().check();
      await page.locator('input[type="file"]').first().setInputFiles({name:"saved.txt",mimeType:"text/plain",buffer:Buffer.from("Saved bytes")});
    } else {
      await page.locator('#inquiry-form input[type="text"]').fill("Original answer");
    }
    await page.locator('#inquiry-form [name="feedback"]').fill("Original feedback");
    await page.locator('#inquiry-form button[type="submit"]').click();

    if (scenario === "blocker-retry-label") {
      await page.waitForFunction(key => inquiryAnswerStore().entries.get(key)?.status === "uncertain",key);
      const uncertainSubmit = page.locator('#inquiry-form button[type="submit"]');
      assert.equal((await uncertainSubmit.innerText()).trim(),"Retry","an uncertain failed answer labels the shared submit button Retry");
      await page.locator("#inquiry-form [data-retry-inquiry-answer]").click();
      await page.waitForFunction(key => inquiryAnswerStore().entries.get(key)?.status === "rejected",key);
      assert.equal(writes.length,2);
      const restored = await context.request.post(`${baseUrl}/agents/${key}/inquiries/${inquiryId}/restore`,{data:{}});
      assert.equal(restored.status(),200);
      await page.reload({waitUntil:"networkidle"});
      await page.waitForSelector("#inquiry-form button[type=submit]");
      assert.equal((await page.locator('#inquiry-form button[type="submit"]').innerText()).trim(),"Retry","a rejected failed answer also labels the shared submit button Retry");
      return;
    }

    if (scenario === "blocker-schema-correction") {
      await page.waitForFunction(key => inquiryAnswerStore().entries.get(key)?.status === "uncertain",key);
      await page.reload({waitUntil:"networkidle"});
      const correctionForm = page.locator("#inquiry-form");
      await correctionForm.locator('[name="choice"]').fill("Latest correction after lost reply");
      await correctionForm.locator('input[name="regions"]').nth(0).uncheck();
      await correctionForm.locator('input[name="regions"]').nth(1).check();
      await correctionForm.locator('[name="feedback"]').fill("Latest feedback");
      await page.waitForFunction(async key => {
        const store = inquiryAnswerStore();
        const entry = store.entries.get(key);
        await Promise.all(store.pendingWrites.values());
        return !entry?.correctionDraftSavePending && entry?.correctionDraft?.choice === "Latest correction after lost reply" &&
          entry.correctionDraft?.regions?.length === 1 && entry.correctionDraft.regions[0] === "Tokyo" &&
          entry.correctionDraft?.user_feedback === "Latest feedback";
      },key);
      assert.equal(writes.length,1,"saving corrections does not send another answer request");
      await page.reload({waitUntil:"networkidle"});
      const restoredForm = page.locator("#inquiry-form");
      assert.equal(await restoredForm.locator('[name="choice"]').inputValue(),"Latest correction after lost reply");
      assert.equal(await restoredForm.locator('input[name="regions"]').nth(0).isChecked(),false);
      assert.equal(await restoredForm.locator('input[name="regions"]').nth(1).isChecked(),true);
      assert.equal(await restoredForm.locator('[name="feedback"]').inputValue(),"Latest feedback");
      const saved = await page.evaluate(key => inquiryAnswerStore().entries.get(key).correctionDraft,key);
      assert.equal(saved.choice,"Latest correction after lost reply");
      assert.deepEqual(saved.regions,["Tokyo"]);
      assert.equal(saved.user_feedback,"Latest feedback");
      return;
    }

    if (scenario === "blocker-file-add") {
      await page.waitForFunction(key => inquiryAnswerStore().entries.get(key)?.status === "uncertain",key);
      await page.locator('input[type="file"]').first().setInputFiles({name:"added.txt",mimeType:"text/plain",buffer:Buffer.from("added after failure")});
      await page.waitForFunction(async key => {
        const store = inquiryAnswerStore();
        const entry = store.entries.get(key);
        await Promise.all(store.pendingWrites.values());
        return !entry?.correctionDraftSavePending && entry?.correctionDraft?.attachments?.length === 1 && entry.correctionDraft.attachments[0].filename === "added.txt";
      },key);
      assert.equal(writes.length,1,"adding a file does not send another answer request");
      await page.reload({waitUntil:"networkidle"});
      assert.equal(await page.locator("#inquiry-form [data-remove-prompt-attachment]").count(),1,"added file is restored after reload");
      assert.match(await page.locator("#inquiry-form").innerText(),/added.txt/);
      assert.equal(await page.locator('#inquiry-form [name="choice"]').inputValue(),"Original answer");
      return;
    }

    if (scenario === "blocker-clear-feedback") {
      await page.waitForFunction(key => inquiryAnswerStore().entries.get(key)?.status === "uncertain",key);
      await page.locator('#inquiry-form [name="feedback"]').fill("");
      await page.waitForFunction(async key => {
        const store = inquiryAnswerStore();
        const entry = store.entries.get(key);
        await Promise.all(store.pendingWrites.values());
        return !entry?.correctionDraftSavePending && Object.hasOwn(entry?.correctionDraft || {},"user_feedback") && entry.correctionDraft.user_feedback === null;
      },key);
      await page.reload({waitUntil:"networkidle"});
      assert.equal(await page.locator('#inquiry-form [name="feedback"]').inputValue(),"","cleared feedback stays empty after reload");
      assert.equal(writes.length,1,"clearing feedback does not send another answer request");
      const saved = await page.evaluate(key => inquiryAnswerStore().entries.get(key).correctionDraft,key);
      assert.equal(saved.user_feedback,null);
      return;
    }

    if (scenario === "blocker-remove-rejected") {
      await page.waitForFunction(key => inquiryAnswerStore().entries.get(key)?.status === "uncertain",key);
      await page.locator('#inquiry-form [name="choice"]').fill("Corrected before rejection");
      await page.locator('#inquiry-form [data-retry-inquiry-answer]').click();
      await page.locator("#confirmation-dialog [data-confirmation-accept]").click();
      await page.waitForFunction(key => inquiryAnswerStore().entries.get(key)?.status === "rejected",key);
      const restored = await context.request.post(`${baseUrl}/agents/${key}/inquiries/${inquiryId}/restore`,{data:{}});
      assert.equal(restored.status(),200);
      await page.reload({waitUntil:"networkidle"});
      const rejectedForm = page.locator("#inquiry-form");
      assert.equal(await rejectedForm.locator("[data-remove-prompt-attachment]").count(),1);
      await rejectedForm.locator('[data-pending-attachment]:has-text("removed.txt") [data-remove-prompt-attachment]').click();
      await page.waitForFunction(async key => {
        const store = inquiryAnswerStore();
        const entry = store.entries.get(key);
        await Promise.all(store.pendingWrites.values());
        return !entry?.correctionDraftSavePending && entry?.correctionDraft?.attachments?.length === 0;
      },key);
      await page.reload({waitUntil:"networkidle"});
      const restoredForm = page.locator("#inquiry-form");
      assert.equal(await restoredForm.locator("[data-remove-prompt-attachment]").count(),0,"removal in rejected state stays saved");
      assert.equal(await restoredForm.locator('[name="choice"]').inputValue(),"Corrected before rejection");
      await restoredForm.locator('button[type="submit"]').click();
      await page.waitForFunction(() => inquiryAnswerStore().entries.size === 0);
      assert.equal(writes.length,3);
      assert.equal(writes[2].attachments.length,0,"the corrected request excludes the removed attachment");
      assert.equal(JSON.parse(writes[2].answer).choice,"Corrected before rejection");
      assert.notEqual(writes[2].client_request_id,writes[1].client_request_id);
      return;
    }

    if (scenario === "blocker-complete-draft") {
      await page.waitForFunction(key => inquiryAnswerStore().entries.get(key)?.status === "uncertain",key);
      const form = page.locator("#inquiry-form");
      await form.locator('[name="choice"]').fill("Corrected choice");
      await form.locator('input[name="regions"]').nth(0).uncheck();
      await form.locator('input[name="regions"]').nth(1).check();
      await form.locator('[name="response"]').fill("Corrected response");
      await form.locator('[name="count"]').fill("");
      await form.locator('[name="feedback"]').fill("");
      await page.locator('input[type="file"]').first().setInputFiles({name:"added.txt",mimeType:"text/plain",buffer:Buffer.from("added")});
      await page.locator('[data-pending-attachment]:has-text("removed.txt") [data-remove-prompt-attachment]').click();
      await page.waitForFunction(async key => {
        const store = inquiryAnswerStore();
        const entry = store.entries.get(key);
        await Promise.all(store.pendingWrites.values());
        return !entry?.correctionDraftSavePending && entry?.correctionDraft?.choice === "Corrected choice" &&
          entry.correctionDraft?.regions?.length === 1 && entry.correctionDraft.regions[0] === "Tokyo" &&
          entry.correctionDraft?.response === "Corrected response" && entry.correctionDraft?.count === null &&
          entry.correctionDraft?.user_feedback === null && entry.correctionDraft?.attachments?.length === 1 &&
          entry.correctionDraft.attachments[0].filename === "added.txt";
      },key);
      await page.reload({waitUntil:"networkidle"});
      const visibleForm = page.locator("#inquiry-form");
      assert.equal(await visibleForm.locator('[name="choice"]').inputValue(),"Corrected choice");
      assert.equal(await visibleForm.locator('input[name="regions"]').nth(1).isChecked(),true);
      assert.equal(await visibleForm.locator('[name="response"]').inputValue(),"Corrected response");
      assert.equal(await visibleForm.locator('[name="count"]').inputValue(),"");
      assert.equal(await visibleForm.locator('[name="feedback"]').inputValue(),"");
      assert.equal(await visibleForm.locator("[data-remove-prompt-attachment]").count(),1);
      await page.locator('#inquiry-form [data-retry-inquiry-answer]').click();
      await page.locator("#confirmation-dialog [data-confirmation-accept]").click();
      await page.waitForFunction(key => inquiryAnswerStore().entries.get(key)?.status === "rejected",key);
      const restored = await context.request.post(`${baseUrl}/agents/${key}/inquiries/${inquiryId}/restore`,{data:{}});
      assert.equal(restored.status(),200);
      await page.reload({waitUntil:"networkidle"});
      const rejectedForm = page.locator("#inquiry-form");
      assert.equal(await rejectedForm.locator('[name="choice"]').inputValue(),"Corrected choice");
      assert.equal(await rejectedForm.locator('input[name="regions"]').nth(1).isChecked(),true);
      assert.equal(await rejectedForm.locator('[name="response"]').inputValue(),"Corrected response");
      assert.equal(await rejectedForm.locator('[name="count"]').inputValue(),"");
      assert.equal(await rejectedForm.locator('[name="feedback"]').inputValue(),"");
      assert.equal((await rejectedForm.locator("[data-pending-attachment]").innerText()).includes("added.txt"),true);
      const visibleDraft = await rejectedForm.evaluate(form => {
        const data = new FormData(form);
        const feedback = String(data.get("feedback") || "").trim();
        const count = String(data.get("count") || "").trim();
        return {
          answer: {
            choice: String(data.get("choice") || "").trim() || null,
            regions: data.getAll("regions").length ? data.getAll("regions") : null,
            response: String(data.get("response") || "").trim() || null,
            count: count ? Number.parseInt(count,10) : null,
            user_feedback: feedback || null,
          },
          feedback,
          attachments: Array.from(form.querySelectorAll("[data-pending-attachment] .attachment-copy strong"),node=>node.textContent.trim()),
        };
      });
      await rejectedForm.locator('button[type="submit"]').click();
      await page.waitForFunction(() => inquiryAnswerStore().entries.size === 0);
      assert.equal(writes.length,3);
      assert.deepEqual(JSON.parse(writes[2].answer),visibleDraft.answer,"the corrected request matches the visible field values");
      assert.equal(writes[2].feedback,visibleDraft.feedback);
      assert.deepEqual(writes[2].attachments.map(file=>file.filename),visibleDraft.attachments,"the corrected request matches the visible file list");
      return;
    }

    if (scenario === "blocker-attachment-correction") {
      await page.waitForFunction(key => inquiryAnswerStore().entries.get(key)?.status === "uncertain",key);
      const failedForm = page.locator("#inquiry-form");
      await failedForm.locator("[data-remove-prompt-attachment]").click();
      await failedForm.locator('[name="choice"]').fill("Corrected answer without attachment");
      await page.waitForFunction(async key => {
        const store = inquiryAnswerStore();
        const entry = store.entries.get(key);
        await Promise.all(store.pendingWrites.values());
        return !entry?.correctionDraftSavePending && entry?.correctionDraft?.choice === "Corrected answer without attachment" &&
          Array.isArray(entry.correctionDraft.attachments) && entry.correctionDraft.attachments.length === 0;
      },key);
      await page.reload({waitUntil:"networkidle"});
      assert.equal(await page.locator("#inquiry-form [data-remove-prompt-attachment]").count(),0,"removed file stays absent after reload");
      await page.locator('#inquiry-form [data-retry-inquiry-answer]').click();
      await page.locator("#confirmation-dialog [data-confirmation-accept]").click();
      await page.waitForFunction(key => inquiryAnswerStore().entries.get(key)?.status === "rejected",key);
      const restored = await context.request.post(`${baseUrl}/agents/${key}/inquiries/${inquiryId}/restore`,{data:{}});
      assert.equal(restored.status(),200);
      await page.reload({waitUntil:"networkidle"});
      assert.equal(await page.locator("#inquiry-form [data-remove-prompt-attachment]").count(),0,"removed file stays absent after durable rejection");
      await page.locator('#inquiry-form button[type="submit"]').click();
      await page.waitForFunction(() => inquiryAnswerStore().entries.size === 0);
      assert.equal(writes.length,3);
      assert.equal(writes[2].attachments.length,0,"corrected answer does not send the removed file");
      assert.equal(JSON.parse(writes[2].answer).choice,"Corrected answer without attachment");
      return;
    }

    if (scenario === "blocker-cancel-race") {
      await page.waitForSelector("[data-inquiry-answer-recovery]");
      await page.evaluate(key => {
        const store = inquiryAnswerStore();
        const originalPut = store.store.put.bind(store.store);
        let started;
        globalThis.__putStarted = new Promise(resolve => { started = resolve; });
        globalThis.__releasePut = null;
        const gate = new Promise(resolve => { globalThis.__releasePut = resolve; });
        const originalRetry = store.retry.bind(store);
        store.retry = (...args) => (globalThis.__retryPromise = originalRetry(...args));
        const originalSend = store.send.bind(store);
        store.send = (entry, signal) => {
          globalThis.__sendSignal = signal;
          return originalSend(entry, signal);
        };
        store.store.put = entry => {
          if (!globalThis.__heldPut) {
            globalThis.__heldPut = true;
            started();
            return gate.then(() => originalPut(entry));
          }
          return originalPut(entry);
        };
        globalThis.__store = store;
        void key;
      },key);
      await page.locator("[data-retry-inquiry-answer]").click();
      await page.evaluate(() => globalThis.__putStarted);
      await page.locator("[data-cancel-inquiry-answer]").click();
      await page.waitForSelector("[data-inquiry-answer-recovery]",{state:"detached"});
      await page.waitForSelector(".message.user.inquiry-response",{state:"detached"});
      assert.equal(await page.locator(".message.user.inquiry-response").count(),0,"Cancel removes the pending answer block");
      await page.evaluate(() => globalThis.__releasePut());
      await page.evaluate(() => globalThis.__retryPromise);
      await page.waitForFunction(async () => (await globalThis.__store.store.all()).length === 0);
      assert.equal(writes.length,1,"Cancel prevents a retry that is still waiting on storage");
      assert.equal(await page.evaluate(() => globalThis.__store.entries.size),0);
      assert.equal((await page.evaluate(() => globalThis.__store.store.all())).length,0,"cancelled entry is not restored by a stale storage write");

      // A second attempt proves that Cancel also invalidates a late response.
      await page.waitForSelector("#inquiry-form");
      if (!await page.locator("#inquiry-form").isVisible()) await page.locator("details.mobile-inquiry > summary").click();
      await page.locator('#inquiry-form input[type="text"]').fill("Second answer");
      await page.locator('#inquiry-form button[type="submit"]').click();
      await page.waitForFunction(key => inquiryAnswerStore().entries.get(key)?.status === "uncertain",key);
      await page.evaluate(key => {
        const store = globalThis.__store;
        globalThis.__sendStarted = new Promise(resolve => { globalThis.__markSendStarted = resolve; });
        store.send = (entry, signal) => {
          globalThis.__sendSignal = signal;
          globalThis.__cancelledAttempt = {id:entry.id,key:entry.destination.agent_key,serverId:entry.destination.server_id,inquiryId:entry.inquiryId};
          globalThis.__markSendStarted();
          return new Promise(resolve => { globalThis.__resolveLateSend = resolve; });
        };
        void key;
      },key);
      await page.locator("[data-retry-inquiry-answer]").click();
      await page.evaluate(() => globalThis.__sendStarted);
      await page.locator("[data-cancel-inquiry-answer]").click();
      await page.waitForSelector("[data-inquiry-answer-recovery]",{state:"detached"});
      assert.equal(await page.evaluate(() => globalThis.__sendSignal.aborted),true,"Cancel aborts the in-flight request");
      await page.evaluate(() => {
        const attempt = globalThis.__cancelledAttempt;
        globalThis.__resolveLateSend({answer_receipt:{version:1,client_request_id:attempt.id,agent_key:attempt.key,
          server_id:attempt.serverId,inquiry_id:attempt.inquiryId,accepted:true,replayed:true,
          accepted_at:new Date().toISOString(),authority:null,start_result:"not_requested"}});
      });
      await page.evaluate(() => globalThis.__retryPromise);
      assert.equal(await page.evaluate(() => globalThis.__store.entries.size),0,"late success does not recreate a cancelled entry");
      assert.equal((await page.evaluate(() => globalThis.__store.store.all())).length,0);
      assert.equal(writes.length,2,"cancelled retry does not send another answer request");
      return;
    }

    if (scenario === "blocker-durable-rejection-correction") {
      await page.waitForFunction(key => inquiryAnswerStore().entries.get(key)?.status === "uncertain",key);
      const form = page.locator("#inquiry-form");
      await form.locator('[name="choice"]').fill("Corrected answer after failure");
      await form.locator('input[name="regions"]').nth(0).uncheck();
      await form.locator('input[name="regions"]').nth(1).check();
      await page.locator("[data-retry-inquiry-answer]").click();
      const confirmation = page.locator("#confirmation-dialog");
      await confirmation.waitFor({state:"visible"});
      await confirmation.locator("[data-confirmation-accept]").click();
      await page.waitForFunction(key => inquiryAnswerStore().entries.get(key)?.status === "rejected",key);

      const restored = await context.request.post(`${baseUrl}/agents/${key}/inquiries/${inquiryId}/restore`,{data:{}});
      assert.equal(restored.status(),200,"the rejected inquiry can return to the answer form");
      await page.reload({waitUntil:"networkidle"});
      await page.waitForSelector("#inquiry-form",{state:"attached"});
      const restoredForm = page.locator("#inquiry-form");
      assert.equal(await restoredForm.locator('input[type="text"]').inputValue(),"Corrected answer after failure");
      assert.equal(await restoredForm.locator('input[type="checkbox"]').nth(0).isChecked(),false);
      assert.equal(await restoredForm.locator('input[type="checkbox"]').nth(1).isChecked(),true);
      assert.equal(await restoredForm.locator('[name="feedback"]').inputValue(),"Original feedback");
      assert.equal(await restoredForm.locator("[data-remove-prompt-attachment]").count(),1,"the original attachment remains available after rejection");

      await restoredForm.locator('button[type="submit"]').click();
      await page.waitForFunction(() => inquiryAnswerStore().entries.size === 0);
      assert.equal(writes.length,3,"corrected fields submit as one new answer");
      assert.notEqual(writes[2].client_request_id,writes[1].client_request_id,"the correction uses a new intent after durable rejection");
      assert.notEqual(writes[2].client_request_id,writes[0].client_request_id);
      assert.deepEqual(JSON.parse(writes[2].answer),{
        choice:"Corrected answer after failure",
        regions:["Tokyo"],
        user_feedback:"Original feedback"
      });
      assert.equal(writes[2].feedback,"Original feedback");
      assert.equal(writes[2].attachments[0]?.filename,"saved.txt");
      return;
    }

    if (scenario === "blocker-lost-edited" || scenario === "blocker-refresh-fields") {
      await page.waitForFunction(key => inquiryAnswerStore().entries.get(key)?.status === "uncertain",key);
      await page.reload({waitUntil:"networkidle"});
      await page.waitForSelector('#inquiry-form [name="choice"]');
      const editor = page.locator('#inquiry-form [name="choice"]');
      if (scenario === "blocker-refresh-fields") {
        assert.equal(await editor.getAttribute("name"),"choice","saved inquiry fields define the normal answer form");
        assert.equal(await editor.inputValue(),"Original answer","saved answer stays editable after the server accepted it");
        return;
      }
      await editor.fill("Edited after lost reply");
      await page.locator("[data-retry-inquiry-answer]").click();
      const warning = page.locator("#confirmation-dialog");
      await warning.waitFor({state:"visible"});
      const retryWarning = await warning.innerText();
      await warning.locator("[data-confirmation-accept]").click();
      await waitForWriteCount(2);
      assert.match(retryWarning,/original answer/i);
      assert.match(retryWarning,/will not be sent/i);
      assert.deepEqual(writes[1],writes[0],"uncertain retry replays the immutable original intent before any correction");
      await page.waitForFunction(() => inquiryAnswerStore().entries.size === 0);
      assert.equal(await page.locator(".message.user.inquiry-response").count(),1);
      assert.match(await page.locator(".message.user.inquiry-response").innerText(),/Original answer/);
      return;
    }

    assert.equal(scenario,"blocker-multiselect-comma");
    await page.waitForFunction(key => inquiryAnswerStore().entries.get(key)?.status === "uncertain",key);
    await page.reload({waitUntil:"networkidle"});
    await page.waitForSelector('#inquiry-form input[name="regions"]');
    const recovery = page.locator("#inquiry-form");
    assert.equal(await recovery.locator('input[name="regions"]').count(),2,"multi-select failure uses the normal choice controls, not text");
    assert.equal(await recovery.locator('input[name="regions"]').nth(0).inputValue(),"Jakarta, Indonesia");
    assert.equal(await recovery.locator('input[name="regions"]').nth(0).isChecked(),true);
    await recovery.locator('input[name="regions"]').nth(1).check();
    await page.waitForFunction(async key => {
      const store = inquiryAnswerStore();
      const entry = store.entries.get(key);
      await Promise.all(store.pendingWrites.values());
      return entry?.correctionDraft?.regions?.length === 2 && !entry.correctionDraftSavePending && !store.pendingWrites.has(key);
    },key);
    await page.reload({waitUntil:"networkidle"});
    await page.waitForSelector('#inquiry-form input[type="checkbox"][name="regions"]');
    const entry = await page.evaluate(key => {
      const entry = inquiryAnswerStore().entries.get(key);
      return {payload:JSON.parse(entry.payload.answer),correctionDraft:entry.correctionDraft,feedback:entry.payload.feedback,
        attachment:entry.payload.attachments[0]?.filename};
    },key);
    assert.deepEqual(entry.payload.regions,["Jakarta, Indonesia"]);
    assert.deepEqual(entry.correctionDraft.regions,["Jakarta, Indonesia","Tokyo"],"comma within a choice remains part of that value");
    assert.equal(entry.feedback,"Original feedback");
    assert.equal(entry.attachment,"regions.png");
  } finally {
    await context.close();
  }
};
