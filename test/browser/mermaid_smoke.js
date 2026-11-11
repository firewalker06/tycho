const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");

const stateSource = `stateDiagram-v2
  accTitle: Publication review
  accDescr: Drafts pass screening before publication. Rejected reviews return to Draft.
  [*] --> Draft
  Draft --> Submitted : submit
  state Review {
    [*] --> Screening
    Screening --> Decision
  }
  Submitted --> Review
  Review --> Published : approved
  Review --> Draft : rejected
  Published --> [*]`;

async function installFixture(page, baseUrl, agentKey, source = stateSource) {
  const fence = String.fromCharCode(96).repeat(3);
  const blocks = [{ id: "mermaid-theme", kind: "message", role: "assistant",
    content: `## Publication review\n\n${fence}mermaid\n${source}\n${fence}\n\n${fence}mermaid\nflowchart LR\n  A[Second chart] --> B[Still source]\n${fence}` }];
  await page.route(new RegExp(`/agents/${agentKey}/conversation(?:\\?|$)`), async (route) => {
    const response = await route.fetch();
    const data = await response.json();
    data.conversation = blocks;
    data.conversation_block_count = blocks.length;
    data.conversation_has_older = false;
    await route.fulfill({ json: data });
  });
  await page.goto(`${baseUrl}/ui#agent/${encodeURIComponent(agentKey)}`, { waitUntil: "networkidle" });
  await page.waitForSelector("#prompt-input");
  await page.evaluate(async () => {
    await ensureMarkdownParserLoaded();
    state.renderedRouteKey = null;
    state.renderedViewHtml = "";
    render();
  });
  await page.locator("code.language-mermaid").first().waitFor();
  return blocks;
}

async function preview(page, index = 0, scope = "") {
  const block = page.locator(`${scope}.markdown-code-block`).nth(index);
  await block.locator("[data-toggle-markdown-code-menu]").click();
  await page.locator(".markdown-code-menu-popover:not([hidden]) [data-preview-mermaid-code]").press("Enter");
  await block.locator(".mermaid svg").waitFor({ timeout: 30000 });
  return block;
}

async function showCode(page, block) {
  await block.locator("[data-toggle-markdown-code-menu]").click();
  await page.locator(".markdown-code-menu-popover:not([hidden]) [data-show-mermaid-code]").press("Enter");
  await block.locator("pre").waitFor({ state: "visible" });
}

