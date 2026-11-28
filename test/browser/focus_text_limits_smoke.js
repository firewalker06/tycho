const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const crypto = require("node:crypto");

module.exports = async ({ browser, baseUrl, captureDir, metadataFixture }) => {
  const results = [];
  const assets = path.resolve(__dirname, "../../lib/hq/remote_ui/assets");
  const digest = value => crypto.createHash("sha256").update(value).digest("hex");
  let assetProof;

  for (const width of [320, 390, 1440]) {
    const context = await browser.newContext({ viewport: { width, height: 1000 }, hasTouch: true });
    try {
      if (!assetProof) {
        const js = await (await context.request.get(`${baseUrl}/ui.js`)).text();
        const css = await (await context.request.get(`${baseUrl}/ui.css`)).text();
        const expected = ["prompt_submissions.js", "inquiry_submissions.js", "now_mascot.js", "app.js"].map(name => fs.readFileSync(path.join(assets, name), "utf8")).join("\n");
        assert.equal(js, expected, "served JavaScript must match checkout");
        assert(css.includes(fs.readFileSync(path.join(assets, "app.css"), "utf8")), "served app CSS must match checkout");
        assetProof = { browserVersion: browser.version(), jsSha256: digest(js), cssSha256: digest(css), matchesCheckout: true };
      }
      const created = await context.request.post(`${baseUrl}/agents`, { data: {
        project_key: "web", name: "Synthetic text limits", prompt: "Fixture only", agent: "codex",
      } });
      assert(created.ok());
      const key = (await created.json()).agent.key;
      const api = `${baseUrl}/agents/${key}/focus`;
      const stored = JSON.parse(fs.readFileSync(path.join(metadataFixture.logsDir, "managed_agents.json"))).find(agent => agent.key === key);
      const file = stored.log_path.replace(/\.raw\.log$/, ".focus.json");
      const legacy = [{ title: "\r\n" + "Legacy group heading ".repeat(8) + "\r\nLast line", subtitle: "\r\n" + "Group description ".repeat(10) + "\r\nLast line", icon: "note", items: [
        { title: "Legacy task heading ".repeat(8) + "\r\nLast line", subtitle: "Task description ".repeat(10) + "\r\nLast line", attachments: [] },
      ] }];
      // Seed only the isolated saved file: new overlong API writes must fail.
      fs.writeFileSync(file, JSON.stringify({ revision: 1, updated_at: null, sections: legacy }));
      const read = async () => (await (await context.request.get(api)).json()).focus;
      assert.deepEqual((await read()).sections, legacy);
      const page = await context.newPage();
      page.setDefaultTimeout(8000);
      await page.goto(`${baseUrl}/ui#agent/${key}`, { waitUntil: "networkidle" });
      if (!await page.locator("[data-agent-focus]").isVisible()) await page.locator('[data-side-conversation="focus"]').click();
      await page.locator('[data-focus-edit-item="0:0"]').waitFor({ state: "visible" });
      const counts = await page.evaluate(() => ["a", "😀", "e\u0301", "👩‍💻"].flatMap(unit => ["title", "subtitle"].map(field => {
        const limit = field === "title" ? 40 : 60;
        const value = Array.from(unit.repeat(limit)).slice(0, limit).join("");
        return { accepted: focusTextLimitMessage(value, field) === "", rejected: focusTextLimitMessage(value + "x", field).includes(`${limit} characters`) };
      })));
      assert(counts.every(result => result.accepted && result.rejected), "client must count code points, including combining marks and ZWJ");
      const clamped = await page.locator(".agent-focus-section-copy .agent-focus-text-trigger > span, .agent-focus-item-text > strong, .agent-focus-item-text > span").evaluateAll(elements => elements.map(element => {
        const style = getComputedStyle(element), rect = element.getBoundingClientRect();
        return { text: element.textContent, clamp: style.webkitLineClamp, overflow: style.overflow, height: rect.height, fontSize: parseFloat(style.fontSize), hiddenLines: element.scrollHeight > element.clientHeight };
      }));
      assert.equal(clamped.length, 4);
      for (const entry of clamped) {
        assert.equal(entry.clamp, "2");
        assert.equal(entry.overflow, "hidden");
        assert(entry.height <= entry.fontSize * 3.5, "each field must use at most two lines");
        assert(entry.hiddenLines, "legacy fixture must actually overflow the clamp");
      }
      assert.equal(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth), true);
      if (captureDir) {
        fs.mkdirSync(captureDir, { recursive: true });
        await page.screenshot({ path: path.join(captureDir, `focus-text-legacy-${width}.png`) });
      }
      const waitForWrites = () => page.waitForFunction(key => {
        const queue = state.agentFocusWriteQueues.get(key);
        return !queue || (!queue.running && queue.pending.length === 0);
      }, key);
      const edit = async item => {
        await page.locator(item ? '[data-focus-edit-item="0:0"]' : '[data-focus-edit-group="0"]').click();
        const form = page.locator("[data-focus-edit-form]");
        await form.waitFor();
        return form;
      };
      let puts = 0;
      page.on("request", request => { if (request.url() === api && request.method() === "PUT") puts += 1; });
      for (const item of [false, true]) {
        const original = item ? legacy[0].items[0] : legacy[0];
        let form = await edit(item);
        assert.equal(await form.locator('[name="title"]').inputValue(), original.title.replace(/\r\n/g, "\n"));
        assert.equal(await form.locator('[name="subtitle"]').inputValue(), original.subtitle.replace(/\r\n/g, "\n"));
        assert.equal(await form.locator("[maxlength]").count(), 0, "editor must not silently cut off legacy text");
        if (captureDir) await page.screenshot({ path: path.join(captureDir, `focus-text-${item ? "item" : "group"}-editor-${width}.png`) });
        await form.locator('[name="subtitle"]').fill("Changed description");
        await form.locator('[name="subtitle"]').press("Enter");
        await page.locator("[data-focus-edit-form]").waitFor({ state: "detached" });
        await waitForWrites();
        let focus = await read();
        assert.equal((item ? focus.sections[0].items[0] : focus.sections[0]).title, original.title, "unrelated edit preserves exact legacy title and CRLF");
        form = await edit(item);
        for (const [field, limit] of [["title", 40], ["subtitle", 60]]) {
          const input = form.locator(`[name="${field}"]`);
          const previousPuts = puts;
          await input.fill("😀".repeat(limit + 1));
          assert.match(await input.evaluate(element => element.validationMessage), new RegExp(`${limit} characters`));
          await input.press("Enter");
          assert.equal(puts, previousPuts, "client must reject changed overlong text before PUT");
          assert.equal(Array.from(await input.inputValue()).length, limit + 1, "invalid draft must stay complete");
          // Switching entries must not discard an invalid draft.
          if (field === "title") {
            await page.locator(item ? '[data-focus-edit-group="0"]' : '[data-focus-edit-item="0:0"]').click();
            assert.equal(await input.inputValue(), "😀".repeat(limit + 1));
          }
          await input.fill("😀".repeat(limit));
          assert.equal(await input.evaluate(element => element.validationMessage), "");
        }
        await form.locator('[name="subtitle"]').press("Enter");
        await page.locator("[data-focus-edit-form]").waitFor({ state: "detached" });
        await waitForWrites();
        focus = await read();
        const target = item ? focus.sections[0].items[0] : focus.sections[0];
        assert.equal(target.title, "😀".repeat(40));
        assert.equal(target.subtitle, "😀".repeat(60));
        for (const [field, limit] of [["title", 40], ["subtitle", 60]]) {
          const invalid = JSON.parse(JSON.stringify(focus.sections));
          (item ? invalid[0].items[0] : invalid[0])[field] += "x";
          const before = fs.readFileSync(file, "utf8");
          const response = await context.request.put(api, { data: { revision: focus.revision, sections: invalid } });
          assert.equal(response.status(), 422);
          assert.match(await response.text(), new RegExp(`${limit} characters`));
          assert.equal(fs.readFileSync(file, "utf8"), before, "API rejection must not truncate or write");
        }
      }
      let focus = await read();
      page.once("dialog", dialog => dialog.accept("x".repeat(41)));
      await page.locator('[data-focus-add-item="0"]').click();
      assert.deepEqual(await read(), focus, "add-item prompt must reject 41 characters without truncation");
      const padded = " " + "n".repeat(38) + " ";
      page.once("dialog", dialog => dialog.accept(padded));
      await page.locator('[data-focus-add-item="0"]').click();
      await waitForWrites();
      focus = await read();
      assert.equal(focus.sections[0].items[1].title, padded, "accepted text must retain leading and trailing spaces");
      if (captureDir) await page.screenshot({ path: path.join(captureDir, `focus-text-boundaries-${width}.png`) });
      results.push({ width, legacyFields: clamped.length, uiBoundaries: "pass", apiBoundaries: "pass", noTruncation: true });
    } finally {
      await context.close();
    }
  }
  if (captureDir) {
    fs.writeFileSync(path.join(captureDir, "focus-text-results.json"), JSON.stringify(results, null, 2));
    fs.writeFileSync(path.join(captureDir, "focus-text-assets.json"), JSON.stringify(assetProof, null, 2));
  }
};
