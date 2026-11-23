const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
module.exports = async ({ browser, baseUrl, captureDir, advanceInquiry, waitForInquiryRuns }) => {
  const layouts = [[1260,875], [1366,768], [1920,1080], [900,700], [390,844], [844,390]];
  const longForm = process.env.TYCHO_REMOTE_UI_INQUIRY_LONG_FORM === "1";
  const results = [];
  let index = 0;
  const frame = page => page.evaluate(() => new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve))));
  const measure = page => page.evaluate(() => {
    const rect = e => e?.getBoundingClientRect().toJSON();
    const root = document.querySelector('[data-agent-workspace]');
    const form = document.querySelector('#inquiry-form,#composer');
    const banner = document.querySelector('.inquiry-banner');
    const dock = document.querySelector('[data-agent-dock]');
    return { header: rect(document.querySelector('.app-header')), root: rect(root), dock: rect(dock), dockScrollHeight: dock?.scrollHeight, dockClientHeight: dock?.clientHeight,
      dockOverflowY: dock && getComputedStyle(dock).overflowY,
      conversationVisibility: getComputedStyle(document.querySelector('.agent-conversation-pane')).visibility,
      composer: rect(document.querySelector('#composer')), form: rect(form), footer: rect(form.querySelector('.inquiry-footer')),
      answer: rect(document.querySelector('textarea[data-inquiry-control]')), banner: rect(banner), copy: rect(banner?.querySelector('p')), fields: rect(document.querySelector('.inquiry-fields')),
      fieldCount: document.querySelectorAll('#inquiry-form .inquiry-field').length,
      actions: rect(form.querySelector('.send-row')), modal: Boolean(form.dataset.editorModal !== undefined),
      inert: document.querySelector('.app-header').inert, overflow: document.documentElement.scrollWidth > innerWidth + 1,
      peers: [...document.querySelectorAll('[data-side-kind]')].filter(e => e.getClientRects().length).map(e => ({kind:e.dataset.sideKind, ...rect(e)})),
      viewport: {width:innerWidth,height:innerHeight}, active: document.activeElement?.getAttribute('aria-label') };
  });
  const bannerFits = g => {
    if (g.banner) assert(g.banner.height <= Math.max(58, g.copy.height + 24) + 2, `banner must use intrinsic copy height: ${JSON.stringify(g)}`);
    assert(!g.overflow, "no document horizontal overflow");
  };
  const actionsReachable = async (page, expanded) => {
    const button = page.locator('#inquiry-form button[type=submit],#composer button[type=submit]').first();
    await button.scrollIntoViewIfNeeded();
    const g = await button.evaluate(e => {const b=e.getBoundingClientRect();return {box:b.toJSON(),hit:e.contains(document.elementFromPoint(b.x+b.width/2,b.y+b.height/2)),height:innerHeight};});
    assert(g.box.top >= -1 && g.box.bottom <= g.height + 1 && g.hit, `action must remain reachable: ${JSON.stringify(g)}`);
  };
  const wheelScrollReachesAnswer = async page => {
    const dock = page.locator('[data-agent-dock]');
    const before = await dock.evaluate(e => ({ scrollTop: e.scrollTop, overflowY: getComputedStyle(e).overflowY }));
    assert.equal(before.overflowY, 'auto', `expanded inquiry dock must allow user scrolling: ${JSON.stringify(before)}`);
    assert.equal(before.scrollTop, 0, 'wheel regression starts at the top of the answer form');
    const footer = page.locator('#inquiry-form .inquiry-footer');
    const box = await dock.boundingBox();
    await page.mouse.move(box.x + box.width / 2, box.y + box.height / 2);
    let scrollTop = 0;
    for (let i = 0; i < 24 && scrollTop === 0; i++) {
      await page.mouse.wheel(0, 300);
      await page.waitForTimeout(30);
      scrollTop = await dock.evaluate(e => e.scrollTop);
    }
    assert(scrollTop > 0, 'a real mouse wheel event scrolls the long answer form');
    for (let i = 0; i < 24; i++) {
      const visible = await footer.evaluate(e => { const r=e.getBoundingClientRect(); return r.bottom <= innerHeight && r.top >= 0; });
      if (visible) break;
      await page.mouse.wheel(0, 300);
      await page.waitForTimeout(30);
    }
    const result = await footer.evaluate(e => {
      const r=e.getBoundingClientRect();
      return { top:r.top, bottom:r.bottom, height:innerHeight, visible:r.bottom <= innerHeight && r.top >= 0 };
    });
    assert(result.visible, `mouse wheel reaches the answer footer: ${JSON.stringify(result)}`);
    return { ...before, scrollTop: await dock.evaluate(e => e.scrollTop), footer: result };
  };
  const assertPanel = (before, after) => {
    assert(!after.modal && !after.inert, "panel expansion must leave header and peers interactive");
    assert(Math.abs(after.dock.width-before.dock.width)<1.1 && Math.abs(after.dock.x-before.dock.x)<1.1, "expansion must preserve panel width and column");
    assert(Math.abs(after.header.height-before.header.height)<1.1 && Math.abs(after.header.bottom-before.header.bottom)<1.1, "header geometry stays unchanged");
    assert(after.form.top >= after.header.bottom-1, "editor stays below header");
    assert(after.dock.bottom <= after.root.bottom + 1,
      `expanded editor stays inside its workspace: ${JSON.stringify({dock:after.dock,root:after.root})}`);
    assert.deepEqual(after.peers.map(p=>[p.kind,p.x,p.width,p.height]),before.peers.map(p=>[p.kind,p.x,p.width,p.height]), "peer geometry stays unchanged");
  };
  for (const [width,height] of layouts) for (const theme of ["dark","light"]) for (const long of [false,true]) {
    const key=`web-inquiry-recovery-${index++}`;
    const context=await browser.newContext({viewport:{width,height},deviceScaleFactor:width===1260?1.5:1,isMobile:width<900,hasTouch:width<900});
    const page=await context.newPage();
    const errors=[];page.on('pageerror',e=>errors.push(e.message));
    const agent=(await (await context.request.get(`${baseUrl}/agents/${key}`)).json()).agent;
    assert(agent.latest_inquiry?.id,"use a persisted isolated inquiry, not a DOM-only form");
    if (longForm) assert(agent.latest_inquiry.fields.length >= 10, `long form fixture has enough persisted fields: ${agent.latest_inquiry.fields.length}`);
    assert.equal(agent.latest_inquiry.message.length>200,long);
    await page.goto(`${baseUrl}/ui#agent/${key}/summary`,{waitUntil:'networkidle'});
    await page.evaluate(theme=>window.TychoAppearance.setPreference(theme),theme);
    await page.locator('#inquiry-form').waitFor({state:'attached'});
    if (key === 'web-inquiry-recovery-0' && !longForm) {
      const upload=await context.request.post(`${baseUrl}/agents/${key}/messages`,{data:{prompt:'Panel attachment fixture',start:false,attachments:[{filename:'panel.md',content_type:'text/markdown',content_base64:Buffer.from('# Attachment stays in its own panel').toString('base64')}]}});
      assert(upload.ok(),await upload.text());
      advanceInquiry(key);
      const detail=(await (await context.request.get(`${baseUrl}/agents/${key}`)).json()).agent;
      const file=detail.attachments.at(-1),focus=(await (await context.request.get(`${baseUrl}/agents/${key}/focus`)).json()).focus;
      const saved=await context.request.put(`${baseUrl}/agents/${key}/focus`,{data:{revision:focus.revision,sections:[{title:'Context',items:[{title:'Keep the source',attachments:[{type:'file',title:'Panel file',path:file.path}]}]}]}});
      assert(saved.ok(),await saved.text());await page.evaluate(()=>refresh({force:true}));
      await page.locator('.side-conversation-controls [data-side-conversation="focus"]:visible').click();
      await page.locator('.agent-focus-attachments a[data-preview-summary-attachment]').click();
      await page.locator('.summary-attachment-preview-scroll[aria-busy="false"]').waitFor({state:'visible'});
      assert.deepEqual(await page.locator('[data-side-kind]').evaluateAll(es=>es.map(e=>e.dataset.sideKind)),['focus','attachment']);
    }
    const disclosure=page.locator('.mobile-inquiry > summary .mobile-inquiry-summary-copy');
    if(await disclosure.count()) await disclosure.click();
    const answer='Retain this answer and its exact draft.\n'.repeat(15);
    await page.locator('#inquiry-form textarea[data-inquiry-control]').first().fill(answer);
    await page.locator('#inquiry-feedback').fill('Keep this feedback through layout and polling.');
    await frame(page);
    await page.locator('[data-agent-dock]').evaluate(e=>{e.scrollTop=0});
    const normal=await measure(page);bannerFits(normal);
    if(captureDir && !longForm && theme==='light' && [1260,390].includes(width)) {
      fs.mkdirSync(captureDir,{recursive:true});
      await page.screenshot({path:path.join(captureDir,`inquiry-normal-short-${width}-${browser.browserType().name()}.png`)});
    }
    assert(normal.header.height<140, "matching landscape header is content-sized");
    const toggle=page.locator('[data-toggle-inquiry-full-screen]');
    if(width>=900) {
      assert.match(await toggle.getAttribute('aria-label'),/panel height/);
      assert((await toggle.innerHTML()).includes('M12 2v20'),"vertical expansion icon");
    }
    await toggle.click();await frame(page);
    if (process.env.TYCHO_REMOTE_UI_INQUIRY_BASELINE === "1" && width === 1260 && !long && longForm) {
      await page.addStyleTag({content: `@media (min-width:900px) {
        .agent-workspace:not(.agent-workspace-full-view) .agent-dock:has(.inquiry-form-full-height, .composer-full-height) { overflow:hidden; }
      }`});
      await frame(page);
    }
    const expanded=await measure(page);bannerFits(expanded);
    if(width>=900) {
      if (!longForm) assertPanel(normal,expanded);
      assert.equal(expanded.conversationVisibility, 'visible', 'full-height editor keeps the Conversation pane visible');
      if(captureDir && process.env.TYCHO_REMOTE_UI_INQUIRY_BASELINE === "1" && width===1260 && !long && !longForm) {
        fs.mkdirSync(captureDir,{recursive:true});
        await page.screenshot({path:path.join(captureDir,"inquiry-before-oversized-desktop.png")});
        fs.writeFileSync(path.join(captureDir,"inquiry-before-geometry.json"),JSON.stringify({normal:normal.answer,expanded:expanded.answer,form:expanded.form,composer:expanded.composer},null,2));
      }
      assert(expanded.answer.height <= normal.answer.height + 1, `answer textarea keeps its normal height: ${JSON.stringify({normal:normal.answer,expanded:expanded.answer})}`);
      assert(expanded.footer && expanded.footer.y >= expanded.fields.bottom - 1,
        `answer actions follow the answer fields: ${JSON.stringify({fields:expanded.fields,footer:expanded.footer})}`);
      if (longForm) assert(expanded.dockScrollHeight > expanded.dockClientHeight && expanded.form.bottom > expanded.viewport.height,
        `long answer form scrolls naturally below the fold: ${JSON.stringify(expanded)}`);
      if (longForm && width === 1260 && !long && theme === 'light') {
        expanded.wheel = await wheelScrollReachesAnswer(page);
        if (captureDir) await page.screenshot({path:path.join(captureDir,`inquiry-expanded-long-desktop-wheel-footer-${browser.browserType().name()}.png`)});
      }
    }
    else assert(expanded.modal&&expanded.inert,"small screens retain accessible modal editing");
    await actionsReachable(page,true);
    if (width===1260 && theme==='light' && !long && !longForm) {
      await page.locator('[data-focused-view-menu] > summary').click();
      await page.locator('[data-view-mode="full"]').click();await frame(page);
      assert(await page.locator('[data-side-kind="summary"]').isVisible(),'Summary Full View remains visible while an editor expansion is saved');
      assert.equal(await page.locator('[data-agent-dock]').isVisible(),false,'Detail only does not overlay Summary with the answer editor');
      await page.locator('[data-focused-view-menu] > summary').click();await page.locator('[data-view-mode="balanced"]').click();await frame(page);
      assertPanel(normal,await measure(page));
    }
    assert.equal(await page.locator('#inquiry-form textarea[data-inquiry-control]').first().inputValue(),answer);
    await page.locator('[data-agent-dock]').evaluate(e=>{e.scrollTop=0});
    await page.locator('#inquiry-form textarea[data-inquiry-control]').first().focus();
    const focusedAnswerName=await page.locator('#inquiry-form textarea[data-inquiry-control]').first().getAttribute('name');
    await frame(page);
    await page.evaluate(()=>refresh({force:true}));await frame(page);
    assert.equal(await page.evaluate(()=>document.activeElement?.getAttribute('name')),focusedAnswerName,'focused answer remains focused during polling');
    const polled=await measure(page);bannerFits(polled);
    if(width>=900 && !longForm) assertPanel(normal,polled);
    if(width>=900) {
      assert(polled.answer.height <= normal.answer.height + 1, `polling keeps answer textarea size: ${JSON.stringify(polled)}`);
      assert(polled.footer && polled.footer.y >= polled.fields.bottom - 1, `polling keeps answer actions after fields: ${JSON.stringify(polled)}`);
    }
    assert.equal(await page.locator('#inquiry-feedback').inputValue(),'Keep this feedback through layout and polling.');
    if(width===1260 && !longForm) {
      await page.setViewportSize({width:390,height:844});await frame(page);
      assert(await page.locator('#inquiry-form.inquiry-form-full-screen').isVisible(),'resize to mobile switches the expanded answer into its modal');
      assert.equal(await page.locator('#inquiry-form textarea[data-inquiry-control]').first().inputValue(),answer,'mobile resize keeps the answer draft');
      await page.setViewportSize({width:1260,height:875});await frame(page);
      assert(await page.locator('#inquiry-form.inquiry-form-full-height').isVisible(),'resize to desktop restores panel expansion');
      assert.equal(await page.locator('#inquiry-form textarea[data-inquiry-control]').first().inputValue(),answer,'desktop resize keeps the answer draft');
    }
    if(captureDir && theme==='light' && [1260,1920,390].includes(width)) {
      fs.mkdirSync(captureDir,{recursive:true});
      await page.screenshot({path:path.join(captureDir,`inquiry-expanded-${longForm?'long':'short'}-${width}-${browser.browserType().name()}.png`)});
    }
    await page.keyboard.press('Escape');await frame(page);
    const collapsed=await measure(page);bannerFits(collapsed);
    assert(!collapsed.modal&&!collapsed.inert);
    assert.equal(await page.locator('#inquiry-form textarea[data-inquiry-control]').first().inputValue(),answer);
    await actionsReachable(page,false);
    if(width===1260 && !long && !longForm && theme==='light' && captureDir) {
      await page.locator('[data-agent-dock]').evaluate(e=>{e.scrollTop=0});
      await page.screenshot({path:path.join(captureDir,`inquiry-compact-tablet-${browser.browserType().name()}.png`)});
    }
    // Spare allocated height must never stretch the warning banner into a blank surface.
    if(width===1260 && !long && !longForm) {
      await page.locator('#inquiry-form').evaluate(e=>{e.style.height='1800px'});await frame(page);bannerFits(await measure(page));
      await page.locator('#inquiry-form').evaluate(e=>e.style.removeProperty('height'));
    }
    results.push({kind:'inquiry',width,height,theme,long,normal,expanded,collapsed});
    assert.deepEqual(errors,[]);await context.close();
  }
  for (const [width,height] of layouts) for (const theme of ['dark','light']) {
    const context=await browser.newContext({viewport:{width,height},isMobile:width<900,hasTouch:width<900});
    const response=await context.request.post(`${baseUrl}/agents`,{data:{project_key:'web',template_key:'custom',name:'Panel editor fixture',prompt:'Draft fixture',start:false}});
    assert(response.ok(),await response.text());const key=(await response.json()).agent.key;
    const page=await context.newPage();await page.goto(`${baseUrl}/ui#agent/${key}/summary`,{waitUntil:'networkidle'});
    await page.evaluate(theme=>window.TychoAppearance.setPreference(theme),theme);
    const draft='Retain the multiline prompt draft.\n'.repeat(70);await page.locator('#prompt-input').fill(draft);await frame(page);
    const normal=await measure(page);await page.locator('[data-toggle-composer-full-screen]').click();await frame(page);
    const expanded=await measure(page);
    if(width>=900) {assertPanel(normal,expanded);assert.match(await page.locator('[data-toggle-composer-full-screen]').getAttribute('aria-label'),/Collapse editor/);}
    else assert(expanded.modal&&expanded.inert);
    await actionsReachable(page,true);
    assert.equal(await page.locator('#prompt-input').inputValue(),draft);
    await page.evaluate(()=>refresh({force:true}));await frame(page);assert.equal(await page.locator('#prompt-input').inputValue(),draft);
    if(captureDir&&width===1260&&theme==='light') await page.screenshot({path:path.join(captureDir,`prompt-panel-expanded-${browser.browserType().name()}.png`)});
    if(width===1920&&theme==='dark') {
      await page.setViewportSize({width:844,height:390});await frame(page);assert((await measure(page)).modal,"resize into small screen uses modal");
      await page.setViewportSize({width:1260,height:875});await frame(page);assert(!(await measure(page)).modal,"resize back restores panel expansion");
      assert.equal(await page.locator('#prompt-input').inputValue(),draft);
    }
    await page.keyboard.press('Escape');await frame(page);assert(!(await measure(page)).modal);assert.equal(await page.locator('#prompt-input').inputValue(),draft);
    results.push({kind:'composer',width,height,theme,normal,expanded});await context.close();
  }
  // A real inquiry submission moves through failed answer recovery, retry and accepted state.
  const recoveryContext=await browser.newContext({viewport:{width:1260,height:875}});
  const recoveryPage=await recoveryContext.newPage(),recoveryKey='web-inquiry-recovery-60';
  await recoveryPage.goto(`${baseUrl}/ui#agent/${recoveryKey}/summary`,{waitUntil:'networkidle'});
  await recoveryPage.locator('#inquiry-form textarea[data-inquiry-control]').first().fill('A real isolated answer');
  await recoveryPage.locator('[data-toggle-inquiry-full-screen]').click();await frame(recoveryPage);
  const failedPattern=new RegExp(`/agents/${recoveryKey}/inquiries/[^/]+/answer$`);
  await recoveryPage.route(failedPattern,route=>route.fulfill({status:503,contentType:'application/json',body:JSON.stringify({error:'Synthetic unavailable answer service'})}));
  await recoveryPage.locator('#inquiry-form button[type=submit]').click();
  await recoveryPage.locator('[data-inquiry-answer-recovery]').waitFor({state:'visible'});await frame(recoveryPage);
  bannerFits(await measure(recoveryPage));await actionsReachable(recoveryPage,true);
  assert.equal(await recoveryPage.locator('#inquiry-form textarea[data-inquiry-control]').first().inputValue(),'A real isolated answer');
  await recoveryPage.locator('[data-toggle-inquiry-full-screen]').click();await frame(recoveryPage);
  await recoveryPage.evaluate(()=>refresh({force:true}));await frame(recoveryPage);
  assert(await recoveryPage.locator('.inquiry-form-full-height').isVisible(),'failed-answer panel expansion survives polling');
  await recoveryPage.unroute(failedPattern);
  await recoveryPage.locator('#inquiry-form button[type=submit]').click();
  await recoveryPage.locator('#composer').waitFor({state:'visible'});
  const composerPlacement = await recoveryPage.locator('#composer').evaluate(e => {
    const dock = document.querySelector('[data-agent-dock]');
    const box = e.getBoundingClientRect();
    return { inDock: dock.contains(e), top: box.top, bottom: box.bottom, viewportHeight: innerHeight };
  });
  assert(composerPlacement.inDock, `conversation composer follows the accepted answer in the dock: ${JSON.stringify(composerPlacement)}`);
  let composerVisible = composerPlacement.top >= 0 && composerPlacement.bottom <= composerPlacement.viewportHeight;
  for (let i = 0; i < 12 && !composerVisible; i++) {
    await recoveryPage.mouse.move(600, 400);
    await recoveryPage.mouse.wheel(0, 250);
    await recoveryPage.waitForTimeout(30);
    composerVisible = await recoveryPage.locator('#composer').evaluate(e => {
      const box=e.getBoundingClientRect(); return box.top >= 0 && box.bottom <= innerHeight;
    });
  }
  assert(composerVisible, 'the conversation composer is reachable after the answer is accepted');
  if(waitForInquiryRuns) waitForInquiryRuns();
  assert.equal(await recoveryPage.locator('[data-editor-modal]').count(),0);
  await recoveryContext.close();
  if(captureDir)fs.writeFileSync(path.join(captureDir,'panel-editor-geometry.json'),JSON.stringify(results,null,2));
  console.log(JSON.stringify({engine:browser.browserType().name(),inquiryCases:24,composerCases:12,spareHeightProbe:true,attachmentPeers:true,answerRecoveryAndRetry:true}));
};
