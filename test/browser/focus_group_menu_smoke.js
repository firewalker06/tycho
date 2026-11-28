const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");

// Use synthetic Focus data against an isolated Remote UI server.
module.exports = async ({ browser, baseUrl, captureDir }) => {
  for (const width of [320, 390, 1440]) {
    const context = await browser.newContext({ viewport: { width, height: 1000 }, hasTouch: true });
    try {
      const created = await context.request.post(`${baseUrl}/agents`, { data: {
        project_key: "web", name: "Synthetic group menu", prompt: "Fixture only", agent: "codex",
      } });
      assert(created.ok());
      const key = (await created.json()).agent.key;
      const api = `${baseUrl}/agents/${key}/focus`;
      const saved = await context.request.put(api, { data: { revision: 0, sections: [
        { title: "Active group", subtitle: "A wrapped subtitle for the group controls", items: [{ title: "First item" }] },
        { title: "Completed group", completed: true, items: [{ title: "Finished item", completed: true }] },
      ] } });
      assert(saved.ok());
      const page = await context.newPage();
      page.setDefaultTimeout(8000);
      await page.goto(`${baseUrl}/ui#agent/${key}`, { waitUntil: "networkidle" });
      if (!await page.locator('[data-agent-focus]').isVisible()) await page.locator('[data-side-conversation="focus"]').click();
      const waitForWrites = () => page.waitForFunction(key => {
        const queue = state.agentFocusWriteQueues.get(key);
        return !queue || (!queue.running && queue.pending.length === 0);
      }, key);
      const menu = page.locator('.agent-focus-group-menu').first();
      const trigger = menu.locator('summary');
      await trigger.waitFor({ state: "visible" });
      assert.equal(await page.locator('.agent-focus-section-toggle').count(), 0);
      const geometry = await page.locator('.agent-focus-section').first().evaluate(section => {
        const add = section.querySelector('[data-focus-add-item]');
        const box = add.getBoundingClientRect();
        const circle = getComputedStyle(add, '::before');
        const rail = getComputedStyle(section, '::before');
        const rect = section.getBoundingClientRect();
        const trigger = getComputedStyle(section.querySelector('summary'));
        return { label: add.getAttribute('aria-label'), width: box.width, height: box.height,
          center: box.x + box.width / 2, rail: rect.x + parseFloat(rail.left) + parseFloat(rail.width) / 2,
          radius: circle.borderRadius, circleBorder: circle.borderTopWidth, border: trigger.borderTopWidth };
      });
      assert.equal(geometry.label, "Add item");
      assert(geometry.width >= 44 && geometry.height >= 44);
      assert(Math.abs(geometry.center - geometry.rail) < 0.1);
      assert.equal(geometry.radius, "50%");
      assert.equal(geometry.circleBorder, "2px");
      assert.equal(geometry.border, "0px");
      await trigger.click();
      await page.evaluate(() => refresh({ force: true }));
      await menu.locator('[role=menuitem]').first().waitFor({ state: "visible" });
      const menuFits = await menu.evaluate(element => {
        const rect = element.querySelector('.agent-focus-mobile-menu-popover').getBoundingClientRect();
        return rect.x >= 0 && rect.right <= innerWidth && rect.y >= 0 && rect.bottom <= innerHeight;
      });
      assert(menuFits, "open group menu fits after refresh");
      const disclosure = menu.locator('[data-focus-section]');
      assert.match(await disclosure.innerText(), /Collapse group \(1 items\)/);
      await disclosure.click();
      await trigger.click();
      assert.match(await disclosure.innerText(), /Expand group \(1 items\)/);
      await disclosure.click();
      await trigger.click();
      await menu.locator('[data-focus-complete-group]').click();
      await page.waitForFunction(() => document.querySelectorAll('.agent-focus-completed .agent-focus-section').length === 2);
      await waitForWrites();
      const completedMenu = page.locator('.agent-focus-completed .agent-focus-group-menu').first();
      await completedMenu.locator('summary').click();
      await completedMenu.getByRole('menuitem', { name: 'Reopen group' }).click();
      await page.waitForFunction(() => document.querySelectorAll('.agent-focus-completed .agent-focus-section').length === 1);
      await waitForWrites();
      const active = page.locator('.agent-focus-sections .agent-focus-group-menu').first();
      await active.locator('summary').tap();
      await active.getByRole('menuitem', { name: 'Delete group' }).tap();
      await page.locator('[data-confirmation-cancel]').tap();
      await page.waitForFunction(() => document.activeElement?.matches('.agent-focus-group-menu > summary'));
      assert.equal((await (await context.request.get(api)).json()).focus.sections.length, 2);
      await active.locator('summary').press('Enter');
      await page.waitForFunction(() => document.activeElement?.matches('.agent-focus-group-menu [role=menuitem]'));
      await active.locator('[role=menuitem]').first().press('End');
      assert.equal(await active.getByRole('menuitem', { name: 'Delete group' }).evaluate(e => e === document.activeElement), true);
      await page.keyboard.press('Escape');
      await page.waitForFunction(() => document.activeElement?.matches('.agent-focus-group-menu > summary'));
      if (captureDir) {
        fs.mkdirSync(captureDir, { recursive: true });
        await active.locator('summary').click();
        await page.screenshot({ path: path.join(captureDir, `group-menu-${width}.png`) });
      } else await active.locator('summary').click();
      await active.getByRole('menuitem', { name: 'Delete group' }).click();
      await page.locator('[data-confirmation-accept]').click();
      await page.waitForFunction(() => document.querySelectorAll('.agent-focus-section').length === 1);
      await waitForWrites();
      assert.equal((await (await context.request.get(api)).json()).focus.sections.length, 1);
    } finally {
      await context.close();
    }
  }
};
