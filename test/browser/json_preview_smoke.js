const path = require("path");

module.exports = async function jsonPreviewSmoke({ browser, baseUrl, agentKey, captureDir }) {
  const page = await browser.newPage({ viewport: { width: 1920, height: 1080 } });
  const errors = [];
  page.on("pageerror", (error) => errors.push(error.message));
  const agent = (await (await page.request.get(`${baseUrl}/agents/${agentKey}`)).json()).agent;
  const attachments = Object.fromEntries(agent.attachments.map((item) => [item.title, item]));
  async function open(title) {
    await page.locator(`.agent-detail-pane [data-preview-summary-attachment="${attachments[title].id}"]`).first().click();
    await page.waitForFunction(() => document.querySelector(".summary-attachment-preview-scroll")?.getAttribute("aria-busy") === "false");
    await page.waitForFunction(() => document.querySelectorAll(".attachment-code-viewer .code-line").length > 0).catch(async (error) => {
      if (captureDir) await page.screenshot({ path: path.join(captureDir, "json-preview-timeout.png") });
      throw new Error(`${error.message}\n${await page.locator(".summary-attachment-preview-scroll").innerHTML()}`);
    });
    return page.locator(".attachment-code-viewer .code-line").evaluateAll((lines) => lines.map((line) => line.textContent));
  }
  await page.goto(`${baseUrl}/ui#agent/${agentKey}/summary/preview-current`, { waitUntil: "networkidle" });
  const jsonLines = await open("Schedule JSON");
  if (captureDir) await page.screenshot({ path: path.join(captureDir, "json-preview.png") });
  if (jsonLines.length < 8) throw new Error(`JSON preview is not multi-line: ${JSON.stringify(jsonLines)}`);
  const original = '{  "name": "Schedule Resume",  "url": "https://example.test/",  "steps": [{"id": 1, "label": "open"}, {"id": 2, "label": "resume"}],  "enabled": true  }';
  if (JSON.stringify(JSON.parse(jsonLines.join("\n"))) !== JSON.stringify(JSON.parse(original))) throw new Error("JSON preview changed data");
  const linesPreview = await open("Events JSONL");
  if (linesPreview.join("|").replace(/\u200b/g, "") !== '{"a":1}|{"b":2}|') throw new Error(`JSON Lines preview was reformatted: ${JSON.stringify(linesPreview)}`);
  if (errors.length) throw new Error(`Page errors: ${errors.join("; ")}`);
  await page.close();
  console.log("json_preview_smoke: ok");
};
