const assert=require('node:assert/strict');
const fs=require('node:fs');
const path=require('node:path');
module.exports=async({browser,baseUrl,agentKey,captureDir})=>{
  const api=await browser.newContext();
  for(let i=0;i<5;i++){
    const r=await api.request.post(`${baseUrl}/agents/${agentKey}/messages`,{data:{prompt:'Synthetic menu overlap fixture',start:false,attachments:Array.from({length:4},(_,j)=>({filename:`evidence-${i*4+j}.txt`,content_type:'text/plain',content_base64:Buffer.from('Synthetic evidence').toString('base64'),title:`Evidence ${i*4+j+1}: long menu title for overlap and scrolling`,url:`https://example.test/evidence/${i*4+j}`}))}});assert(r.ok(),await r.text());
  }
  const child=await api.request.post(`${baseUrl}/agents`,{data:{project_key:'web',template_key:'custom',name:'Linked fixture child',prompt:'Synthetic menu fixture',parent_agent_key:agentKey,start:false}});assert(child.ok(),await child.text());
  const focus=(await(await api.request.get(`${baseUrl}/agents/${agentKey}/focus`)).json()).focus;
  assert((await api.request.put(`${baseUrl}/agents/${agentKey}/focus`,{data:{revision:focus.revision,sections:[{title:'Peer panel',items:[{title:'Keep this peer accessible'}]}]}})).ok());
  const results=[];
  for(const [width,height] of [[1920,1000],[1440,900],[900,700],[390,844],[844,390]])for(const theme of ['dark','light']){
    const context=await browser.newContext({viewport:{width,height},hasTouch:width<900,isMobile:width<900});const page=await context.newPage();const errors=[];page.on('pageerror',e=>errors.push(e.message));
    await page.goto(`${baseUrl}/ui#agent/${agentKey}`,{waitUntil:'networkidle'});await page.evaluate(theme=>window.TychoAppearance.setPreference(theme),theme);
    await page.locator('#prompt-input').fill('Retain this long draft\n'.repeat(40));
    if(width>=900&&await page.locator('[data-side-conversation="focus"]').getAttribute('aria-pressed')!=='true')await page.locator('[data-side-conversation="focus"]').click();
    for(const [name,trigger,flyout] of [['attachments','[data-toggle-attachments]','[data-attachment-flyout]'],['linked','[data-toggle-linked-agents]','[data-linked-agents-flyout]'],['skills','[data-toggle-skills]','[data-skill-flyout]']]){
      const open=async()=>{if(await page.locator(flyout).evaluate(e=>e.classList.contains('hidden')))await page.locator(trigger).click();await page.locator(flyout).waitFor({state:'visible'});};
      await open();
      const measure=async()=>page.locator(flyout).evaluate(e=>{
        const r=e.getBoundingClientRect(),dock=e.closest('[data-agent-dock]').getBoundingClientRect();
        const points=[[r.left+12,r.top+12],[r.right-12,r.top+12],[r.left+12,r.bottom-12],[r.right-12,r.bottom-12]];
        return {rect:{x:r.x,y:r.y,width:r.width,height:r.height,bottom:r.bottom},dockTop:dock.top,hit:points.every(([x,y])=>e.contains(document.elementFromPoint(x,y))),overflow:document.documentElement.scrollWidth>innerWidth,ancestors:[...function*(n){while(n){const s=getComputedStyle(n);yield `${n.className}:overflow=${s.overflow},z=${s.zIndex}`;n=n.parentElement}}(e)].slice(0,7)};
      });
      const facts=await measure();
      if(captureDir){fs.mkdirSync(captureDir,{recursive:true});await page.screenshot({path:path.join(captureDir,`menu-${name}-${width}-${height}-${theme}.png`)});}
      assert(facts.hit,JSON.stringify({width,height,theme,name,...facts}));assert(!facts.overflow);
      await page.setViewportSize({width:width+16,height});assert((await measure()).hit,'viewport resizing keeps menu anchored');await page.setViewportSize({width,height});
      await page.evaluate(()=>refresh({force:true}));assert((await measure()).hit,'polling retains visible, hit-testable flyout');
      if(name==='attachments'){
        await page.locator(`${flyout} [data-attachment-type-filter]`).first().click();assert((await measure()).hit,'filter click remains above conversation');
        const download=page.waitForEvent('download');await page.locator(`${flyout} [data-download-attachment]`).first().click();assert.equal(fs.readFileSync(await(await download).path(),'utf8'),'Synthetic evidence');
        await open();await page.locator(`${flyout} [data-delete-attachment]`).first().click();const dialog=page.locator('#confirmation-dialog');await dialog.waitFor({state:'visible'});
        assert(await dialog.evaluate(e=>{const r=e.getBoundingClientRect();return e.contains(document.elementFromPoint(r.left+r.width/2,r.top+r.height/2))}),'confirmation modal stays above flyouts');
        await page.locator('[data-confirmation-cancel]').click();await dialog.waitFor({state:'hidden'});
        await open();
      }
      const list=page.locator(`${flyout} .attachment-list,${flyout} .linked-agents-flyout-list,${flyout} .skill-flyout-body`).first();
      if(await list.count())await list.evaluate(e=>{e.scrollTop=e.scrollHeight});
      assert((await measure()).hit,'list scroll retains layering');
      const item=page.locator(flyout).locator('button,a').first();if(await item.count())await item.focus();
      await page.keyboard.press('Escape');await page.locator(flyout).waitFor({state:'hidden'});
      assert(await page.locator(trigger).evaluate(e=>e===document.activeElement),'Escape restores trigger focus');
      await page.locator(trigger).click();await page.locator('.app-header').click({position:{x:200,y:10}});await page.locator(flyout).waitFor({state:'hidden'});
      assert.equal(await page.locator('#prompt-input').inputValue(),'Retain this long draft\n'.repeat(40));results.push({width,height,theme,name,...facts});
    }
    await page.locator('[data-toggle-composer-full-screen]').click();
    await page.locator('[data-toggle-attachments]').click();
    const expanded=page.locator('[data-attachment-flyout]');await expanded.waitFor({state:'visible'});
    assert(await expanded.evaluate(e=>{const r=e.getBoundingClientRect();return [[r.left+12,r.top+12],[r.right-12,r.bottom-12]].every(([x,y])=>e.contains(document.elementFromPoint(x,y)))}),'expanded editor flyout stays above its editor');
    await page.keyboard.press('Escape');await expanded.waitFor({state:'hidden'});
    assert.equal(await page.locator('#prompt-input').inputValue(),'Retain this long draft\n'.repeat(40));
    assert.deepEqual(errors,[]);await context.close();
  }
  await api.close();if(captureDir)fs.writeFileSync(path.join(captureDir,'menu-geometry.json'),JSON.stringify(results,null,2));console.log(JSON.stringify({engine:browser.browserType().name(),cases:results.length}));
};
