// Open the Focus menu before activating an action hidden inside it.
module.exports = async (locator, options = {}) => {
  let target = locator;
  if (await target.count() > 1) {
    for (const candidate of await target.all()) {
      if (await candidate.isVisible()) { target = candidate; break; }
      const menu = candidate.locator('xpath=ancestor::details[contains(@class,"agent-focus-mobile-menu")]');
      if (await menu.count() && await menu.locator('summary').isVisible()) { target = candidate; break; }
    }
  }
  const menu = target.locator('xpath=ancestor::details[contains(@class,"agent-focus-mobile-menu")]');
  if (await menu.count() && !await menu.evaluate(element => element.open)) {
    await menu.locator('summary').click();
  }
  await target.click(options);
};
