const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");

module.exports = async ({ page, baseUrl, agentKey, captureDir, theme, width, record }) => {
  const id = `${theme}-${width}-interaction`;
  const observations = [];
  const check = (name, value) => {
    record(`${id}:${name}`, Number(value), "eq", 1);
    observations.push({ name, passed: Boolean(value) });
    assert(value, name);
  };
  // Local browser-only clipboard, never the operator's clipboard.
  await page.evaluate(() => Object.defineProperty(navigator, "clipboard", {
    configurable: true, value: { writeText: async value => { window.subtitleCopiedSession = value; } },
  }));
  const toggle = page.locator("#subtitle-gallery [data-toggle-agent-tree]");
  await toggle.scrollIntoViewIfNeeded();
  await toggle.focus();
  await toggle.press("Enter");
  const children = page.locator("#subtitle-gallery .agent-delegation-children");
  check("keyboard-expand", await children.isVisible() && await toggle.getAttribute("aria-expanded") === "true");
  check("keyboard-focus", await toggle.evaluate(el => el === document.activeElement && el.matches(":focus-visible") && getComputedStyle(el).outlineStyle !== "none"));
  const child = await children.locator(".agent-block-subtitle").evaluate(el => ({ height: el.getBoundingClientRect().height, line: parseFloat(getComputedStyle(el).lineHeight), scroll: el.scrollWidth, width: el.clientWidth }));
  check("expanded-child-one-line", Math.abs(child.height - child.line) <= 1 && child.scroll > child.width);
  await toggle.press("Space");
  check("keyboard-collapse", !await children.isVisible() && await toggle.getAttribute("aria-expanded") === "false");
  if (width === 320) await toggle.tap(); else await toggle.click();
  check("pointer-expand", await children.isVisible());
  const archive = page.locator("#subtitle-gallery [data-archive-delegate]");
  await archive.focus(); await archive.press("Space");
  check("archive-uncheck", !await archive.isChecked() && await page.evaluate(key => state.archiveDelegateExclusions.get(parseRoute().key)?.has(key), agentKey));
  await archive.press("Space");
  check("archive-recheck", await archive.isChecked());

  // Selecting through the real change handler replaces the gallery with the real list.
  await page.evaluate(() => { state.bulkArchiveMode = true; });
  const selection = page.locator(`#subtitle-gallery [data-select-agent="${agentKey}"]`);
  await selection.focus(); await selection.press("Space");
  const selected = page.locator(`#view [data-select-agent="${agentKey}"]`);
  await selected.waitFor();
  check("bulk-keyboard-select", await selected.isChecked());
  const filter = page.getByRole("searchbox", { name: "Filter agents and projects" });
  const name = await page.evaluate(key => findAgent(key).name, agentKey);
  await filter.fill(name);
  await filter.focus();
  await page.evaluate(() => refresh({ force: true }));
  check("refresh-retains-selection", await selected.isChecked());
  check("refresh-retains-filter-focus", await filter.inputValue() === name && await filter.evaluate(el => el === document.activeElement));
  await selected.focus(); await selected.press("Space");
  check("bulk-keyboard-clear", !await selected.isChecked());
  await page.evaluate(() => cancelBulkArchiveMode());
  const row = page.locator(`#view .agent-row[data-open-agent="${agentKey}"]`);
  if (width === 320) await row.tap(); else await row.click();
  await page.locator("#prompt-input").waitFor();
  check("row-navigation", await page.evaluate(key => parseRoute().type === "agent" && parseRoute().key === key, agentKey));
  await page.locator("#prompt-input").fill("Retained synthetic subtitle draft");
  const copy = page.getByRole("button", { name: "Copy Session ID", exact: true });
  await copy.focus(); await copy.press("Enter");
  await page.waitForFunction(key => window.subtitleCopiedSession === key, agentKey);
  check("keyboard-copy-session", await page.evaluate(key => window.subtitleCopiedSession === key, agentKey));
  const more = page.locator("#header-more-button");
  await more.focus(); await more.press("Enter");
  check("keyboard-header-menu", await more.getAttribute("aria-expanded") === "true");
  await page.keyboard.press("Escape");
  check("menu-restores-focus", await more.getAttribute("aria-expanded") === "false" && await more.evaluate(el => el === document.activeElement));
  await page.evaluate(() => refresh({ force: true }));
  check("refresh-retains-composer", await page.locator("#prompt-input").inputValue() === "Retained synthetic subtitle draft");
  await page.screenshot({ path: path.join(captureDir, `${id}-detail.png`) });

  await page.goto(`${baseUrl}/ui#agents`, { waitUntil: "networkidle" });
  await page.locator(".agent-row").first().waitFor();
  await page.evaluate(key => {
    const host = document.createElement("section"); host.id = "subtitle-reference-interaction";
    host.innerHTML = renderAgentReference({ key, state: "active", status: "succeeded", name: "Synthetic reference" }, { projectName: "Long synthetic reference metadata ".repeat(30) });
    document.querySelector("#view").prepend(host);
  }, agentKey);
  const link = page.locator("#subtitle-reference-interaction a");
  await link.focus();
  check("reference-accessible-name", Boolean(await link.getAttribute("aria-label")));
  const snapshot = await link.ariaSnapshot();
  check("reference-full-accessibility", snapshot.includes("Long synthetic reference metadata ".repeat(30).trim()));
  await link.press("Enter");
  await page.locator("#prompt-input").waitFor();
  check("reference-keyboard-navigation", await page.evaluate(key => parseRoute().key === key && parseRoute().type === "agent", agentKey));
  fs.writeFileSync(path.join(captureDir, `${id}.json`), JSON.stringify(observations, null, 2));
};
