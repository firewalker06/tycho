const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");

module.exports = async ({ browser, baseUrl, agentKey, captureDir }) => {
  const response = await fetch(`${baseUrl}/agents/${encodeURIComponent(agentKey)}`);
  assert(response.ok);
  const agent = (await response.json()).agent;
  const attachment = agent.attachments.find(item => item.title === "Cold route guide");
  assert(attachment);
  const key = encodeURIComponent(agentKey), id = encodeURIComponent(attachment.id);
  const routes = [
    { name: "attachment", hash: `#attachment/${id}`, request: /\/attachments\/[^/]+$/, selector: ".attachment-viewer", text: "Workspace guide" },
    { name: "agent-attachment", hash: `#agent/${key}/attachment/${id}`, request: /\/attachments\/[^/]+$/, selector: ".attachment-viewer", text: "Workspace guide" },
    { name: "project-diff", hash: "#project/web/diff?scope=worktree", request: /\/projects\/web\/git\/diff$/, selector: ".diff-viewer", text: "Cold route diff fixture" },
    { name: "pull-requests", hash: `#agent/${key}/pr-diffs`, request: /\/agents\/[^/]+\/pull-requests$/, selector: ".pr-diff-list", text: "123" },
  ];
  const evidence = [];
  for (const [label, viewport] of [["desktop", { width: 1440, height: 900 }], ["mobile", { width: 390, height: 844 }]]) {
    for (const route of routes) {
      for (const start of ["active", "inactive", ...(route.name === "project-diff" ? ["retry", "blur-in-flight"] : [])]) {
        const context = await browser.newContext({ viewport, isMobile: label === "mobile", hasTouch: label === "mobile" });
        const page = await context.newPage();
        const requests = [], errors = [];
        page.on("request", r => { if (r.resourceType() === "fetch") requests.push(new URL(r.url()).pathname); });
        page.on("pageerror", e => errors.push(e.message));
        if (start === "inactive") await page.addInitScript(() => { document.hasFocus = () => false; });
        let release, held;
        const heldSignal = new Promise(resolve => { held = resolve; });
        const barrier = new Promise(resolve => { release = resolve; });
        if (start === "retry") await page.route("**/servers/resources", r => r.fulfill({ status: 503, contentType: "application/json", body: '{"error":"Synthetic initial load failure"}' }));
        if (start === "blur-in-flight") await page.route("**/servers/resources", async r => {
          const response = await r.fetch(); held(); await barrier; await r.fulfill({ response });
        });
        await page.goto(`${baseUrl}/ui${route.hash}`, { waitUntil: "load" });
        if (start === "inactive") {
          await page.waitForTimeout(150);
          assert.equal(requests.length, 0, `${label} ${route.name}: inactive boot`);
          await page.evaluate(() => { delete document.hasFocus; window.dispatchEvent(new Event("focus")); });
        }
        if (start === "retry" || start === "blur-in-flight") {
          if (start === "retry") await page.waitForFunction(() => state.failureCount > 0 && !state.refreshInFlight);
          else await heldSignal;
          await page.evaluate(() => { document.hasFocus = () => false; window.dispatchEvent(new Event("blur")); });
          if (start === "blur-in-flight") { release(); await page.waitForFunction(() => !state.refreshInFlight); }
          assert.equal(await page.evaluate(() => Boolean(state.initialRouteLoaded)), false);
          assert.equal(await page.evaluate(() => state.timer), null);
          assert.equal(requests.filter(p => route.request.test(p)).length, 0, "failed/inactive initialization must not load route data");
          await page.unroute("**/servers/resources");
          await page.evaluate(() => { delete document.hasFocus; window.dispatchEvent(new Event("focus")); });
        }
        await page.waitForFunction(() => !state.refreshInFlight && state.lastUpdatedAt !== null);
        assert(requests.some(p => route.request.test(p)), `${label} ${route.name} ${start}: cold route data was not requested`);
        await page.waitForFunction(() => document.getElementById("tycho-boot-shell").hidden);
        const content = page.locator(route.selector).first();
        await content.waitFor({ state: "visible", timeout: 10000 });
        assert((await content.textContent()).includes(route.text), `${label} ${route.name}: rendered fixture data`);
        assert.equal(await page.evaluate(() => state.initialRouteLoaded), true);
        const file = content.locator(".diff-file").first();
        if (await file.count() && !(await file.evaluate(el => el.open))) await file.locator("summary").click();
        if (captureDir && start === "active" && ["agent-attachment", "project-diff"].includes(route.name)) await page.screenshot({ path: path.join(captureDir, `cold-${route.name}-${label}.png`) });
        const hash = await page.evaluate(() => location.hash);
        const preserved = await content.evaluate(el => {
          el.dataset.coldRouteProbe = "preserved";
          const scroll = el.closest("[data-preserve-scroll]") || document.scrollingElement;
          scroll.scrollTop = Math.min(60, scroll.scrollHeight - scroll.clientHeight);
          const details = el.querySelector("details");
          if (details) details.open = !details.open;
          return { scrollTop: scroll.scrollTop, open: details ? details.open : null };
        });
        const selection = page.locator(".pr-diff-nav-item[aria-current='page']");
        const selected = await selection.count() ? await selection.getAttribute("href") : null;
        await page.evaluate(() => refresh());
        assert.equal(await content.getAttribute("data-cold-route-probe"), "preserved", "later polls preserve the loaded workspace DOM");
        assert.equal(await page.evaluate(() => location.hash), hash);
        const after = await content.evaluate(el => ({
          scrollTop: (el.closest("[data-preserve-scroll]") || document.scrollingElement).scrollTop,
          open: el.querySelector("details")?.open ?? null,
        }));
        assert.deepEqual(after, preserved, "later polls preserve scroll and details state");
        if (selected) assert.equal(await page.locator(".pr-diff-nav-item[aria-current='page']").getAttribute("href"), selected);
        const pollCount = requests.filter(p => /\/servers\/(resources|activity)$/.test(p)).length;
        await page.evaluate(() => {
          for (let i = 0; i < 8; i++) { window.dispatchEvent(new Event("focus")); document.dispatchEvent(new Event("visibilitychange")); }
        });
        await page.waitForTimeout(100);
        assert.equal(requests.filter(p => /\/servers\/(resources|activity)$/.test(p)).length, pollCount, "repeated active events add no requests");
        assert.deepEqual(errors, []);
        evidence.push({ viewport: label, route: route.name, start, routeRequests: requests.filter(p => route.request.test(p)), rendered: true, laterPollPreserved: true, repeatedEvents: 16 });
        await context.close();
      }
    }
  }
  console.log(JSON.stringify(evidence, null, 2));
  if (captureDir) fs.writeFileSync(path.join(captureDir, "cold-workspace-evidence.json"), JSON.stringify(evidence, null, 2));
};
