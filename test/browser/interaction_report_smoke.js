"use strict";

const assert = require("node:assert/strict");
const fs = require("node:fs/promises");
const http = require("node:http");
const os = require("node:os");
const path = require("node:path");
const { spawn } = require("node:child_process");
const { chromium } = require(process.env.TYCHO_PLAYWRIGHT_PATH || "playwright");

const root = path.resolve(__dirname, "../..");
const fixture = `<!doctype html><title>Interaction fixture</title>
<style>body{font:16px system-ui;margin:30px;background:#edf2f8;color:#203047}#card{max-width:850px;padding:24px;background:white;border:1px solid #becbdc;border-radius:12px}button,input{padding:10px;margin:6px}#panel{padding:15px;background:#d5f1e1}</style>
<div id="card"><h1>Interaction test fixture</h1><p id="state">Setup</p>
<button id="prepare" onclick="document.getElementById('state').textContent='Ready'">Start</button>
<label>Name <input id="name"></label><details id="options"><summary>Options</summary><p>Fixture options</p></details>
<p id="status">Pending</p><button id="commit" onclick="document.getElementById('status').outerHTML='<p id=status>Done</p>'">Commit</button>
<button id="show" onclick="document.getElementById('slot').innerHTML='<div id=panel>Visible panel</div>'">Show</button>
<div id="slot"></div><button id="busy" onclick="document.getElementById('state').setAttribute('aria-busy','true')">Busy</button>
<button id="hide" onclick="document.getElementById('panel').remove()">Hide</button>
<button id="slow" onclick="setTimeout(()=>document.getElementById('status').textContent='Delayed',250)">Slow</button>
<button id="never">No change</button><button id="later">Must not run</button>
<button class="duplicate">Duplicate A</button><button class="duplicate">Duplicate B</button></div>`;

async function command(args, env) {
  return new Promise((resolve, reject) => {
    const child = spawn(process.execPath, ["bin/remote-ui-interaction-report", ...args], { cwd: root, env });
    let output = "";
    child.stdout.on("data", (bytes) => { output += bytes; });
    child.stderr.on("data", (bytes) => { output += bytes; });
    child.on("error", reject);
    child.on("exit", (code) => resolve({ code, output }));
  });
}

async function main() {
  const directory = process.env.TYCHO_REMOTE_UI_CAPTURE_DIR || await fs.mkdtemp(path.join(os.tmpdir(), "tycho-configured-interaction-"));
  await fs.mkdir(directory, { recursive: true });
  const server = http.createServer((request, response) => {
    response.writeHead(200, { "Content-Type": "text/html" });
    response.end(fixture);
  });
  await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
  const url = `http://127.0.0.1:${server.address().port}/`;
  const env = { ...process.env, TYCHO_REMOTE_TOKEN: "fixture-report-token" };
  const measurement = (name, trigger, expect, extra = {}) => ({
    action: "measure", name, trigger: { action: "click", selector: trigger }, expect, screenshot: "#card", withinMs: 1000, ...extra
  });
  const scenarios = {
    configured: { expected: 0, steps: [
      { action: "open", url: "/demo" }, { action: "click", selector: "#prepare", text: "Start" },
      { action: "fill", selector: "#name", value: "Synthetic sample" }, { action: "expand", selector: "#options" },
      { action: "wait", expect: { selector: "#state", text: "Ready" } },
      measurement("Text on a replaced element", "#commit", { selector: "#status", text: "Done" }),
      measurement("New panel becomes visible", "#show", { selector: "#panel", visible: true }),
      measurement("Attribute changes on another element", "#busy", { selector: "#state", attribute: { name: "aria-busy", value: "true" } }),
      measurement("Panel is removed", "#hide", { selector: "#panel", visible: false })
    ] },
    late: { expected: 1, steps: [measurement("Delayed text", "#slow", { selector: "#status", text: "Delayed" }, { withinMs: 10 }), { action: "click", selector: "#later" }] },
    timeout: { expected: 1, steps: [measurement("Unchanged target", "#never", { selector: "#status", text: "Done" }, { timeoutMs: 400, withinMs: 10 })] },
    already: { expected: 2, steps: [measurement("Already satisfied", "#commit", { selector: "#status", text: "Pending" })] },
    ambiguous: { expected: 2, steps: [measurement("Duplicate trigger", ".duplicate", { selector: "#status", text: "Done" })] },
    guard: { expected: 2, steps: [{ ...measurement("Wrong trigger text", "#commit", { selector: "#status", text: "Done" }), trigger: { action: "click", selector: "#commit", text: "Wrong text" } }] }
  };
  let browser;
  try {
    for (const [name, scenario] of Object.entries(scenarios)) {
      const config = path.join(directory, `${name}.json`);
      const report = path.join(directory, `${name}-report.html`);
      await fs.writeFile(config, JSON.stringify({ name: `Fixture: ${name}`, url, timeoutMs: 2000, steps: scenario.steps }, null, 2));
      const result = await command(["--config", config, "--output", report], env);
      assert.equal(result.code, scenario.expected, result.output);
      const html = await fs.readFile(report, "utf8");
      assert.ok(!html.includes(env.TYCHO_REMOTE_TOKEN));
      assert.ok(!result.output.includes(env.TYCHO_REMOTE_TOKEN));
      if (name === "configured") assert.equal((html.match(/data:image\/png;base64,/g) || []).length, 12);
      if (name === "late") assert.ok(!html.includes('<td>2</td><td>click</td>'));
      if (name === "timeout") assert.ok(html.includes("timeout"));
      console.log(`${name}: exit ${result.code}, HTML saved`);
    }
    browser = await chromium.launch(process.env.CHROME_PATH ? { executablePath: process.env.CHROME_PATH } : { channel: "chrome" });
    const page = await browser.newPage({ viewport: { width: 1280, height: 1000 } });
    await page.goto(`file://${path.join(directory, "configured-report.html")}`);
    assert.equal(await page.locator("img").count(), 12);
    assert.ok(await page.evaluate(() => [...document.images].every((image) => image.complete && image.naturalWidth > 0)));
    assert.equal(await page.evaluate(() => document.documentElement.scrollWidth > innerWidth), false);
    await page.screenshot({ path: path.join(directory, "report-preview.png") });
    await page.setViewportSize({ width: 390, height: 844 });
    assert.equal(await page.evaluate(() => document.documentElement.scrollWidth > innerWidth), false);
    console.log(`Browser checks passed. Reports: ${directory}`);
  } finally {
    await browser?.close();
    await new Promise((resolve) => server.close(resolve));
  }
}

main().catch((error) => { console.error(error); process.exitCode = 1; });
