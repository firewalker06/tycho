const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const variants = [
  {id:"rejected-fade",blur:0,saturation:1,contrast:1,tint:0},
  {id:"blur",blur:5,saturation:1,contrast:1,tint:0},
  {id:"muted",blur:0,saturation:.48,contrast:.72,tint:.15},
  {id:"soft",blur:3,saturation:.78,contrast:.9,tint:.1}
];
const selector=':root:is([data-backdrop="photo"], [data-image-backdrop="ready"])';
function styles(variant) {
  // The chosen variant must use production CSS, not a test-only approximation.
  if (variant.id === "soft") return "";
  if (variant.id === "rejected-fade") return `
${selector} body::before {inset:0!important;filter:none!important;}
${selector} body::after {content:none!important;}
:root[data-backdrop="photo"]:not([data-image-backdrop="ready"]) body::before {background-image:radial-gradient(ellipse at center,color-mix(in srgb,var(--bg) 90%,transparent) 0% 55%,transparent 100%),var(--theme-backdrop-image)!important;}
:root[data-image-backdrop="ready"] body::before {background-image:radial-gradient(ellipse at center,color-mix(in srgb,var(--bg) 90%,transparent) 0% 55%,transparent 100%),var(--theme-raster-image)!important;}
${selector} .content {background-image:linear-gradient(to right,transparent,color-mix(in srgb,var(--bg) 98%,transparent) 12px,color-mix(in srgb,var(--bg) 98%,transparent) calc(100% - 12px),transparent)!important;}
${selector} .message.run_summary {background:color-mix(in srgb,var(--accent-alt) 12%,var(--panel))!important;}
${selector} .agent-summary-viewer {background:transparent!important;border:0!important;border-radius:0!important;padding:0!important;}
${selector} .settings-section-heading {background:transparent!important;border-radius:0!important;padding:0!important;}
`;
  return `
${selector} .content {background-image:none!important;}
:root[data-backdrop="photo"]:not([data-image-backdrop="ready"]) body::before {background-image:var(--theme-backdrop-image)!important;}
:root[data-image-backdrop="ready"] body::before {background-image:var(--theme-raster-image)!important;}
${selector} body::before {inset:-12px!important;filter:blur(${variant.blur}px) saturate(${variant.saturation}) contrast(${variant.contrast}) brightness(1.02)!important;}
:root[data-appearance="dark"]:is([data-backdrop="photo"],[data-image-backdrop="ready"]) body::before {filter:blur(${variant.blur}px) saturate(${variant.saturation}) contrast(${variant.contrast}) brightness(.88)!important;}
${selector} body::after {content:"";position:fixed;inset:0;z-index:-1;pointer-events:none;background:color-mix(in srgb,var(--bg) ${variant.tint*100}%,transparent);}
${selector} .message.run_summary {background:var(--panel)!important;}
${selector} .agent-summary-viewer {background:var(--panel);border:1px solid var(--border);border-radius:8px;padding:12px;}
${selector} .settings-section-heading {background:var(--panel);border-radius:8px;padding:8px;}
`;
}
async function install(page,variant) {
  await page.evaluate(css=>{document.getElementById("filter-comparison")?.remove();if(css){const s=document.createElement("style");s.id="filter-comparison";s.textContent=css;document.head.append(s);}},styles(variant));
  await page.evaluate(async()=>{await document.fonts.ready;await new Promise(requestAnimationFrame);await new Promise(requestAnimationFrame);});
}
async function scrollSample(page,frames=120) {
  return page.evaluate(async frames=>{
    const node=conversationScrollRoot();
    const canScroll=node && node.scrollHeight>node.clientHeight;
    if(!canScroll)throw Error("Scroll fixture must overflow the conversation");
    node.scrollTop=0;const gaps=[];let last;
    for(let i=0;i<frames+1;i++){await new Promise(requestAnimationFrame);const now=performance.now();if(last!==undefined)gaps.push(now-last);last=now;node.scrollTop=(i*17)%(node.scrollHeight-node.clientHeight);}
    gaps.sort((a,b)=>a-b);return {frames:gaps.length,median:gaps[Math.floor(gaps.length*.5)],p95:gaps[Math.floor(gaps.length*.95)],maximum:gaps.at(-1),over33ms:gaps.filter(x=>x>33).length};
  },frames);
}
async function traceScroll(page,output) {
  const cdp=await page.context().newCDPSession(page),events=[];
  await cdp.send("Tracing.start",{categories:"devtools.timeline,disabled-by-default-devtools.timeline,cc",transferMode:"ReportEvents"});
  cdp.on("Tracing.dataCollected",({value})=>events.push(...value));
  const result=await scrollSample(page,120);
  const complete=new Promise(resolve=>cdp.once("Tracing.tracingComplete",resolve));await cdp.send("Tracing.end");await complete;
  const counts={};for(const e of events)if(["Paint","RasterTask","Layout","UpdateLayerTree"].includes(e.name))counts[e.name]=(counts[e.name]||0)+1;
  if(output)fs.writeFileSync(output,JSON.stringify({traceEvents:events}));await cdp.detach();return {result,events:counts};
}
module.exports=async({browser,baseUrl,agentKey,captureDir})=>{
  const context=await browser.newContext({viewport:{width:1920,height:1100},reducedMotion:"reduce",serviceWorkers:"block"}),page=await context.newPage(),route=`${baseUrl}/ui#agent/${agentKey}`,results=[],performance=[];
  try{
    await page.goto(route);await page.locator("#prompt-input").waitFor();
    const examples=await page.evaluate(()=>TychoAppearance.getThemeState().examples);
    await page.evaluate(async()=>{
      TychoAppearance.setPreference("dark");TychoAppearance.setTheme("dark","dracula");
      const url=TychoAppearance.getThemeState().examples.find(x=>x.id==="builtin:senggigi-beach").photo;
      const blob=await(await fetch(url)).blob();await TychoBackdropImages.choose(new File([blob],"Uploaded beach fixture.webp",{type:"image/webp"}));
      const id=TychoBackdropImages.getState().image.serverId;await TychoBackdropImages.select(id,"light");
    });
    const scenes=[...examples,{id:"dracula",name:"Uploaded beach",mode:"dark"},{id:"nord",name:"Uploaded beach",mode:"light"}];
    for(const width of [1920,390]){
      await page.setViewportSize({width,height:width===390?844:1100});
      for(const scene of scenes){
        await page.evaluate(t=>{TychoAppearance.setPreference(t.mode);TychoAppearance.setTheme(t.mode,t.id);},scene);
        for(const screen of ["conversation","summary"]){
          await page.goto(screen==="summary"?`${route}/summary/rich-summary`:route);await page.locator(screen==="summary"?"[data-agent-summary-page]":"#prompt-input").waitFor();
          for(const variant of variants){
            await install(page,variant);
            const facts=await page.evaluate(()=>({filter:getComputedStyle(document.body,"::before").filter,contentFilter:getComputedStyle(document.querySelector(".content")).filter,overflow:document.documentElement.scrollWidth>innerWidth}));
            assert.equal(facts.contentFilter,"none");assert(!facts.overflow);
            if(captureDir){fs.mkdirSync(captureDir,{recursive:true});await page.screenshot({path:path.join(captureDir,`${variant.id}-${scene.id.replace("builtin:","")}-${scene.mode}-${width}-${screen}.png`)});}
            results.push({scene:scene.name,mode:scene.mode,width,screen,variant:variant.id,...facts});
          }
        }
      }
      await page.goto(route);await page.locator("#prompt-input").waitFor();
      await page.locator(".message.assistant").filter({hasText:"Tail message 19."}).waitFor();
      await page.evaluate(width=>{TychoAppearance.setPreference("dark");TychoAppearance.setTheme("dark",width===390?"dracula":"builtin:cyberpunk");},width);
      // Equal page, content, scroll sequence, viewport and warm-up for each variant.
      for(let trial=0;trial<3;trial++)for(const variant of (trial%2?[...variants].reverse():variants)){
        await install(page,variant);await scrollSample(page,30);
        performance.push({width,scene:width===390?"Uploaded beach Dark":"Cyberpunk Dark",trial,variant:variant.id,...await scrollSample(page)});
      }
      if(captureDir)for(const id of ["rejected-fade","soft"]){await install(page,variants.find(v=>v.id===id));const trace=await traceScroll(page,path.join(captureDir,`scroll-${width}-${id}.trace.json`));performance.push({width,scene:width===390?"Uploaded beach Dark":"Cyberpunk Dark",variant:id,trace:true,...trace});}
    }
    if(captureDir)fs.writeFileSync(path.join(captureDir,"filter-comparison-results.json"),JSON.stringify({browser:browser.version(),environment:"Local headless Chrome, reduced motion, isolated synthetic fixture; viewport emulation is not a phone GPU",method:"3 alternating-order warm trials, 120 requestAnimationFrame-driven scroll steps; trace runs reported separately",scenes:results,performance},null,2));
    console.log(`backdrop_filter_comparison: ok (${results.length} rendered variants; ${performance.length} scroll observations)`);
  }finally{await context.close();}
};
module.exports.variants=variants;
module.exports.styles=styles;
module.exports.scrollSample=scrollSample;