module.exports = async function mermaidSmoke({ browser, baseUrl, agentKey, captureDir }) {
  const evidence = [];
  for (const viewport of [{ width: 1440, height: 1000 }, { width: 390, height: 844 }]) {
    const page = await browser.newPage({ viewport });
    const errors = [];
    page.on("pageerror", (error) => errors.push(error.message));
    const blocks = await installFixture(page, baseUrl, agentKey);
    assert.equal(await page.locator('script[src*="/mermaid@"]').count(), 0, "source view must not load Mermaid");
    const block = await preview(page);
    assert.equal(await page.locator(".mermaid svg").count(), 1, "preview only the selected chart");
    assert.equal(await page.locator("pre:not([hidden]) code.language-mermaid").count(), 1);
    if (captureDir) fs.writeFileSync(path.join(captureDir, "state.svg"), await block.locator(".mermaid svg").evaluate((svg) => svg.outerHTML));
    const facts = await page.evaluate(() => {
      const config = window.mermaid.mermaidAPI.getConfig();
      const svg = document.querySelector(".mermaid svg");
      const title = document.getElementById(svg.getAttribute("aria-labelledby"));
      const description = document.getElementById(svg.getAttribute("aria-describedby"));
      return {
        theme: config.theme, look: config.look, layout: config.state.layout,
        securityLevel: config.securityLevel, startOnLoad: config.startOnLoad,
        script: document.querySelector('script[src*="/mermaid@"]').src,
        role: svg.getAttribute("role"), title: title?.textContent, description: description?.textContent,
        overflow: document.documentElement.scrollWidth > innerWidth,
        stateBorder: svg.querySelector(".node rect") ? getComputedStyle(svg.querySelector(".node rect")).stroke : null,
        clusterBorder: svg.querySelector(".statediagram-cluster rect.outer") ? getComputedStyle(svg.querySelector(".statediagram-cluster rect.outer")).stroke : null,
      };
    });
    assert.equal(facts.theme, "redux-dark-color");
    assert.equal(facts.look, "neo");
    assert.equal(facts.layout, "elk");
    assert.equal(facts.securityLevel, "strict");
    assert.equal(facts.startOnLoad, false);
    assert(facts.script.includes("mermaid@12.2.0/"));
    assert.equal(facts.role, "graphics-document document");
    assert.equal(facts.title, "Publication review");
    assert(facts.description.includes("Rejected reviews return to Draft"));
    assert(!facts.overflow, "diagram must stay inside the mobile/desktop viewport");
    assert.equal(facts.stateBorder, "rgb(255, 255, 255)", "neo dark state borders match the reference");
    assert.equal(facts.clusterBorder, "rgb(232, 121, 249)", "Redux colours the composite state");
    await block.scrollIntoViewIfNeeded();
    if (captureDir) await page.screenshot({ path: path.join(captureDir, `mermaid-state-${viewport.width}.png`) });
    await showCode(page, block);
    if (captureDir) await page.screenshot({ path: path.join(captureDir, `mermaid-source-${viewport.width}.png`) });
    assert.equal(await page.locator(".mermaid").count(), 0);
    assert.equal(await block.locator("code").textContent(), `${stateSource}\n`, "source round trip must be exact");
    await preview(page);
    await page.evaluate(() => refresh({ force: true, forceConversation: true }));
    assert.equal(await page.locator(".mermaid svg").count(), 1, "unchanged polling must preserve the preview");
    await block.evaluate((node) => { window.__previewBlock = node; });
    blocks.push({ id: "poll-update", kind: "message", role: "assistant", content: "A new poll result." });
    await page.evaluate(() => refresh({ force: true, forceConversation: true }));
    assert.equal(await page.locator(".mermaid svg").count(), 1, "a changed poll must preserve the preview");
    assert(await page.evaluate(() => window.__previewBlock === document.querySelector("[data-mermaid-previewing]")), "keep the rendered chart node");
    if (captureDir) await page.screenshot({ path: path.join(captureDir, `mermaid-poll-${viewport.width}.png`) });
    const summary = { id: "chart-summary", kind: "run_summary", role: "assistant", content: blocks[0].content,
      metadata: { summary_id: "chart-summary", status: "success", run_number: 1 } };
    blocks.push(summary);
    await page.evaluate(() => refresh({ force: true, forceConversation: true }));
    await page.goto(`${baseUrl}/ui#agent/${agentKey}/summary/chart-summary`, { waitUntil: "networkidle" });
    await page.reload({ waitUntil: "networkidle" });
    await page.locator("[data-agent-summary-page] code.language-mermaid").first().waitFor();
    await preview(page, 0, "[data-agent-summary-page] ");
    await page.evaluate(() => {
      window.__summaryChart = document.querySelector(".mermaid svg");
      const agent = findAgent(parseRoute().key);
      agent.run_count = Number(agent.run_count || 0) + 1;
      render();
    });
    if (captureDir) await page.screenshot({ path: path.join(captureDir, `mermaid-summary-poll-${viewport.width}.png`) });
    assert.equal(await page.locator(".mermaid svg").count(), 1, "Summary metadata updates must preserve the preview");
    assert(await page.evaluate(() => window.__summaryChart === document.querySelector(".mermaid svg")), "Summary must keep the same SVG");
    await page.evaluate(() => refresh({ force: true, forceConversation: true }));
    assert(await page.evaluate(() => window.__summaryChart === document.querySelector(".mermaid svg")), "forced Summary polling must keep the SVG");
    const summaryBlock = page.locator("[data-agent-summary-page] .markdown-code-block").first();
    await showCode(page, summaryBlock);
    await page.evaluate(() => {
      findAgent(parseRoute().key).run_count += 1;
      render();
    });
    assert.equal(await page.locator(".mermaid").count(), 0, "Show code must survive metadata updates");
    await page.evaluate(() => {
      const block = document.querySelector("[data-agent-summary-page] .markdown-code-block");
      void previewMermaidCodeBlock(block);
      findAgent(parseRoute().key).run_count += 1;
      render();
    });
    await summaryBlock.locator(".mermaid svg").waitFor();
    await page.evaluate(() => window.TychoAppearance.setPreference("light"));
    await summaryBlock.locator(".mermaid svg").waitFor();
    assert.equal(await page.evaluate(() => window.mermaid.mermaidAPI.getConfig().theme), "base");
    await page.evaluate(() => {
      const agent = findAgent(parseRoute().key);
      const summary = runSummaryBlocks(agent).find(block => runSummaryId(block) === "chart-summary");
      summary.content = summary.content.replace("Publication review", "Changed summary").replace("Screening --> Decision", "Screening --> Revised");
      render();
    });
    assert.equal(await page.locator(".mermaid svg").count(), 0, "changed source must discard the old preview");
    assert((await summaryBlock.locator("code").textContent()).includes("Screening --> Revised"));
    await preview(page, 0, "[data-agent-summary-page] ");
    await page.goto(`${baseUrl}/ui#agent/${agentKey}`, { waitUntil: "networkidle" });
    assert.equal(await page.locator(".mermaid svg").count(), 0, "previews must not leak across routes");
    assert.deepEqual(errors, []);
    evidence.push({ viewport, ...facts });
    await page.close();
  }

  const page = await browser.newPage({ viewport: { width: 1440, height: 1000 } });
  await installFixture(page, baseUrl, agentKey);
  await preview(page);
  const elkGeometry = await page.locator(".mermaid svg").getAttribute("viewBox");
  const examples = [
    ["state Dagre override", `---\nconfig:\n  state:\n    layout: dagre\n---\n${stateSource}`],
    ["flowchart", 'flowchart LR\n  A[Start] --> B{Ready?}\n  B -->|yes| C[Done]'],
    ["sequence", 'sequenceDiagram\n  Alice->>Bob: Check the preview\n  Bob-->>Alice: Done'],
    ["class", 'classDiagram\n  Animal <|-- Duck\n  Animal : +String name'],
    ["er", 'erDiagram\n  USER ||--o{ TASK : owns'],
    ["legacy override", '---\nconfig:\n  theme: dark\n  look: classic\n  layout: dagre\n---\nflowchart LR\n  A --> B'],
    ["strict security", '%%{init: {"securityLevel":"loose"}}%%\nflowchart LR\n  A[Safe link] --> B[Done]\n  click A "javascript:window.__mermaidUnsafe=true" "Unsafe"'],
  ];
  for (const [name, source] of examples) {
    await page.evaluate((source) => {
      const code = document.querySelector("code.language-mermaid");
      showMermaidCodeBlock(code.closest(".markdown-code-block"));
      code.textContent = source;
    }, source);
    await preview(page);
    assert.equal(await page.locator(".mermaid[data-mermaid-error]").count(), 0, name);
    if (name === "state Dagre override") {
      assert.notEqual(await page.locator(".mermaid svg").getAttribute("viewBox"), elkGeometry, "ELK must produce its own layout, not fall back to Dagre");
    }
    if (name === "legacy override") {
      assert.equal(await page.locator('.mermaid [data-look="neo"]').count(), 0, "frontmatter must still select classic geometry");
    }
    if (name === "strict security") {
      assert.equal(await page.locator('.mermaid a[href^="javascript:"], .mermaid [onclick]').count(), 0);
      assert.equal(await page.evaluate(() => window.__mermaidUnsafe === true), false);
      assert.equal(await page.evaluate(() => window.mermaid.mermaidAPI.getConfig().securityLevel), "strict");
    }
  }
  await page.evaluate(() => {
    const code = document.querySelector("code.language-mermaid");
    showMermaidCodeBlock(code.closest(".markdown-code-block"));
    code.textContent = "flowchart LR\n  A[<img src=x onerror=window.__mermaidUnsafe=true>] -->";
    return previewMermaidCodeBlock(code.closest(".markdown-code-block"));
  });
  assert.equal(await page.locator('.mermaid[data-mermaid-error="true"]').count(), 1);
  assert.equal(await page.locator(".mermaid img").count(), 0, "invalid source must stay text");
  await showCode(page, page.locator(".markdown-code-block").first());
  assert((await page.locator("code.language-mermaid").first().textContent()).includes("onerror=window.__mermaidUnsafe"));
  await page.close();
  const offline = await browser.newPage();
  await offline.route("**/mermaid@12.2.0/**", (route) => route.abort());
  await installFixture(offline, baseUrl, agentKey);
  const offlineBlock = offline.locator(".markdown-code-block").first();
  await offlineBlock.locator("[data-toggle-markdown-code-menu]").click();
  await offline.locator(".markdown-code-menu-popover:not([hidden]) [data-preview-mermaid-code]").click();
  await offline.locator('.mermaid[data-mermaid-error="true"]').waitFor();
  assert.equal(await offline.locator(".mermaid").textContent(), `${stateSource}\n`);
  await showCode(offline, offlineBlock);
  assert.equal(await offlineBlock.locator("code").textContent(), `${stateSource}\n`);
  await offline.close();
  if (captureDir) fs.writeFileSync(path.join(captureDir, "mermaid-browser-evidence.json"), JSON.stringify(evidence, null, 2));
  console.log("mermaid_smoke: ok", JSON.stringify(evidence));
};
