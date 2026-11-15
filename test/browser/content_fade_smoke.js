const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
module.exports = async ({browser,baseUrl,agentKey,captureDir}) => {
  const baseline = process.env.TYCHO_REMOTE_UI_FADE_BASELINE === "1";
  const context = await browser.newContext({viewport:{width:1920,height:1100},reducedMotion:"reduce",serviceWorkers:"block"});
  const page = await context.newPage(), results = [], errors = [];
  page.on("pageerror", e => errors.push(e.message));
  const route = `${baseUrl}/ui#agent/${agentKey}`;
  try {
    const focus = await context.request.get(`${baseUrl}/agents/${agentKey}/focus`);
    const saved = await focus.json();
    const put = await context.request.put(`${baseUrl}/agents/${agentKey}/focus`, {data:{revision:saved.focus.revision,sections:[{title:"Reading over a photo",subtitle:"Muted Focus labels must stay clear.",icon:"todo_working",items:[{title:"Check the content area",subtitle:"The photo belongs at the edges. Keep task details easy to read.",attachments:[{type:"link",title:"Read the fixture guide",url:"https://example.test/guide"}]}]}]}});
    assert(put.ok(),await put.text());
    await page.goto(route); await page.locator("#prompt-input").waitFor();
    await page.waitForFunction(()=>TychoBackdropImages.getState().loaded&&!TychoBackdropImages.getState().busy);
    await page.evaluate(async()=>{
      TychoAppearance.setPreference("dark");TychoAppearance.setTheme("dark","dracula");
      const url=TychoAppearance.getThemeState().examples.find(t=>t.id==="builtin:senggigi-beach").photo;
      const blob=await(await fetch(url)).blob();await TychoBackdropImages.choose(new File([blob],"Uploaded beach fixture.webp",{type:"image/webp"}));
      await TychoBackdropImages.select(TychoBackdropImages.getState().image.serverId,"light");
    });
    const themes = await page.evaluate(() => [...TychoAppearance.getThemeState().examples,{id:"dracula",mode:"dark",name:"Uploaded beach Dark",uploaded:true},{id:"nord",mode:"light",name:"Uploaded beach Light",uploaded:true}]);
    for (const width of [1920,1440,390]) {
      await page.setViewportSize({width,height:width===390?844:1100});
      for (const theme of themes) {
        await page.evaluate(t => {TychoAppearance.setPreference(t.mode);TychoAppearance.setTheme(t.mode,t.id);},theme);
        for (const screen of ["conversation","focus","settings","summary"]) {
          await page.goto(screen === "settings" ? `${baseUrl}/ui#settings` : screen === "summary" ? `${route}/summary/rich-summary` : route);
          if (screen === "settings") { await page.getByRole("button",{name:"Configuration",exact:true}).click(); await page.locator("#appearance-heading").scrollIntoViewIfNeeded(); }
          else if(screen === "summary") await page.locator("[data-agent-summary-page]").waitFor();
          else { await page.locator("#prompt-input").waitFor(); const focus=page.locator("[data-agent-focus]"); if(screen === "focus") {if(!await focus.isVisible()) await page.locator("[data-show-agent-focus]").click();await page.getByText("Check the content area",{exact:true}).waitFor();} else if(await focus.isVisible()) await page.getByRole("button",{name:"Close Focus panel",exact:true}).click(); }
          await page.waitForFunction(theme => theme.uploaded ? Boolean(TychoBackdropImages.getState().image?.url)&&document.documentElement.dataset.imageBackdrop==="ready" : TychoBackdropImages.getState().themePhoto?.id === theme.id,theme);
          await page.evaluate(async()=>{const i=new Image();i.src=(TychoBackdropImages.getState().themePhoto||TychoBackdropImages.getState().image).url;await i.decode();await Promise.all(document.getAnimations().filter(a=>Number.isFinite(a.effect.getComputedTiming().endTime)).map(a=>a.finished.catch(()=>{})));await new Promise(requestAnimationFrame);});
          const facts = await page.evaluate(() => {
            const content=document.querySelector(".content"), r=content.getBoundingClientRect();
            const nodes=[...content.querySelectorAll("p, .message-role, .field-hint, .ui-field__label, .section-label, a")].filter(n=>{const b=n.getBoundingClientRect();return b.width&&b.height&&b.bottom>100&&b.top<innerHeight-70&&n.textContent.trim()&&!n.closest("button,[hidden] ");});
            return {background:getComputedStyle(content).backgroundImage,rect:{left:r.left,right:r.right,top:r.top,bottom:r.bottom},overflow:document.documentElement.scrollWidth>innerWidth,text: nodes.slice(0,24).map(n=>({text:n.textContent.trim().slice(0,90),color:getComputedStyle(n).color})),wash:getComputedStyle(document.body,"::before").backgroundImage};
          });
          // Sample the actual background behind visible text, with glyphs hidden.
          // This catches bright photo detail under off-center labels and links.
          const samples = await page.evaluate(() => {
            const root=document.querySelector(".content"), walker=document.createTreeWalker(root,NodeFilter.SHOW_TEXT), result=[];
            while(walker.nextNode() && result.length<100){
              const node=walker.currentNode, parent=node.parentElement;
              if(!parent.checkVisibility()||!node.textContent.trim()||parent.closest("button,input,select,textarea,svg,[aria-hidden=true],.sr-only"))continue;
              const range=document.createRange();range.selectNodeContents(node);
              const rect=[...range.getClientRects()].find(r=>r.width>4&&r.height>8&&r.top>75&&r.bottom<innerHeight-70&&r.left>=0&&r.right<=innerWidth);
              if(!rect)continue;
              const x=rect.left+Math.min(rect.width/2,40),y=rect.top+rect.height/2,hit=document.elementFromPoint(x,y);
              if(!hit||!parent.contains(hit))continue;
              let opacity=1;for(let n=parent;n;n=n.parentElement)opacity*=Number(getComputedStyle(n).opacity);
              result.push({text:node.textContent.trim().slice(0,80),color:getComputedStyle(parent).color,opacity,x,y});
            }
            return result;
          });
          const hidden=await page.addStyleTag({content:".content, .content * {-webkit-text-fill-color:transparent!important;text-shadow:none!important;caret-color:transparent!important;}"});
          const background=await page.screenshot();await hidden.evaluate(n=>n.remove());
          facts.contrast=await page.evaluate(async ({samples,encoded})=>{
            const image=await createImageBitmap(await(await fetch(`data:image/png;base64,${encoded}`)).blob());
            const canvas=document.createElement("canvas");canvas.width=image.width;canvas.height=image.height;const ctx=canvas.getContext("2d");ctx.drawImage(image,0,0);image.close();
            const probe=document.createElement("canvas").getContext("2d");
            const luminance=rgb=>rgb.map(v=>{v/=255;return v<=.04045?v/12.92:((v+.055)/1.055)**2.4;}).reduce((s,v,i)=>s+v*[.2126,.7152,.0722][i],0);
            return samples.map(sample=>{const bg=[...ctx.getImageData(Math.floor(sample.x),Math.floor(sample.y),1,1).data];probe.clearRect(0,0,1,1);probe.fillStyle=sample.color;probe.fillRect(0,0,1,1);const fg=[...probe.getImageData(0,0,1,1).data],alpha=fg[3]/255*sample.opacity,a=luminance(fg.slice(0,3).map((v,i)=>v*alpha+bg[i]*(1-alpha))),b=luminance(bg.slice(0,3));return {text:sample.text,opacity:sample.opacity,background:bg.slice(0,3),foreground:fg,ratio:(Math.max(a,b)+.05)/(Math.min(a,b)+.05)};});
          },{samples,encoded:background.toString("base64")});
          assert(facts.contrast.length,"Measure text in the actual reading region");
          if(!baseline) for(const sample of facts.contrast) assert(sample.ratio>=4.5,`${theme.name} ${screen} ${width}: ${JSON.stringify(sample)}`);
          assert(!facts.overflow,`${screen} overflow at ${width}`);assert(facts.text.length,`${screen} has real text`);
          if(!baseline) {
            assert.equal(facts.background,"none","No full-content fade remains");
            const layers=await page.evaluate(()=>({image:getComputedStyle(document.body,"::before").filter,tint:getComputedStyle(document.body,"::after").backgroundColor,content:getComputedStyle(document.querySelector(".content")).filter,controls:[...document.querySelectorAll("button,input,.agent-focus-panel,.agent-summary-viewer")].every(n=>getComputedStyle(n).filter==="none")}));
            assert.match(layers.image,/blur\(3px\)/);assert.equal(layers.content,"none");assert(layers.controls,"Text and controls stay sharp");facts.layers=layers;
          }
          if(captureDir){fs.mkdirSync(captureDir,{recursive:true});await page.screenshot({path:path.join(captureDir,`fade-${theme.id.replace(/^builtin:/, "")}-${width}-${screen}.png`)});}
          results.push({theme:theme.name,mode:theme.mode,width,screen,...facts});
        }
      }
    }
    // Explicit saved adjustments survive the stronger shared reading surface.
    await page.goto(`${baseUrl}/ui#settings`);await page.getByRole("button",{name:"Configuration",exact:true}).click();
    await page.evaluate(async()=>{
      TychoAppearance.setPreference("dark");TychoAppearance.setTheme("dark","dracula");
      const c=document.createElement("canvas");c.width=1200;c.height=900;const x=c.getContext("2d");
      for(let row=0;row<30;row++)for(let col=0;col<40;col++){x.fillStyle=(row+col)%2?"#ffffff":"#000000";x.fillRect(col*30,row*30,30,30);}
      const blob=await new Promise(r=>c.toBlob(r,"image/png"));await TychoBackdropImages.choose(new File([blob],"High detail fixture.png",{type:"image/png"}));
    });
    if(!baseline)assert.equal(await page.evaluate(()=>TychoBackdropImages.getState().image.fade),.5,"New image uses gentle tint default");
    await page.evaluate(()=>TychoBackdropImages.update({fade:.2,intensity:1,x:80,y:25}));
    await page.reload();await page.waitForFunction(()=>TychoBackdropImages.getState().loaded&&!TychoBackdropImages.getState().busy);
    assert.deepEqual(await page.evaluate(()=>{const i=TychoBackdropImages.getState().image;return[i.fade,i.intensity,i.x,i.y];}),[.2,1,80,25]);
    if(!baseline)assert.equal(await page.locator(".content").evaluate(n=>getComputedStyle(n).backgroundImage),"none");
    await page.locator(".theme-image-settings details").evaluate(n=>{n.open=true;});
    const fade=page.locator('[data-theme-image-setting="fade"]');
    assert.equal(await fade.inputValue(),"0.2");assert.equal(await fade.getAttribute("aria-valuetext"),"4% palette tint");await fade.focus();await fade.press("ArrowRight");
    await page.waitForFunction(()=>!TychoBackdropImages.getState().busy&&TychoBackdropImages.getState().image.fade===.25);
    await fade.press("ArrowLeft");
    await page.waitForFunction(()=>!TychoBackdropImages.getState().busy&&TychoBackdropImages.getState().image.fade===.2);
    await page.evaluate(()=>refresh({force:true}));assert.equal(await fade.inputValue(),"0.2");
    const imageId=await page.evaluate(()=>TychoBackdropImages.getState().image.serverId);
    for(const mode of ["dark","light"]){await page.evaluate(async ({mode,imageId})=>{TychoAppearance.setPreference(mode);if(mode==="light"){await TychoBackdropImages.select(imageId,"light");await TychoBackdropImages.update({fade:0,intensity:1},"light");}},{mode,imageId});await page.goto(route);await page.locator("#prompt-input").waitFor();if(captureDir)await page.screenshot({path:path.join(captureDir,`fade-high-detail-${mode}-390.png`)});}
    assert.deepEqual(errors,[]);
    if(captureDir)fs.writeFileSync(path.join(captureDir,"content-fade-results.json"),JSON.stringify({baseline,cases:results,saved_adjustments:"preserved",high_detail:"black/white checker at full intensity",errors},null,2));
    console.log(`content_fade_smoke: ok (${results.length} photo regions; saved image adjustments preserved)`);
  }finally{await context.close();}
};
