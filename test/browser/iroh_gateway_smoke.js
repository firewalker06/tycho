// Uses only synthetic credentials from the isolated gateway fixture on stdin.
const fs = require('fs');
const path = require('path');
const { chromium } = require(process.env.TYCHO_PLAYWRIGHT_PATH);
(async () => {
  const input = JSON.parse(fs.readFileSync(0, 'utf8'));
  const browser = await chromium.launch({ executablePath: '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome', headless: true });
  try {
    for (const [name, viewport] of [['desktop', { width: 1440, height: 900 }], ['mobile', { width: 390, height: 844 }]]) {
      const context = await browser.newContext({ viewport, ignoreHTTPSErrors: true });
      // Fixture certificate only. Python independently verifies TLS using its fixture CA.
      const page = await context.newPage();
      await page.goto(input.origin + '/ui', { waitUntil: 'domcontentloaded' });
      await page.waitForFunction(() => typeof brokerGet === 'function');
      const denied = await page.evaluate(async () => (await fetch('/agents')).status);
      if (denied !== 401) throw new Error('Missing bearer was not rejected');
      await page.evaluate(token => localStorage.setItem('hq.remote.token', token), input.token);
      await page.reload({ waitUntil: 'domcontentloaded' });
      await page.waitForFunction(() => typeof brokerGet === 'function');
      await page.locator('#tycho-boot-shell').waitFor({ state: 'hidden', timeout: 20000 });
      const facts = await page.evaluate(async () => {
        const data = await brokerGet('/agents');
        return { agents: data.agents.length, overflow: document.documentElement.scrollWidth > innerWidth, title: document.title };
      });
      if (facts.agents !== 0 || facts.overflow) throw new Error('Fixture UI failed');
      await page.screenshot({ path: path.join(input.output, name + '.png'), fullPage: false });
      console.log(JSON.stringify({ viewport: name, authorizedThroughRealIroh: true, missingBearer401: true, ...facts }));
      await context.close();
    }
  } finally { await browser.close(); }
})().catch(error => { console.error(error.message); process.exit(1); });
