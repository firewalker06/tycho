const assert = require("node:assert/strict");

module.exports = async ({browser, baseUrl, advanceInquiry, waitForInquiryRuns}) => {
  const viewportWidth = Number(process.env.TYCHO_REMOTE_UI_INQUIRY_LATE_STORE_VIEWPORT || 1440);
  const cases = [
    {key:"web-inquiry-recovery-0", mode:"closed", visible:"#composer"},
    {key:"web-inquiry-recovery-1", mode:"replacement", visible:"#inquiry-form"},
  ];
  const failures = [];

  for (const scenario of cases) {
    const context = await browser.newContext({
      viewport:{width:viewportWidth,height:viewportWidth <= 600 ? 844 : 900},
      isMobile:viewportWidth <= 600,
      hasTouch:viewportWidth <= 600,
    });
    const page = await context.newPage();
    page.setDefaultTimeout(10000);
    try {
      const detailResponse = await context.request.get(`${baseUrl}/agents/${scenario.key}`);
      assert.equal(detailResponse.status(),200);
      const agent = (await detailResponse.json()).agent;
      const oldInquiryId = agent.latest_inquiry.id;
      await page.goto(`${baseUrl}/ui#agent/${scenario.key}`,{waitUntil:"networkidle"});
      await page.waitForSelector("#inquiry-form",{state:"attached"});
      if (viewportWidth <= 600 && !await page.locator("#inquiry-form").isVisible()) {
        await page.locator("details.mobile-inquiry > summary").click();
      }

      const entry = {
        id:`late-store-${scenario.key}`,
        key:scenario.key,
        inquiryId:oldInquiryId,
        payload:{answer:JSON.stringify({choice:"Saved answer for the old inquiry"}),feedback:"",attachments:[]},
        status:"rejected",
        preview:[{key:"choice",label:"Your answer",type:"text",value:"Saved answer for the old inquiry"}],
        destination:{
          agent_key:scenario.key,
          server_id:agent.delegation.server_id,
          path:`/agents/${encodeURIComponent(scenario.key)}/inquiries/${encodeURIComponent(oldInquiryId)}/answer`,
          url:new URL(baseUrl).origin,
        },
        attachmentIds:[],
        controls:{},
        draftStorageKey:"",
      };
      await page.evaluate(async saved => {
        const store = inquiryAnswerStore();
        await store.ready;
        await store.store.put(saved);
      },entry);

      if (scenario.mode === "closed") {
        const closed = await context.request.post(`${baseUrl}/agents/${scenario.key}/inquiries/${oldInquiryId}/dismiss`,{data:{}});
        assert.equal(closed.status(),200,"another path closes the inquiry before the page reload");
      } else {
        assert.ok(advanceInquiry,"the fixture can create a replacement inquiry");
        const nextId = await advanceInquiry(scenario.key);
        await waitForInquiryRuns?.();
        assert.notEqual(nextId,oldInquiryId,"the server replaces the original inquiry");
      }

      await page.addInitScript(() => {
        Object.defineProperty(globalThis,"TychoInquirySubmissions",{
          configurable:true,
          set(api) {
            const originalStorage = api.storage;
            api.storage = () => {
              const store = originalStorage();
              const originalAll = store.all;
              let firstRead = true;
              store.all = () => {
                if (!firstRead) return originalAll();
                firstRead = false;
                return new Promise((resolve,reject) => {
                  globalThis.__releaseSavedAnswers = () => originalAll().then(resolve,reject);
                });
              };
              return store;
            };
            Object.defineProperty(globalThis,"TychoInquirySubmissions",{
              value:api,configurable:true,writable:true,
            });
          },
        });
      });
      await page.reload({waitUntil:"networkidle"});
      await page.waitForSelector(scenario.visible,{state:"attached"});
      if (scenario.visible === "#inquiry-form" && viewportWidth <= 600 && !await page.locator("#inquiry-form").isVisible()) {
        await page.locator("details.mobile-inquiry > summary").click();
      }
      await page.locator(scenario.visible).waitFor({state:"visible"});
      const visibleBeforeRead = await page.locator(scenario.visible).count();
      await page.evaluate(async () => {
        if (!globalThis.__releaseSavedAnswers) throw new Error("Saved-answer read did not wait as expected");
        globalThis.__releaseSavedAnswers();
        await inquiryAnswerStore().ready;
        await new Promise(requestAnimationFrame);
      });
      const stateAfterRead = await page.evaluate(async ({key,selector}) => {
        const control = document.querySelector(selector);
        return {
        present:Boolean(control),
        visible:Boolean(control?.getClientRects().length),
        entries:inquiryAnswerStore().entries.size,
        disk:(await inquiryAnswerStore().store.all()).length,
        latestInquiry:findAgent(key)?.latest_inquiry?.id || null,
        };
      },{key:scenario.key,selector:scenario.visible});
      if (visibleBeforeRead !== 1 || !stateAfterRead.present || !stateAfterRead.visible || stateAfterRead.entries !== 0 || stateAfterRead.disk !== 0) {
        failures.push({width:viewportWidth,...scenario,visibleBeforeRead,stateAfterRead});
      }
    } finally {
      await context.close();
    }
  }

  assert.deepEqual(failures,[],`Delayed saved-answer load removed the current composer or inquiry form: ${JSON.stringify(failures)}`);
};
