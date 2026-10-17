// Run with a local Playwright install and Chrome. See README.md.
const { chromium } = require("playwright");
const fs = require("node:fs");
const path = require("node:path");

(async () => {
  const base = process.env.TYCHO_PROTO_TEST_URL;
  const token = fs.readFileSync(process.env.TYCHO_PROTO_TEST_TOKEN_FILE, "utf8").trim();
  const capture = process.env.TYCHO_PROTO_CAPTURE_DIR;
  fs.mkdirSync(capture, { recursive: true });
  const browser = await chromium.launch({ executablePath: process.env.CHROME_PATH, headless: true });
  const page = await browser.newPage({ viewport: { width: 1280, height: 900 } });
  const errors = [];
  page.on("pageerror", (failure) => errors.push(failure.message));
  try {
    const response = await page.goto(base);
    if (response.status() !== 200) throw new Error("Page did not load");
    await page.locator("#token").fill("wrong-token");
    await page.locator("#login button").click();
    await page.waitForFunction(() => document.getElementById("error").textContent.includes("Access token"));
    await page.locator("#token").fill(token);
    await page.locator("#login button").click();
    await page.locator("#workspace").waitFor({ state: "visible" });
    const task = process.env.TYCHO_PROTO_TEST_PROMPT || "Read README.md in the current workspace. Do not change files. Report its first heading, then write PROTOTYPE_AGENT_OK.";
    await page.locator("#prompt").fill(task);
    await page.locator("#start").click();
    await page.waitForFunction(() => ["running", "succeeded"].includes(document.getElementById("status").textContent));
    await page.locator("#prompt").fill("Draft preserved during polling");
    await page.waitForTimeout(1500);
    if (await page.locator("#prompt").inputValue() !== "Draft preserved during polling") throw new Error("Polling lost draft");
    await page.waitForFunction(() => ["succeeded", "failed", "stopped"].includes(document.getElementById("status").textContent), null, { timeout: 195000 });
    const status = await page.locator("#status").textContent();
    const result = await page.locator("#result").textContent();
    if (status !== "succeeded" || !result.includes("PROTOTYPE_AGENT_OK")) throw new Error(`Agent did not pass: ${status}: ${result}`);
    await page.screenshot({ path: path.join(capture, "desktop.png"), fullPage: true });
    await page.setViewportSize({ width: 390, height: 844 });
    await page.screenshot({ path: path.join(capture, "mobile.png"), fullPage: true });
    const overflow = await page.evaluate(() => document.documentElement.scrollWidth > window.innerWidth);
    if (overflow) throw new Error("Mobile horizontal overflow");
    await page.reload();
    await page.locator("#login-panel").waitFor({ state: "visible" });
    if (await page.evaluate(() => localStorage.length || sessionStorage.length)) throw new Error("Credential stored in browser storage");
    if (errors.length) throw new Error(errors.join("\n"));
    fs.writeFileSync(path.join(capture, "browser-evidence.json"), JSON.stringify({
      url: base, status, result, invalidTokenRejected: true, draftPreserved: true,
      mobileOverflow: overflow, reloadRequiresToken: true, browserErrors: errors,
    }, null, 2));
    console.log("Browser smoke passed: real agent, authentication, polling, desktop, mobile, reload.");
  } finally { await browser.close(); }
})().catch((failure) => { console.error(failure); process.exitCode = 1; });
