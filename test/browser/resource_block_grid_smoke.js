const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
module.exports = async ({browser,baseUrl,captureDir,metadataFixture}) => {
  const api=await browser.newContext();
  const created=[];
  for(let i=0;i<9;i++) {
    const response=await api.request.post(`${baseUrl}/agents`,{data:{project_key:i<5?'web':'grid-secondary',template_key:'custom',name:`Block ${i+1} — Long descriptive agent title with 日本語 ${'UnbrokenLabel'.repeat(4)}`,prompt:'Synthetic block grid fixture',start:false,...(i===2?{parent_agent_key:created[0].key}:{})}});
    assert(response.ok(),await response.text());created.push((await response.json()).agent);
    const schedule=await api.request.post(`${baseUrl}/schedules`,{data:{key:`grid-${i}`,name:`Schedule ${i+1} — Long recurring review ${'LongScheduleLabel'.repeat(3)}`,cron:'0 9 * * *',project_key:i<5?'web':'grid-secondary',message:'Synthetic grid schedule; do not run'}});
    assert.equal(schedule.status(),201,await schedule.text());
  }
  const storePath=path.join(metadataFixture.logsDir,'managed_agents.json');
  const stored=JSON.parse(fs.readFileSync(storePath));
  for(const item of stored) if(created.some(agent=>agent.key===item.key)) {
    item.unread=true;item.structured_result={status:'success',summary:'Completed review with retained decisions and evidence. '+ 'LongSummaryWithoutSpaces'.repeat(6)};
  }
  fs.writeFileSync(`${storePath}.grid-fixture`,JSON.stringify(stored));fs.renameSync(`${storePath}.grid-fixture`,storePath);
  const results=[];
  const widths=[320,390,899,900,901,1099,1100,1101,1439,1440,1441,1920];
  const expected=width=>width>=1440?3:width>=900?2:1;
  const routes=[{name:'now',hash:'now'},{name:'agents-flat',hash:'agents',sort:'agent_name_asc'},{name:'agents-grouped',hash:'agents',sort:'project_asc'},{name:'schedules',hash:'schedules'}];
  for(const width of widths) for(const theme of ['dark','light']) {
    const context=await browser.newContext({viewport:{width,height:1000},isMobile:width<900,hasTouch:width<900});
    const page=await context.newPage();const errors=[];page.on('pageerror',e=>errors.push(e.message));
    for(const route of routes) {
      await page.goto(`${baseUrl}/ui#${route.hash}`,{waitUntil:'networkidle'});
      await page.locator('.resource-block-grid').first().waitFor();
      await page.evaluate(({sort,theme})=>{window.TychoAppearance.setPreference(theme);if(sort){state.agentSort=sort;setSessionStorageValue(AGENT_SORT_STORAGE_KEY,sort);renderAgents({focusFilter:false})}},{sort:route.sort,theme});
      await page.evaluate(()=>refresh({force:true}));
      const order=await page.locator('#view [data-open-agent],#view .schedule-row').evaluateAll(es=>es.map(e=>e.dataset.openAgent||e.querySelector('[data-schedule-key]')?.dataset.scheduleKey));
      if(route.name==='agents-grouped') {
        const family=page.locator(`.agent-delegation-tree:has([data-open-agent="${created[2].key}"])`);
        assert.equal(await family.count(),1,'delegated family stays in one grid cell');
        assert.deepEqual(await family.locator('[data-open-agent]').evaluateAll(es=>es.map(e=>e.dataset.openAgent)),[created[0].key,created[2].key]);
      }
      for(const rail of width>=1100?['expanded','absent']:['responsive']) {
        await page.evaluate(rail=>{
          const shell=document.querySelector('.app-shell'),view=document.querySelector('#view'),header=document.querySelector('.app-header'),nav=document.querySelector('#bottom-nav');
          if(innerWidth>=1100){shell.style.gridTemplateColumns=rail==='absent'?'minmax(0,1fr)':'144px minmax(0,1fr)';view.style.gridColumn=header.style.gridColumn=rail==='absent'?'1':'2';nav.style.display=rail==='absent'?'none':'';document.querySelector('.sidebar-settings-link').style.display=rail==='absent'?'none':'';}
        },rail);
        await page.evaluate(()=>new Promise(resolve=>requestAnimationFrame(()=>requestAnimationFrame(resolve))));
        const geometry=await page.locator('.resource-block-grid').evaluateAll(grids=>grids.map(grid=>{
          const r=grid.getBoundingClientRect(),style=getComputedStyle(grid);
          const children=[...grid.children].filter(e=>!e.matches('.group-title,.empty-row,.empty-state'));
          const box=e=>{const b=e.getBoundingClientRect();return {x:b.x,y:b.y,right:b.right,bottom:b.bottom,width:b.width,height:b.height,overflow:e.scrollWidth>e.clientWidth+1}};
          return {width:r.width,x:r.x,right:r.right,columns:style.gridTemplateColumns.split(/\s+/).length,gap:parseFloat(style.columnGap),contentWidth:grid.clientWidth-parseFloat(style.paddingLeft)-parseFloat(style.paddingRight),padding:parseFloat(style.paddingLeft),cells:children.map(box),headings:[...grid.querySelectorAll(':scope > .group-title')].map(box)};
        }));
        for(const g of geometry) {
          assert.equal(g.columns,expected(width),JSON.stringify({width,route:route.name,rail,g}));
          assert.equal(g.gap,12);
          const cellWidth=(g.contentWidth-12*(expected(width)-1))/expected(width);
          g.cells.forEach((cell,i)=>{
            assert(Math.abs(cell.width-cellWidth)<1.1&&!cell.overflow,`block width/overflow: ${JSON.stringify({width,route:route.name,rail,i,cell,cellWidth})}`);
            assert(Math.abs(cell.x-(g.x+g.padding+(i%expected(width))*(cellWidth+12)))<1.1,'row-major order and left alignment');
          });
          for(const heading of g.headings) assert(Math.abs(heading.width-g.contentWidth)<1.1,'group heading spans all columns');
        }
        assert.equal(await page.evaluate(()=>document.documentElement.scrollWidth>innerWidth+1),false,'no page horizontal overflow');
        assert.deepEqual(await page.locator('#view [data-open-agent],#view .schedule-row').evaluateAll(es=>es.map(e=>e.dataset.openAgent||e.querySelector('[data-schedule-key]')?.dataset.scheduleKey)),order,'resizing and sidebar variation preserve DOM order');
        results.push({width,theme,route:route.name,rail,geometry});
        if(captureDir&&theme==='light'&&rail!=='absent'&&[1920,1100,390].includes(width)&&route.name!=='agents-flat') {
          fs.mkdirSync(captureDir,{recursive:true});await page.screenshot({path:path.join(captureDir,`blocks-${route.name}-${expected(width)}col-${browser.browserType().name()}.png`)});
        }
      }
      await page.evaluate(()=>refresh({force:true}));
      assert.deepEqual(await page.locator('#view [data-open-agent],#view .schedule-row').evaluateAll(es=>es.map(e=>e.dataset.openAgent||e.querySelector('[data-schedule-key]')?.dataset.scheduleKey)),order,`polling retains order and grouping at ${width}/${theme}/${route.name}`);
    }
    if(width===1920&&theme==='dark') {
      await page.goto(`${baseUrl}/ui#schedules`,{waitUntil:'networkidle'});await page.locator('.schedule-row').first().waitFor();
      const pause=page.locator('[data-schedule-key="grid-0"][data-schedule-action="pause"]');await pause.click();
      await page.locator('[data-schedule-key="grid-0"][data-schedule-action="resume"]').click();
      await page.locator('[data-schedule-key="grid-0"][data-schedule-action="pause"]').waitFor();
      await page.evaluate(()=>refresh({force:true}));
      const row=page.locator('.schedule-row').filter({has:page.locator('[data-schedule-key="grid-0"]')});await row.locator('.schedule-action-trigger').press('Enter');
      const edit=row.locator('[data-edit-schedule="grid-0"]');await edit.waitFor({state:'visible'});
      await page.evaluate(()=>new Promise(resolve=>requestAnimationFrame(()=>requestAnimationFrame(resolve))));
      await edit.focus();assert(await edit.evaluate(e=>e===document.activeElement));
      await edit.press('Enter');await page.locator('#schedule-form').waitFor();
      await page.goto(`${baseUrl}/ui#agents`,{waitUntil:'networkidle'});await page.locator('#agent-filter').fill('Block');
      await page.locator('.resource-block-grid [data-open-agent]').first().press('Enter');await page.locator('#prompt-input').waitFor();
    }
    assert.deepEqual(errors,[]);await context.close();
  }
  await api.close();if(captureDir)fs.writeFileSync(path.join(captureDir,'resource-grid-geometry.json'),JSON.stringify(results,null,2));
  console.log(JSON.stringify({engine:browser.browserType().name(),arrangements:results.length,breakpoints:[900,1440],gap:12,now:true,agents:true,schedules:true}));
};
