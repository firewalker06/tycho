const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");

module.exports = async ({ browser, baseUrl, agentKey, captureDir }) => {
  assert(captureDir, "Retain synthetic measurements and screenshots outside the repository");
  fs.mkdirSync(captureDir, { recursive: true });
  const checks = [], observations = {}, results = [];
  const record = (check, value, op, expect) => {
    checks.push({ check, samples: 1, op, expect });
    observations[check] = [value];
  };
  for (const theme of ["dark", "light"]) {
    for (const width of [320, 1440]) {
      const context = await browser.newContext({ viewport: { width, height: 900 }, deviceScaleFactor: 1, serviceWorkers: "block", reducedMotion: "reduce" });
      await context.addInitScript(theme => localStorage.setItem("hq.remote.appearance", theme), theme);
      const page = await context.newPage();
      if (process.env.TYCHO_SUBTITLE_BASELINE) {
        await page.route("**/ui.css*", async route => {
          const response = await route.fetch();
          const css = await response.text();
          const current = fs.readFileSync(path.join(__dirname, "../../lib/hq/remote_ui/assets/app.css"), "utf8");
          assert(css.includes(current), "Baseline replacement must match the served application CSS");
          await route.fulfill({ response, body: css.replace(current, fs.readFileSync(process.env.TYCHO_SUBTITLE_BASELINE, "utf8")) });
        });
      }
      await page.goto(`${baseUrl}/ui#agent/${encodeURIComponent(agentKey)}`, { waitUntil: "networkidle" });
      await page.locator("#prompt-input").waitFor({ state: "visible" });
      for (const long of [false, true]) {
        const text = long ? "Succeeded / Host / Synthetic project / codex / gpt-6.2-sol / low / ".repeat(12) : "OK";
        const id = `${theme}-${width}-${long ? "long" : "short"}`;
        const g = await page.evaluate(async text => {
          const title = document.querySelector("#screen-title").textContent;
          setHeaderSubtitle(text);
          await new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve)));
          const el = document.querySelector(".subtitle-status-text");
          const style = getComputedStyle(el);
          const rect = el.getBoundingClientRect();
          const icon = document.querySelector("#screen-subtitle .ui-icon").getBoundingClientRect();
          const controls = ["#header-title-copy", "#header-more-button"].map(selector => {
            const node = document.querySelector(selector), r = node.getBoundingClientRect();
            return r.width > 0 && r.left >= 0 && r.right <= innerWidth && document.elementFromPoint(r.x + r.width / 2, r.y + r.height / 2)?.closest(selector) === node;
          });
          return { text: el.textContent, scrollWidth: el.scrollWidth, clientWidth: el.clientWidth, height: rect.height, lineHeight: parseFloat(style.lineHeight), whiteSpace: style.whiteSpace, ellipsis: style.textOverflow, overflow: style.overflow, iconWidth: icon.width, titleKept: title === document.querySelector("#screen-title").textContent, controls, pageOverflow: document.documentElement.scrollWidth - innerWidth };
        }, text);
        record(`${id}:one-line-error-px`, Math.abs(g.height - g.lineHeight), "le", 1);
        record(`${id}:width-difference-px`, g.scrollWidth - g.clientWidth, long ? "ge" : "eq", long ? 1 : 0);
        record(`${id}:full-text`, Number(g.text === text), "eq", 1);
        record(`${id}:ellipsis-style`, Number(g.whiteSpace === "nowrap" && g.ellipsis === "ellipsis" && g.overflow === "hidden"), "eq", 1);
        record(`${id}:controls-and-title`, Number(g.titleKept && g.controls.every(Boolean) && g.iconWidth === 14), "eq", 1);
        record(`${id}:page-overflow-px`, g.pageOverflow, "le", 1);
        results.push({ id, geometry: g });
        await page.screenshot({ path: path.join(captureDir, `${id}.png`) });
      }
      await context.close();
    }
  }
  fs.writeFileSync(path.join(captureDir, "plan.json"), JSON.stringify(checks, null, 2));
  fs.writeFileSync(path.join(captureDir, "observations.json"), JSON.stringify(observations, null, 2));
  fs.writeFileSync(path.join(captureDir, "results.json"), JSON.stringify({ browser: browser.version(), results }, null, 2));
};
