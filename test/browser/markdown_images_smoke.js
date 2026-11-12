const assert = require("assert");
const path = require("path");

module.exports = async function markdownImagesSmoke({ browser, baseUrl, agentKey, captureDir }) {
  for (const width of [1440, 390]) for (const theme of ["dark", "light"]) for (const peer of [false, true]) {
    const page = await browser.newPage({ viewport: { width, height: 900 } });
    const errors = [];
    const imageRequests = [];
    let rejectImage = false;
    let holdImage = false;
    let releaseImage;
    page.on("pageerror", (error) => errors.push(error.message));
    await page.addInitScript((theme) => {
      localStorage.setItem("hq.remote.appearance", theme);
      window.revokedImages = [];
      const revoke = URL.revokeObjectURL.bind(URL);
      URL.revokeObjectURL = (url) => { window.revokedImages.push(url); revoke(url); };
    }, theme);
    await page.route("**/*", async (route) => {
      const url = new URL(route.request().url());
      assert.notStrictEqual(url.hostname, "example.test", "Markdown sent an external image request");
      if (peer && url.pathname === "/servers/resources") {
        const response = await route.fetch();
        const data = await response.json();
        const local = data.servers.find((server) => server.local);
        data.servers.push({ ...local, key: "fixture-peer", name: "Synthetic peer", local: false, url: baseUrl });
        return route.fulfill({ response, json: data });
      }
      if (url.pathname.endsWith("/workspace/image") || /\/attachments\/[^/]+\/blob$/.test(url.pathname)) {
        imageRequests.push({ resource: url.searchParams.get("path"), path: url.pathname, authorization: route.request().headers().authorization, peerToken: route.request().headers()["x-tycho-remote-server-token"] });
        if (url.searchParams.get("path") === "docs/local image.svg") {
          if (holdImage) await new Promise((resolve) => { releaseImage = resolve; });
          if (rejectImage) return route.fulfill({ status: 401, json: { error: "Unauthorized" } });
        }
      }
      if (url.pathname.startsWith("/servers/fixture-peer/")) {
        return route.fulfill({ response: await route.fetch({ url: `${baseUrl}${url.pathname.replace("/servers/fixture-peer", "")}${url.search}` }) });
      }
      return route.continue();
    });
    const detail = (await (await page.request.get(`${baseUrl}/agents/${agentKey}`)).json()).agent;
    const attachment = detail.attachments.find((item) => item.title === "Release review");
    const key = peer ? `fixture-peer/${agentKey}` : agentKey;
    const id = peer ? `fixture-peer/${attachment.id}` : attachment.id;
    const summaryUrl = `${baseUrl}/ui#agent/${encodeURIComponent(key)}/summary/preview-current`;
    const attachmentUrl = `${baseUrl}/ui#agent/${encodeURIComponent(key)}/attachment/${encodeURIComponent(id)}`;
    async function loaded(selector) {
      await page.waitForFunction((selector) => {
        const images = [...document.querySelectorAll(`${selector} img`)];
        return images.length === 2 && images.every((image) => image.complete && image.naturalWidth > 0 && image.src.startsWith("blob:"));
      }, selector);
      assert(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth), "horizontal overflow");
    }
    await page.goto(summaryUrl, { waitUntil: "networkidle" });
    await loaded(".summary-section-text");
    // The current Summary uses rich sections. The prior Summary uses the plain summary field.
    await page.goto(summaryUrl.replace("preview-current", "preview-prior"), { waitUntil: "networkidle" });
    await loaded(".agent-summary-markdown-viewer");
    await page.goto(summaryUrl, { waitUntil: "networkidle" });
    await loaded(".summary-section-text");
    const summaryImages = await page.locator(".summary-section-text img").evaluateAll((images) => images.map((image) => image.src));
    const name = `${width}-${theme}-${peer ? "peer" : "local"}`;
    if (captureDir) await page.screenshot({ path: path.join(captureDir, `summary-${name}.png`) });
    await page.goto(attachmentUrl, { waitUntil: "networkidle" });
    await page.locator(".markdown-viewer h1").waitFor();
    await loaded(".attachment-viewer .markdown-viewer");
    assert.strictEqual(await page.locator(".attachment-viewer .field-hint").filter({ hasText: "image unavailable" }).count(), 4);
    assert(await page.evaluate((urls) => urls.every((url) => window.revokedImages.includes(url)), summaryImages), "Summary blob URLs were not released");
    const composer = page.locator("#prompt-input");
    if (width === 1440) await composer.fill("Keep this draft");
    await page.evaluate(async () => refresh({ force: true, forceAttachment: true }));
    if (width === 1440) assert.strictEqual(await composer.inputValue(), "Keep this draft");
    await loaded(".attachment-viewer .markdown-viewer");
    if (captureDir) await page.screenshot({ path: path.join(captureDir, `attachment-${name}.png`) });
    assert(imageRequests.some((request) => request.path.includes("/workspace/image")), "relative image did not use workspace image API");
    assert(imageRequests.some((request) => request.path.includes("/attachments/")), "registered image did not use attachment blob API");
    assert(imageRequests.every((request) => request.path.startsWith(peer ? "/servers/fixture-peer/" : "/")), "image used another server");

    // Metadata contains literal URL punctuation. Every loaded image must be blue:
    // the root fallback is red and the denied private target is green.
    const reserved = detail.attachments.find((item) => item.title === "Reserved image paths");
    const reservedId = peer ? `fixture-peer/${reserved.id}` : reserved.id;
    await page.goto(`${baseUrl}/ui#agent/${encodeURIComponent(key)}/attachment/${encodeURIComponent(reservedId)}`, { waitUntil: "networkidle" });
    await page.waitForFunction(() => {
      const images = [...document.querySelectorAll(".attachment-viewer .markdown-viewer img")];
      return images.length === 6 && images.every((image) => image.complete && image.naturalWidth > 0);
    });
    const pixels = await page.locator(".attachment-viewer .markdown-viewer img").evaluateAll((images) => images.map((image) => {
      const canvas = document.createElement("canvas");
      canvas.width = canvas.height = 1;
      const context = canvas.getContext("2d");
      context.drawImage(image, 0, 0);
      return Array.from(context.getImageData(0, 0, 1, 1).data);
    }));
    assert.deepStrictEqual(pixels, Array(6).fill([46, 107, 204, 255]), "wrong root image or private bytes were displayed");
    assert.strictEqual(await page.locator(".attachment-viewer .field-hint").filter({ hasText: "image unavailable" }).count(), 3);
    assert(imageRequests.some((request) => request.resource === "docs #1 ? 100%/image.svg"), "document metadata was parsed as a URL");
    assert(imageRequests.some((request) => request.resource === "docs #1 ? 100%/image#?%.svg"), "Markdown reference was not decoded once");
    assert(imageRequests.some((request) => request.resource === "safe-internal.svg"));
    assert(imageRequests.some((request) => request.resource === "safe-docs/image.svg"));
    assert(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth), "reserved path overflow");
    if (captureDir) await page.screenshot({ path: path.join(captureDir, `reserved-paths-${name}.png`) });

    // Test sanitization in the same renderer used by both views. Only a fresh img with an
    // approved local resource can survive, even if raw HTML supplies application attributes.
    const security = await page.evaluate((key) => {
      const agent = findAgent(key);
      const fixture = '<img src="https://example.test/tracker.png" onerror="window.IMAGE_XSS=1"><img src="javascript:alert(1)"><img src="data:image/svg+xml,evil"><img src="file://evil.test/etc/passwd"><img src="/etc/passwd" data-markdown-image-path="/settings"><script>window.IMAGE_XSS=1</script>';
      const element = document.createElement("div");
      element.innerHTML = renderMarkdown(fixture, { imageContext: { agent } });
      return { images: element.querySelectorAll("img").length, scripts: element.querySelectorAll("script").length, executed: Boolean(window.IMAGE_XSS) };
    }, key);
    assert.deepStrictEqual(security, { images: 0, scripts: 0, executed: false });

    // An image read uses the same credential route as other resource reads. A rejected
    // read gives a visible fallback and an explicit refresh retries it after recovery.
    await page.evaluate((peer) => {
      setToken("synthetic-markdown-image-token");
      if (peer) safeLocalStorageSet(SERVER_TOKENS_STORAGE_KEY, JSON.stringify({ "fixture-peer": "synthetic-peer-image-token" }));
    }, peer);
    await page.goto(`${baseUrl}/ui#agent/${encodeURIComponent(key)}`, { waitUntil: "networkidle" });
    rejectImage = true;
    await page.goto(summaryUrl, { waitUntil: "networkidle" });
    await page.locator(".summary-section-text [data-markdown-image-error]").waitFor();
    rejectImage = false;
    await page.evaluate(async () => refresh({ force: true }));
    await loaded(".summary-section-text");
    assert(imageRequests.some((request) => request.authorization === "Bearer synthetic-markdown-image-token"), "image read omitted bearer authentication");
    if (peer) assert(imageRequests.some((request) => request.peerToken === "synthetic-peer-image-token"), "peer image read omitted peer credentials");

    // A delayed response must not add an image or retain a blob after navigation.
    await page.goto(`${baseUrl}/ui#agent/${encodeURIComponent(key)}`, { waitUntil: "networkidle" });
    holdImage = true;
    await page.goto(summaryUrl, { waitUntil: "domcontentloaded" });
    await page.waitForFunction(() => document.querySelector(".summary-section-text img"));
    for (let attempt = 0; !releaseImage && attempt < 100; attempt += 1) await page.waitForTimeout(20);
    assert(releaseImage, "image request was not held");
    await page.goto(`${baseUrl}/ui#agent/${encodeURIComponent(key)}`, { waitUntil: "domcontentloaded" });
    await page.waitForFunction(() => !document.querySelector(".summary-section-text"));
    releaseImage();
    await page.waitForTimeout(150);
    assert.strictEqual(await page.evaluate(() => markdownImageResources.size), 0, "late image response retained a resource after navigation");
    assert.deepStrictEqual(errors, []);
    console.log(`Markdown images: ${name}: rich/plain Summary, reserved metadata, decoded-once references, safe/private symlinks, pixels, auth retry, polling, URL cleanup and late response passed`);
    await page.close();
  }
};
