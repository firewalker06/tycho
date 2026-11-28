const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");

// Same production renderers in a synthetic gallery. No private agent data is used.
module.exports = async ({ browser, baseUrl, agentKey, captureDir }) => {
  assert(captureDir, "Keep synthetic evidence outside the repository");
  fs.mkdirSync(captureDir, { recursive: true });
  const checks = [], observations = {}, results = [];
  const record = (check, value, op, expect) => {
    checks.push({ check, samples: 1, op, expect }); observations[check] = [value];
  };
  for (const theme of ["dark", "light"]) for (const width of [320, 1440]) {
    const context = await browser.newContext({ viewport: { width, height: 900 }, deviceScaleFactor: 1, hasTouch: width === 320, reducedMotion: "reduce", serviceWorkers: "block" });
    await context.addInitScript(theme => localStorage.setItem("hq.remote.appearance", theme), theme);
    const page = await context.newPage();
    const errors = [];
    page.on("pageerror", error => errors.push(error.message));
    if (process.env.TYCHO_SUBTITLE_BASELINE) {
      await page.route("**/ui.css*", async route => {
        const response = await route.fetch(), css = await response.text();
        const current = fs.readFileSync(path.join(__dirname, "../../lib/hq/remote_ui/assets/app.css"), "utf8");
        assert(css.includes(current), "The served bundle must contain the candidate application CSS");
        await route.fulfill({ response, body: css.replace(current, fs.readFileSync(process.env.TYCHO_SUBTITLE_BASELINE, "utf8")) });
      });
    }
    await page.goto(`${baseUrl}/ui#agents`, { waitUntil: "networkidle" });
    await page.locator(".agent-row").first().waitFor();
    for (const sample of ["short", "would-wrap", "overflow", "unbroken"]) {
      const rows = await page.evaluate(async ({ sample, agentKey }) => {
        const source = findAgent(agentKey);
        const agent = { ...source, name: "Synthetic agent", agent: "", model: "", reasoning_effort: "", running: false, status: "succeeded", updated_at: new Date().toISOString(), delegation: { children: [{}] } };
        const reference = { key: agentKey, name: agent.name, status: "succeeded", state: "active", server_key: source.server_key };
        const gallery = document.createElement("section"); gallery.id = "subtitle-gallery";
        document.querySelector("#subtitle-gallery")?.remove();
        document.querySelector("#view").append(gallery);
        // Match responsive resource grid cells and compact list/reference containers.
        const variants = {
          list: a => renderAgentRow(a),
          highlighted: a => renderAgentRow(a, { query: "Web", serverIcon: true }),
          child: a => renderAgentRow(a, { delegationDepth: 2 }),
          grouped: a => renderAgentGroup(a.project_key, [a]),
          delegated: a => renderAgentTree({ root: { ...a, delegated_agents: [{ ...a, key: "synthetic-child" }] }, entries: [{ agent: a, depth: 0 }] }, ""),
          selectable: a => renderSelectableAgentRow(a, { delegatedRunningCount: 1 }),
          archive: a => renderAgentRow(a, { archiveSelectable: true, selected: true }),
          unavailable: a => renderAgentRow(a, { unavailable: true }),
          card: a => renderAgentCard(a),
          switcher: a => renderSwitcherAgentRow(a, 0),
          reference: a => renderAgentReference(reference, { projectName: a.model || "Web" }),
          relationship: a => `<div class="agent-relationship-row">${renderAgentReference(reference, { embedded: true, projectName: a.model || "Web" })}<span class="agent-relationship-tools">Archived</span></div>`,
        };
        const output = [];
        for (const [variant, render] of Object.entries(variants)) {
          const cell = document.createElement("section");
          cell.style.cssText = "min-width:0;margin-bottom:12px";
          cell.innerHTML = `<h2 style="font-size:13px">${variant}</h2><div class="resource-block-grid subtitle-test-grid"></div>`;
          gallery.append(cell);
          const host = cell.querySelector(".subtitle-test-grid");
          if (variant === "grouped") host.classList.remove("resource-block-grid");
          let naturalHeight, lineHeight, el;
          const mount = model => {
            agent.model = model; host.innerHTML = render(agent);
            el = host.querySelector(".agent-block-subtitle");
            if (!el) throw new Error(`Missing shared subtitle in ${variant}`);
            lineHeight = parseFloat(getComputedStyle(el).lineHeight);
            el.style.whiteSpace = "normal";
            el.style.overflowWrap = "anywhere";
            el.style.setProperty("-webkit-line-clamp", "unset");
            naturalHeight = el.getBoundingClientRect().height;
            el.style.removeProperty("-webkit-line-clamp");
            el.style.removeProperty("white-space");
            el.style.removeProperty("overflow-wrap");
          };
          mount("");
          const firstLineHeight = naturalHeight;
          if (sample === "short") mount("");
          else if (sample === "would-wrap") {
            let found = false;
            for (let count = 1; count <= 100; count++) {
              mount("metadata ".repeat(count).trim());
              if (Math.abs(naturalHeight - firstLineHeight - lineHeight) < 1) { found = true; break; }
            }
            if (!found) throw new Error(`Could not construct a natural two-line subtitle: ${variant} height=${naturalHeight} line=${lineHeight} whitespace=${getComputedStyle(el).whiteSpace}`);
          } else mount(sample === "unbroken" ? "LongModelWithoutBreaks".repeat(50) : "Synthetic model metadata ".repeat(50));
          const expected = el.textContent;
          // A second unclamped copy proves that CSS, not string truncation, limits the display.
          const style = getComputedStyle(el), rect = el.getBoundingClientRect();
          const fullText = el.textContent;
          const clone = el.cloneNode(true); clone.style.cssText = `position:absolute;visibility:hidden;width:${rect.width}px;-webkit-line-clamp:unset;white-space:normal;overflow-wrap:anywhere`;
          el.parentElement.append(clone);
          const fullHeight = clone.getBoundingClientRect().height; clone.remove();
          const root = host.firstElementChild;
          output.push({ variant, expectedModel: agent.model, fullText, expected, height: rect.height, lineHeight, firstLineHeight, naturalHeight: fullHeight, clientWidth: el.clientWidth, scrollWidth: el.scrollWidth, scrollHeight: el.scrollHeight, clientHeight: el.clientHeight, display: style.display, ellipsis: style.textOverflow, overflow: style.overflow, whiteSpace: style.whiteSpace, titleKept: root.textContent.includes(["reference", "relationship"].includes(variant) ? (source.name || source.key) : agent.name), iconCount: root.querySelectorAll(".ui-icon").length, highlights: el.querySelectorAll("mark").length, metadataKept: !agent.model || fullText.includes(agent.model), pageOverflow: document.documentElement.scrollWidth - innerWidth });
        }
        await new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve)));
        return output;
      }, { sample, agentKey });
      const accessibility = await page.locator("#subtitle-gallery").ariaSnapshot();
      fs.writeFileSync(path.join(captureDir, `${theme}-${width}-${sample}-accessibility.txt`), accessibility);
      for (const g of rows) {
        const id = `${theme}-${width}-${sample}-${g.variant}`;
        record(`${id}:max-lines-px`, g.height - g.firstLineHeight, "le", 1);
        record(`${id}:expected-height-error-px`, Math.abs(g.height - g.firstLineHeight), "le", 1);
        record(`${id}:natural-lines-px`, g.naturalHeight - g.height, sample === "short" ? "le" : "ge", 1);
        record(`${id}:full-metadata`, Number(g.fullText === g.expected && g.metadataKept), "eq", 1);
        record(`${id}:accessible-metadata`, Number(!g.expectedModel || accessibility.includes(g.expectedModel.trim())), "eq", 1);
        record(`${id}:ellipsis-style`, Number(g.display === "block" && g.ellipsis === "ellipsis" && g.overflow === "hidden" && g.whiteSpace === "nowrap"), "eq", 1);
        if (g.variant === "highlighted") record(`${id}:search-highlight`, g.highlights, "ge", 1);
        record(`${id}:title-icons`, Number(g.titleKept && g.iconCount > 0), "eq", 1);
        record(`${id}:text-width-overflow-px`, g.scrollWidth - g.clientWidth, sample === "short" ? "eq" : "ge", sample === "short" ? 0 : 1);
        record(`${id}:page-overflow-px`, g.pageOverflow, "le", 1);
        results.push({ id, ...g });
      }
      await page.screenshot({ path: path.join(captureDir, `${theme}-${width}-${sample}.png`), fullPage: true });
      if (sample === "overflow" && width === 320) {
        const cells = page.locator("#subtitle-gallery > section");
        for (let index = 0; index < rows.length; index++) {
          await cells.nth(index).screenshot({ path: path.join(captureDir, `${theme}-${width}-${sample}-${rows[index].variant}.png`) });
        }
      }
    }
    if (!process.env.TYCHO_SUBTITLE_BASELINE) {
      await require("./agent_subtitle_interactions_smoke")({ page, baseUrl, agentKey, captureDir, theme, width, record });
    }
    assert.deepEqual(errors, []);
    await context.close();
  }
  fs.writeFileSync(path.join(captureDir, "plan.json"), JSON.stringify(checks, null, 2));
  fs.writeFileSync(path.join(captureDir, "observations.json"), JSON.stringify(observations, null, 2));
  fs.writeFileSync(path.join(captureDir, "results.json"), JSON.stringify({ browser: browser.version(), results }, null, 2));
};
