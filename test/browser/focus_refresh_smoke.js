const clickFocusAction = require("./focus_menu_actions");
const assert=require('node:assert/strict');const fs=require('node:fs');const path=require('node:path');
module.exports=async({browser,baseUrl,agentKey,captureDir})=>{
 const api=await browser.newContext();
 const save=async title=>{const focus=(await(await api.request.get(`${baseUrl}/agents/${agentKey}/focus`)).json()).focus;const r=await api.request.put(`${baseUrl}/agents/${agentKey}/focus`,{data:{revision:focus.revision,sections:[{title:'Reading',items:Array.from({length:24},(_,i)=>({title:`${title}: item ${i+1}`,attachments:i===0&&attachment?[{type:'file',title:'Retained preview',path:attachment.path}]:[]}))},{title:'Choices',items:[{title:'Keep this choice'}]}]}});assert(r.ok(),await r.text());};
 const upload=await api.request.post(`${baseUrl}/agents/${agentKey}/messages`,{data:{prompt:'Synthetic attachment state',start:false,attachments:[{filename:'focus-refresh.txt',content_type:'text/plain',content_base64:Buffer.from('Retain this attachment preview').toString('base64')}]}});assert(upload.ok());
 const attachment=(await(await api.request.get(`${baseUrl}/agents/${agentKey}`)).json()).agent.attachments[0];
 const peerResponse=await api.request.post(`${baseUrl}/agents`,{data:{project_key:'web',template_key:'custom',name:'Other Focus agent',prompt:'Synthetic navigation target',start:false}});assert(peerResponse.ok());const peer=(await peerResponse.json()).agent;
 const peerFocus=(await(await api.request.get(`${baseUrl}/agents/${peer.key}/focus`)).json()).focus;assert((await api.request.put(`${baseUrl}/agents/${peer.key}/focus`,{data:{revision:peerFocus.revision,sections:[{title:'Other agent',items:[{title:'Keep this separate Focus'}]}]}})).ok());
 const results=[];
 for(const width of [1920,1000,390])for(const theme of ['dark','light']){
  await save('Original');const context=await browser.newContext({viewport:{width,height:900},hasTouch:width<900,isMobile:width<900});const page=await context.newPage();const errors=[];page.on('pageerror',e=>errors.push(e.message));let focusReads=0,peerReads=0;
  page.on('request',r=>{if(new URL(r.url()).pathname.endsWith(`/agents/${peer.key}/focus`)&&r.method()==='GET')peerReads++;if(new URL(r.url()).pathname.endsWith(`/agents/${agentKey}/focus`)&&r.method()==='GET')focusReads++;});
  await page.goto(`${baseUrl}/ui#agent/${agentKey}`,{waitUntil:'networkidle'});await page.evaluate(theme=>window.TychoAppearance.setPreference(theme),theme);
  const panel=page.locator('[data-agent-focus]');for(let i=0;i<2&&!await panel.isVisible();i++)await page.locator('[data-side-conversation="focus"]').click();await panel.waitFor({state:'visible'});
  await page.locator('#prompt-input').fill('Retain this refresh draft');await clickFocusAction(page.locator('[data-focus-section]').nth(1));
  await page.locator('.agent-focus-scroll').evaluate(e=>e.scrollTop=160);
  await page.evaluate(()=>{window.retainedFocus=document.querySelector('[data-agent-focus]');window.retainedFocusScroll=document.querySelector('.agent-focus-scroll').scrollTop;});
  const reads=focusReads;await save('Background update');
  await page.evaluate(async()=>{await refresh({force:true});await pollAgentActivity({manual:true});});
  assert(await panel.textContent().then(s=>s.includes('Original: item 1')&&!s.includes('Background update')),'background polling must not refresh Focus data');
  assert(await panel.evaluate(e=>e===window.retainedFocus),'background polling must retain the actual Focus node');
  assert.equal(focusReads,reads,'background polling must not request Focus');
  assert(await page.evaluate(key=>state.agentDetails[key]?.focus?.sections?.[0]?.items?.[0]?.title==='Background update: item 1',agentKey),'agent detail updates while displayed Focus remains frozen');
  assert.equal(await page.locator('[data-focus-section]').nth(1).getAttribute('aria-expanded'),'false');
  assert(await page.locator('.agent-focus-scroll').evaluate(e=>Math.abs(e.scrollTop-window.retainedFocusScroll)<1.1),'polling retains Focus scroll');
  const refreshButton=page.locator('[data-refresh-focus]'),bulk=page.locator('[data-focus-bulk]');
  assert.equal((await refreshButton.textContent()).trim(),'');assert.equal(await refreshButton.getAttribute('aria-label'),'Refresh Focus');assert.equal(await refreshButton.getAttribute('title'),'Refresh Focus');assert.equal((await bulk.textContent()).trim(),'');assert.equal(await bulk.getAttribute('aria-label'),'Collapse all');
  let release;const held=new Promise(r=>release=r);await page.route(`**/agents/${agentKey}/focus`,async route=>{if(route.request().method()==='GET'){await held;}await route.continue();});
  await refreshButton.press('Enter');await page.waitForFunction(()=>document.querySelector('[data-refresh-focus]')?.getAttribute('aria-busy')==='true');if(captureDir){fs.mkdirSync(captureDir,{recursive:true});await page.screenshot({path:path.join(captureDir,`focus-refresh-loading-${width}-${theme}.png`)});}assert(await panel.textContent().then(s=>s.includes('Original: item 1')),'loading retains content');await page.evaluate(()=>{window.joinedFocusRefresh=refreshAgentFocus(parseRoute().key);});assert.equal(focusReads,reads+1,'concurrent manual refreshes share one Focus request');await page.evaluate(()=>refresh({force:true}));release();
  await page.waitForFunction(()=>document.querySelector('[data-agent-focus]')?.textContent.includes('Background update: item 1'));await page.unroute(`**/agents/${agentKey}/focus`);
  assert(await refreshButton.evaluate(e=>e===document.activeElement),'keyboard refresh retains focus');
  assert.equal(await page.locator('[data-focus-section]').nth(1).getAttribute('aria-expanded'),'false');
  await page.route(`**/agents/${agentKey}/focus`,route=>route.fulfill({status:503,contentType:'application/json',body:JSON.stringify({error:'Synthetic Focus read failed'})}));
  await refreshButton.click();await page.locator('[data-focus-refresh-error]').waitFor({state:'visible'});assert(await panel.textContent().then(s=>s.includes('Background update: item 1')));assert.equal(await refreshButton.isEnabled(),true);
  if(captureDir){fs.mkdirSync(captureDir,{recursive:true});await page.screenshot({path:path.join(captureDir,`focus-refresh-error-${width}-${theme}.png`)});}
  await page.unroute(`**/agents/${agentKey}/focus`);await save('Manual fetch');
  await page.evaluate(()=>{
    window.scrollTo(0,0);
    const touch=(name,y)=>{const event=new Event(name,{bubbles:true});Object.defineProperty(event,'touches',{value:y===null?[]:[{clientY:y}]});window.dispatchEvent(event);};
    touch('touchstart',0);touch('touchmove',180);touch('touchend',null);
  });await page.waitForFunction(()=>document.querySelector('[data-agent-focus]')?.textContent.includes('Manual fetch: item 1'));
  assert.equal(await page.locator('[data-focus-refresh-error]').count(),0);
  assert.equal(await page.locator('[data-focus-section]').nth(1).getAttribute('aria-expanded'),'false');
  // A real file preview remains selected and its Focus source remains intact across global polling.
  await page.locator('.agent-focus-scroll').evaluate(e=>e.scrollTop=0);
  await panel.locator('button[data-preview-summary-attachment]').first().press('Space');
  await page.locator('.summary-attachment-preview-scroll[aria-busy="false"]').waitFor({state:'visible'});
  const preview=await page.evaluate(()=>state.summaryAttachmentPreview.id);
  await save('Preview background');await page.evaluate(()=>refresh({force:true}));
  assert.equal(await page.evaluate(()=>state.summaryAttachmentPreview?.id),preview);
  assert(await panel.textContent().then(s=>s.includes('Manual fetch: item 1')&&!s.includes('Preview background')));
  for(let i=0;i<2&&!await panel.isVisible();i++)await page.locator('[data-side-conversation="focus"]').click();await panel.waitFor({state:'visible'});

  await bulk.press('Space');assert.equal(await bulk.getAttribute('aria-label'),'Expand all');assert((await page.locator('[data-focus-section]').evaluateAll(es=>es.every(e=>e.getAttribute('aria-expanded')==='false'))));
  if(captureDir)await page.screenshot({path:path.join(captureDir,`focus-refresh-collapsed-${width}-${theme}.png`)});
  await bulk.press('Enter');assert.equal(await bulk.getAttribute('aria-label'),'Collapse all');assert((await page.locator('[data-focus-section]').evaluateAll(es=>es.every(e=>e.getAttribute('aria-expanded')==='true'))));
  let releaseDetail,detailStarted;const detailHeld=new Promise(r=>releaseDetail=r),detailSeen=new Promise(r=>detailStarted=r);
  await page.route(`**/agents/${agentKey}`,async route=>{const response=await route.fetch();detailStarted();await detailHeld;await route.fulfill({response});});
  await page.evaluate(key=>{window.olderAgentDetail=ensureAgentDetail(key,true);},agentKey);await detailSeen;
  await save('Newest explicit Focus');await refreshButton.click();await page.waitForFunction(()=>document.querySelector('[data-agent-focus]')?.textContent.includes('Newest explicit Focus: item 1'));
  releaseDetail();await page.evaluate(async()=>{await window.olderAgentDetail;render();});await page.unroute(`**/agents/${agentKey}`);
  assert(await panel.textContent().then(s=>s.includes('Newest explicit Focus: item 1')),'older agent detail cannot replace newer manual Focus');
  if(width<900)await page.locator('.side-conversation-controls [data-side-conversation="conversation"]').click();
  const beforeManualFetch=await page.evaluate(()=>state.summaryAttachmentPreview?.id);
  await save('Agent fetch latest');
  const message=await api.request.post(`${baseUrl}/agents/${agentKey}/messages`,{data:{prompt:'Synthetic new conversation item for manual fetch',start:false}});assert(message.ok());
  await page.evaluate(()=>refresh({force:true}));
  const fetchMessages=page.locator('[data-load-pending-conversation]');await fetchMessages.waitFor({state:'visible'});await fetchMessages.click();
  await page.waitForFunction(()=>document.querySelector('[data-agent-focus]')?.textContent.includes('Agent fetch latest: item 1'));
  assert.equal(await page.evaluate(()=>state.summaryAttachmentPreview?.id),beforeManualFetch,'manual agent fetch retains attachment selection');
  assert.equal(await page.locator('#prompt-input').inputValue(),'Retain this refresh draft');assert.equal(await page.evaluate(()=>document.documentElement.scrollWidth>innerWidth+1),false);
  for(let i=0;i<2&&!await panel.isVisible();i++)await page.locator('[data-side-conversation="focus"]').click();await panel.waitFor({state:'visible'});
  if(captureDir)await page.screenshot({path:path.join(captureDir,`focus-refresh-ready-${width}-${theme}.png`)});
  if(width===1920&&theme==='dark'){
    let releaseCatalog,catalogStarted;const hold=new Promise(r=>releaseCatalog=r),started=new Promise(r=>catalogStarted=r);
    await page.route('**/servers/resources',async route=>{const response=await route.fetch();catalogStarted();await hold;await route.fulfill({response});});
    await page.evaluate(()=>{window.previousRouteRefresh=refresh({force:true,refreshFocus:true});});await started;
    await page.evaluate(key=>navigate({type:'agent',key}),peer.key);await page.waitForFunction(()=>document.querySelector('[data-agent-focus]')?.textContent.includes('Keep this separate Focus'));
    await page.evaluate(()=>window.otherFocusNode=document.querySelector('[data-agent-focus]'));
    releaseCatalog();await page.evaluate(()=>window.previousRouteRefresh);await page.unroute('**/servers/resources');
    assert.equal(peerReads,0,'a manual refresh started before navigation must not fetch the new agent Focus');
    assert(await page.locator('[data-agent-focus]').evaluate(e=>e===window.otherFocusNode),'navigation target retains its Focus node');
  }
  assert.deepEqual(errors,[]);results.push({width,theme,focusReads});await context.close();
 }
 await api.close();if(captureDir)fs.writeFileSync(path.join(captureDir,'focus-refresh-results.json'),JSON.stringify(results,null,2));console.log(JSON.stringify({engine:browser.browserType().name(),cases:results.length}));
};
