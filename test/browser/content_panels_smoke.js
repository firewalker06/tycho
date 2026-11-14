const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");

module.exports = async function contentPanelsSmoke({ browser, baseUrl, agentKey, captureDir }) {
  const results = [];
  const stateResults = [];
  for (const theme of ["dark", "light"]) {
    const page = await browser.newPage({ viewport: { width: 1320, height: 900 } });
    const errors = [];
    const frames = () => page.evaluate(() => new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve))));
    page.on("pageerror", error => errors.push(error.message));
    await page.addInitScript(theme => localStorage.setItem("hq.remote.appearance", theme), theme);
    const url = `${baseUrl}/ui#agent/${agentKey}/summary/preview-prior`;
    await page.goto(url, { waitUntil: "networkidle" });
    // Use the application's theme API, and seed a long synthetic conversation.
    await page.evaluate(({ theme, agentKey }) => {
      window.TychoAppearance.setPreference(theme);
      const blocks = state.conversations[agentKey]?.blocks;
      if (blocks) blocks.push(...Array.from({ length: 30 }, (_, i) => ({ kind: "message", role: "user", content: `Synthetic panel check ${i}: Keep this conversation position.` })));
      render();
    }, { theme, agentKey });
    const open = page.locator(".agent-detail-pane [data-preview-summary-attachment]").first();
    const toggle = key => page.locator(`[data-toggle-content-panel="${key}"]`);
    const panel = key => page.locator({ conversation: ".agent-conversation-pane", summary: ".agent-detail-pane", preview: ".summary-attachment-preview-pane" }[key]);
    const measure = () => page.evaluate(() => {
      const root = document.querySelector(".agent-workspace");
      const nav = document.querySelector("#bottom-nav");
      const selected = nav.querySelector("button.active");
      const style = getComputedStyle(selected);
      const rgb = color => {
        const context = document.createElement("canvas").getContext("2d");
        context.fillStyle = color;
        context.fillRect(0, 0, 1, 1);
        return [...context.getImageData(0, 0, 1, 1).data].slice(0, 3);
      };
      const luminance = color => rgb(color).map(value => value / 255)
        .map(value => value <= 0.04045 ? value / 12.92 : ((value + 0.055) / 1.055) ** 2.4)
        .reduce((sum, value, index) => sum + value * [0.2126, 0.7152, 0.0722][index], 0);
      const contrast = (a, b) => (Math.max(luminance(a), luminance(b)) + 0.05) / (Math.min(luminance(a), luminance(b)) + 0.05);
      const palette = getComputedStyle(document.documentElement);
      const navStyle = getComputedStyle(nav);
      const sidebar = { visible: nav.getClientRects().length > 0, width: nav.getBoundingClientRect().width,
        frame: [navStyle.borderTopWidth, navStyle.borderRightWidth, navStyle.borderBottomWidth, navStyle.borderLeftWidth],
        selectedLabel: selected.getAttribute("aria-label"), current: selected.getAttribute("aria-current"),
        shadow: style.boxShadow, leftWidth: style.borderLeftWidth, rightWidth: style.borderRightWidth,
        leftColor: style.borderLeftColor, rightColor: style.borderRightColor,
        fillContrast: contrast(style.backgroundColor, palette.getPropertyValue("--ds-background-canvas")),
        textContrast: contrast(style.color, style.backgroundColor),
        focusContrast: contrast(palette.getPropertyValue("--ds-focus-ring"), style.backgroundColor) };
      const workspace = root.getBoundingClientRect();
      const headings = [...root.querySelectorAll("[data-content-panel-heading]")].map(heading => {
        const button = heading.querySelector("[data-toggle-content-panel]");
        const label = heading.querySelector(".content-panel-label");
        const rect = heading.getBoundingClientRect();
        const labelRect = label.getBoundingClientRect();
        const target = document.getElementById(button.getAttribute("aria-controls"));
        return { key: heading.dataset.contentPanelHeading, collapsed: heading.classList.contains("is-collapsed"),
          expanded: button.getAttribute("aria-expanded"), collapseUnavailable: button.getAttribute("aria-disabled") === "true", name: button.getAttribute("aria-label"), tooltip: button.title,
          targetVisible: target?.getClientRects().length > 0, targetExists: Boolean(target),
          x: rect.x, right: rect.right, top: rect.top, bottom: rect.bottom, width: rect.width, height: rect.height,
          topBorder: getComputedStyle(heading).borderTopWidth, bottomBorder: getComputedStyle(heading).borderBottomWidth, sideBorders: [getComputedStyle(heading).borderLeftWidth, getComputedStyle(heading).borderRightWidth], radius: getComputedStyle(heading).borderRadius, toggleRadius: getComputedStyle(button).borderRadius,
          labelWidth: labelRect.width, labelHeight: labelRect.height };
      });
      return { sidebar, headings, workspace: { top: workspace.top, bottom: workspace.bottom, height: workspace.height }, width: innerWidth, usable: root.clientWidth, visible: root.dataset.visiblePanels?.split(" "), overflow: document.documentElement.scrollWidth > innerWidth,
        panels: [...root.querySelectorAll(":scope > .agent-conversation-pane, :scope > .agent-detail-pane, :scope > .summary-attachment-preview-pane")].filter(el => el.getClientRects().length).map(el => { const r = el.getBoundingClientRect(); return { x: r.x, right: r.right, width: r.width, bottom: r.bottom }; }) };
    });
    const check = async count => {
      const layout = await measure();
      assert.equal(layout.visible.length, count, JSON.stringify(layout));
      assert(!layout.overflow, JSON.stringify(layout));
      assert.equal(layout.panels.length, count, JSON.stringify(layout));
      for (let i = 0; i < count; i++) {
        assert(layout.panels[i].width >= (count === 1 ? 340 : layout.visible[i] === "conversation" ? 380 : 440), JSON.stringify(layout));
        assert(layout.panels[i].right <= layout.width + 1, JSON.stringify(layout));
        assert(layout.panels[i].bottom <= 901, JSON.stringify(layout));
        if (i) assert(layout.panels[i - 1].right <= layout.panels[i].x, JSON.stringify(layout));
      }
      assert.deepEqual(layout.headings.map(heading => heading.key), ["conversation", "summary", "preview"], "Accordion slots must keep their panel order");
      for (const [index, heading] of layout.headings.entries()) {
        const expanded = layout.visible.includes(heading.key);
        if (!expanded) {
          assert.equal(heading.topBorder, "0px", "Collapsed strips must join the header without a top border");
          assert.equal(heading.bottomBorder, "0px", "Collapsed strips must have no bottom border");
          assert.deepEqual(heading.sideBorders, ["1px", "1px"], "Collapsed strips must retain side separators");
          assert.equal(heading.radius, "0px", "Collapsed strip corners must be square");
          assert.equal(heading.toggleRadius, "0px", "Collapsed toggle corners must be square");
        }
        assert.equal(heading.expanded, String(expanded));
        assert.equal(heading.collapsed, !expanded);
        assert.equal(heading.targetVisible, expanded);
        assert(heading.targetExists && heading.name.includes(expanded ? "Collapse" : "Expand"));
        assert.equal(heading.collapseUnavailable, expanded && count === 1);
        if (heading.collapseUnavailable) assert(heading.tooltip.includes("must remain expanded"), "Unavailable collapse must explain why the panel stays expanded");
        else assert.equal(heading.tooltip, heading.name);
        if (index) assert(layout.headings[index - 1].right <= heading.x, "Panel headers and strips must remain at distinct panel positions");
        if (!expanded) {
          assert(Math.abs(heading.width - 48) <= 1, `Collapsed strip width: ${JSON.stringify(heading)}`);
          assert(Math.abs(heading.top - layout.workspace.top) <= 1 && Math.abs(heading.bottom - layout.workspace.bottom) <= 1, `Collapsed strip must fill workspace height: ${JSON.stringify(heading)}`);
          assert(heading.labelHeight > heading.labelWidth * 2, "Collapsed panel name must have a vertical presentation");
        }
      }
      if (layout.width >= 1100) {
        assert.equal(Math.round(layout.sidebar.width), 56, "Combined split must retain the icon rail");
        assert(layout.sidebar.visible && layout.sidebar.frame.every(width => width === "0px"), "Rail must have no outer frame");
        assert.equal(layout.sidebar.selectedLabel, "Agents");
        assert.equal(layout.sidebar.current, "page");
        assert.equal(layout.sidebar.shadow, "none", "Selected rail item must have no left shadow");
        assert.equal(layout.sidebar.leftWidth, layout.sidebar.rightWidth, "Selected rail item must have no thicker left border");
        assert.equal(layout.sidebar.leftColor, layout.sidebar.rightColor, "Selected rail item must have no separate left border color");
        if (theme === "light") {
          assert(layout.sidebar.fillContrast >= 1.15, "Light selected fill must remain distinct from canvas");
          assert(layout.sidebar.textContrast >= 4.5, "Light selected text must remain readable");
          assert(layout.sidebar.focusContrast >= 3, "Light focus ring must retain contrast");
        }
      } else assert(!layout.sidebar.visible, "Existing tablet/mobile navigation must stay hidden on a split route");
      results.push({ theme, ...layout });
    };
    const capture = async name => { if (captureDir) await page.screenshot({ path: path.join(captureDir, `content-panels-${name}-${theme}.png`) }); };
    const composer = page.locator("#composer textarea");
    await composer.fill("Keep this unsent panel draft.");
    await page.evaluate(() => { document.querySelector(".agent-conversation-scroll").scrollTop = 180; });
    await open.click();
    await page.waitForFunction(() => document.querySelector(".summary-attachment-preview-scroll")?.getAttribute("aria-busy") === "false");
    await check(2);
    assert(await panel("preview").isVisible());
    assert(await panel("summary").isVisible());
    assert.equal(await page.evaluate(() => parseRoute().summaryId), "preview-prior");
    await toggle("conversation").focus();
    assert(await toggle("conversation").evaluate(button => {
      const event = new KeyboardEvent("keydown", { key: "ArrowRight", ctrlKey: true, bubbles: true, cancelable: true });
      button.dispatchEvent(event);
      return !event.defaultPrevented && button === document.activeElement;
    }), "Accordion keys must not take modified browser shortcuts");
    await page.keyboard.press("ArrowRight");
    assert(await toggle("summary").evaluate(button => button === document.activeElement), "Right arrow must focus the next panel control");
    await page.keyboard.press("ArrowLeft");
    assert(await toggle("conversation").evaluate(button => button === document.activeElement), "Left arrow must focus the previous panel control");
    await page.keyboard.press("End");
    assert(await toggle("preview").evaluate(button => button === document.activeElement), "End must focus the last panel control");
    await page.keyboard.press("Home");
    assert(await toggle("conversation").evaluate(button => button === document.activeElement), "Home must focus the first panel control");
    const stripFocus = await toggle("conversation").evaluate(button => {
      const style = getComputedStyle(button);
      const bounds = button.getBoundingClientRect();
      const clip = button.closest(".content-panel-heading").getBoundingClientRect();
      const outside = parseFloat(style.outlineOffset) + parseFloat(style.outlineWidth);
      return { active: button === document.activeElement, visible: button.matches(":focus-visible"),
        width: parseFloat(style.outlineWidth), style: style.outlineStyle, offset: parseFloat(style.outlineOffset),
        contained: bounds.left - outside >= clip.left && bounds.right + outside <= clip.right && bounds.top - outside >= clip.top && bounds.bottom + outside <= clip.bottom };
    });
    assert(stripFocus.active && stripFocus.visible && stripFocus.width >= 2 && stripFocus.style === "solid" && stripFocus.contained,
      `Keyboard outline must remain inside the collapsed strip: ${JSON.stringify({ theme, ...stripFocus })}`);
    stateResults.push({ theme, case: "unclipped-collapsed-keyboard-outline", ...stripFocus });
    await capture("constrained-focus");
    await page.keyboard.press("Space");
    assert.equal(await panel("conversation").locator(".agent-conversation-scroll").evaluate(element => element.scrollTop), 180, "First preview must preserve Conversation position before any poll");
    assert.equal(await composer.inputValue(), "Keep this unsent panel draft.");
    stateResults.push({ theme, case: "first-preview-before-poll", conversationScroll: 180 });
    await page.locator("[data-restore-content-panels]").click();
    await check(2);
    await page.locator("[data-close-summary-attachment-preview]").click();
    assert.equal(await panel("conversation").locator(".agent-conversation-scroll").evaluate(element => element.scrollTop), 180, "Closing the preview must also restore the hidden Conversation position");
    assert.equal(await composer.inputValue(), "Keep this unsent panel draft.");
    await open.click();
    await page.waitForFunction(() => document.querySelector(".summary-attachment-preview-scroll")?.getAttribute("aria-busy") === "false");
    await check(2);
    await capture("constrained");
    await page.evaluate(() => { document.querySelector(".agent-detail-pane").scrollTop = 120; });
    await toggle("conversation").focus();
    await page.keyboard.press("Enter");
    await check(2);
    assert(await panel("conversation").isVisible());
    assert(!(await panel("summary").isVisible()));
    assert.equal(await composer.inputValue(), "Keep this unsent panel draft.");
    await page.evaluate(() => {
      document.querySelector(".agent-conversation-scroll").scrollTop = 140;
      document.querySelector(".summary-attachment-preview-scroll").scrollTop = 380;
    });
    const saved = await page.evaluate(() => [document.querySelector(".agent-conversation-scroll").scrollTop, document.querySelector(".summary-attachment-preview-scroll").scrollTop]);
    assert(saved[0] > 0 && saved[1] > 0, `Fixture must scroll: ${saved}`);
    // Native scroll anchoring can add one line (17 px) after an asynchronous reflow.
    // Prove that control case, then check the application's default scrolling behavior.
    for (const mode of ["auto", "default"]) {
      const scroll = page.locator(".summary-attachment-preview-scroll");
      await scroll.evaluate((element, mode) => {
        if (mode === "auto") element.style.overflowAnchor = "auto";
        else element.style.removeProperty("overflow-anchor");
        element.querySelector("h1").style.paddingBottom = "0px";
        element.scrollTop = 380;
      }, mode);
      await page.waitForTimeout(250);
      await scroll.locator("h1").evaluate(element => { element.style.paddingBottom = "17px"; });
      await page.waitForTimeout(250);
      const actual = await scroll.evaluate(element => element.scrollTop);
      assert.equal(actual, mode === "auto" ? 397 : 380, `${mode} scroll anchoring after a real layout change`);
      stateResults.push({ theme, case: "native-scroll-anchor", mode, before: 380, after: actual });
    }
    await page.locator(".summary-attachment-preview-scroll h1").evaluate(element => { element.style.removeProperty("padding-bottom"); });
    await frames();
    const selection = await page.evaluate(() => state.summaryAttachmentPreview.id);
    for (let cycle = 0; cycle < 12; cycle++) {
      await toggle("summary").click();
      await check(2);
      assert(!(await panel("preview").isVisible()));
      assert.equal(await page.evaluate(() => document.querySelector(".agent-detail-pane").scrollTop), 120);
      await page.evaluate(async () => { await refresh({ force: true, preserveFocusedWorkspace: true }); render(); });
      await check(2);
      await toggle("preview").click();
      await check(2);
      assert.equal(await page.evaluate(() => document.querySelector(".summary-attachment-preview-scroll").scrollTop), saved[1], `Attachment scroll after poll cycle ${cycle}`);
      await toggle("conversation").click();
      assert.equal(await composer.inputValue(), "Keep this unsent panel draft.");
      assert.equal(await page.evaluate(() => document.querySelector(".agent-conversation-scroll").scrollTop), saved[0], `Conversation scroll after poll cycle ${cycle}`);
    }
    for (let cycle = 0; cycle < 20; cycle++) {
      await page.setViewportSize({ width: 390, height: 844 });
      await frames();
      assert(!(await panel("preview").isVisible()));
      await page.setViewportSize({ width: cycle % 2 ? 2200 : 1320, height: 900 });
      await frames();
      await check(cycle % 2 ? 3 : 2);
      assert.equal(await panel("preview").locator(".summary-attachment-preview-scroll").evaluate(element => element.scrollTop), saved[1], `Attachment scroll after settled resize ${cycle}`);
      assert.equal(await panel("conversation").locator(".agent-conversation-scroll").evaluate(element => element.scrollTop), saved[0], `Conversation scroll after settled resize ${cycle}`);
      stateResults.push({ theme, case: "settled-mobile-desktop-resize", cycle, attachmentScroll: saved[1], conversationScroll: saved[0] });
    }
    await page.setViewportSize({ width: 1320, height: 900 });
    await frames();
    await capture("constrained-conversation");
    await page.setViewportSize({ width: 2200, height: 900 });
    await page.waitForFunction(() => document.querySelector(".agent-workspace")?.dataset.visiblePanels?.split(" ").length === 3);
    await check(3);
    await capture("wide");
    for (const key of ["conversation", "summary", "preview"]) {
      await toggle(key).click();
      await check(2);
      assert(!(await panel(key).isVisible()));
      if (key === "preview") {
        await page.setViewportSize({ width: 1320, height: 900 });
        await frames();
        assert(!(await panel("preview").isVisible()), "Manual collapse must remain through constrained resize");
        await page.setViewportSize({ width: 390, height: 844 });
        await frames();
        await page.setViewportSize({ width: 2200, height: 900 });
        await frames();
        assert(!(await panel("preview").isVisible()) && await toggle("preview").getAttribute("aria-expanded") === "false", "Wide return must retain the user's vertical collapsed strip");
        assert.equal(await page.evaluate(() => state.summaryAttachmentPreview.id), selection);
        assert.equal(await composer.inputValue(), "Keep this unsent panel draft.");
        stateResults.push({ theme, case: "wide-user-collapse-through-mobile", collapsedPanel: "preview", selection: "preserved", draft: "preserved" });
        await capture("wide-collapsed");
      }
      await page.evaluate(() => render());
      assert(!(await panel(key).isVisible()));
      await toggle(key).click();
      await check(3);
    }
    await composer.focus();
    for (const width of [900, 1024, 1100, 1280, 1378, 1377, 1440]) {
      await page.setViewportSize({ width, height: 900 });
      await page.evaluate(() => syncContentPanelLayout());
      const fit = await measure();
      await check(fit.visible.length);
      if (width === 900) assert(await toggle("conversation").evaluate(button => button === document.activeElement), "Resize must move focus out of a hidden composer");
      assert(fit.visible.length <= (fit.usable < 1284 ? 2 : 3));
    }
    await page.setViewportSize({ width: 1180, height: 900 });
    await page.waitForFunction(() => document.querySelector(".agent-workspace")?.dataset.visiblePanels?.split(" ").length === 2);
    await check(2);
    await page.locator("[data-restore-content-panels]").click();
    await check(2);
    // Measure fit after extra navigation space, independent of viewport width.
    await page.evaluate(() => { document.querySelector(".agent-workspace").style.width = "760px"; });
    await page.waitForFunction(() => document.querySelector(".agent-workspace")?.dataset.visiblePanels?.split(" ").length === 1);
    await check(1);
    await toggle("conversation").click();
    await check(1);
    assert(await panel("conversation").isVisible());
    assert(await toggle("conversation").evaluate(button => button === document.activeElement), "Expanding the only fitting panel must retain keyboard focus");
    await page.keyboard.press("Space");
    assert(await panel("conversation").isVisible() && await toggle("conversation").evaluate(button => button === document.activeElement), "The last expanded panel must stay open without dropping focus");
    await page.keyboard.press("ArrowRight");
    await page.keyboard.press("Space");
    assert(await panel("summary").isVisible() && await toggle("summary").evaluate(button => button === document.activeElement), "Single-panel accordion must expand Summary with Space and retain focus");
    assert.equal(await panel("summary").evaluate(element => element.scrollTop), 120);
    await page.keyboard.press("ArrowRight");
    await page.keyboard.press("Enter");
    assert(await panel("preview").isVisible() && await toggle("preview").evaluate(button => button === document.activeElement), "Single-panel accordion must expand Attachment with Enter and retain focus");
    assert.equal(await panel("preview").locator(".summary-attachment-preview-scroll").evaluate(element => element.scrollTop), saved[1]);
    await page.keyboard.press("Home");
    await page.keyboard.press("Enter");
    assert(await panel("conversation").isVisible() && await toggle("conversation").evaluate(button => button === document.activeElement));
    assert.equal(await panel("conversation").locator(".agent-conversation-scroll").evaluate(element => element.scrollTop), saved[0]);
    stateResults.push({ theme, case: "single-expanded-panel-keyboard-focus", minimumOne: "preserved", focus: "preserved", scroll: "preserved" });
    await page.evaluate(() => { document.querySelector(".agent-workspace").style.removeProperty("width"); });
    await page.setViewportSize({ width: 390, height: 844 });
    assert(!(await page.locator(".content-panel-controls").isVisible()));
    assert.equal(await page.locator("[data-content-panel-heading]:visible").count(), 0, "Mobile must not introduce a stacked accordion");
    assert(await panel("summary").isVisible());
    assert(!(await panel("preview").isVisible()));
    assert(!(await page.evaluate(() => document.documentElement.scrollWidth > innerWidth)));
    await capture("mobile-summary");
    await page.setViewportSize({ width: 2200, height: 900 });
    await page.waitForFunction(() => document.querySelector(".agent-workspace")?.dataset.visiblePanels?.split(" ").length === 3);
    await check(3);
    assert.equal(await page.evaluate(() => document.querySelector(".summary-attachment-preview-scroll").scrollTop), saved[1], "Attachment scroll after mobile resize");
    assert.equal(await page.evaluate(() => document.querySelector(".agent-conversation-scroll").scrollTop), saved[0], "Conversation scroll after mobile resize");
    assert.equal(await panel("summary").evaluate(element => element.scrollTop), 120, "Summary scroll after mobile resize");
    assert.equal(await page.evaluate(() => state.summaryAttachmentPreview.id), selection);
    assert.equal(await page.evaluate(() => parseRoute().summaryId), "preview-prior");
    assert.equal(await composer.inputValue(), "Keep this unsent panel draft.");
    const visibleFocus = () => page.evaluate(() => {
      const element = document.activeElement;
      const rect = element.getBoundingClientRect();
      return element !== document.body && element.getClientRects().length > 0 && rect.bottom > 0 && rect.top < innerHeight && rect.right > 0 && rect.left < innerWidth;
    });
    for (const selector of ["[data-close-summary-attachment-preview]", '[data-toggle-content-panel="summary"]', "[data-restore-content-panels]"]) {
      await page.setViewportSize({ width: 1320, height: 900 });
      await frames();
      await page.locator(selector).focus();
      await page.setViewportSize({ width: 390, height: 844 });
      await frames();
      assert(await composer.evaluate(element => element === document.activeElement), `${selector}: mobile must focus the visible composer`);
      assert(await visibleFocus(), `${selector}: mobile focus must be in the viewport`);
      await page.keyboard.press("Tab");
      assert(await visibleFocus(), `${selector}: keyboard must continue from a visible mobile control`);
      await page.setViewportSize({ width: 1320, height: 900 });
      await frames();
      assert(await visibleFocus(), `${selector}: desktop return must keep visible focus`);
      stateResults.push({ theme, case: "mobile-focus-handoff", selector, mobileTarget: "composer", keyboard: "passed", desktopReturn: "visible" });
    }
    await toggle("summary").focus();
    await page.evaluate(async () => {
      window.previousAccordionStrip = document.querySelector('[data-toggle-content-panel="summary"]');
      state.conversations[parseRoute().key].blocks.push({ kind: "message", role: "user", content: "Changed content while the vertical Summary strip has focus." });
      await refresh({ force: true, preserveFocusedWorkspace: true });
      render();
    });
    await frames();
    assert(await toggle("summary").evaluate(button => button === document.activeElement && button !== window.previousAccordionStrip && button.getAttribute("aria-expanded") === "false"), "Collapsed strip must retain actual focus through a changed poll render");
    await page.keyboard.press("Space");
    assert(await panel("summary").isVisible() && !(await panel("preview").isVisible()), "Expanding the middle strip must replace another expanded panel");
    assert.equal(await panel("summary").evaluate(element => element.scrollTop), 120);
    assert.equal(await composer.inputValue(), "Keep this unsent panel draft.");
    await toggle("preview").focus();
    await page.keyboard.press("Enter");
    assert.equal(await panel("preview").locator(".summary-attachment-preview-scroll").evaluate(element => element.scrollTop), saved[1]);
    await toggle("conversation").click();
    assert.equal(await panel("conversation").locator(".agent-conversation-scroll").evaluate(element => element.scrollTop), saved[0]);
    stateResults.push({ theme, case: "vertical-strip-changed-poll-and-keyboard", retainedFocus: true, scroll: "preserved", draft: "preserved" });
    for (const changedPoll of [false, true]) {
      await page.locator("[data-restore-content-panels]").focus();
      await page.evaluate(async changedPoll => {
        window.previousRestorePanelButton = document.querySelector("[data-restore-content-panels]");
        state.conversations[parseRoute().key].blocks.push({ kind: "message", role: "user", content: `Changed panel focus fixture ${changedPoll}` });
        if (changedPoll) await refresh({ force: true, preserveFocusedWorkspace: true });
        render();
      }, changedPoll);
      await frames();
      assert(await page.locator("[data-restore-content-panels]").evaluate(button => button === document.activeElement && button !== window.previousRestorePanelButton), "Restore panels must keep actual focus after changed DOM replacement");
      stateResults.push({ theme, case: changedPoll ? "restore-focus-changed-poll" : "restore-focus-changed-render", replacedNode: true, retainedFocus: true });
    }
    await page.locator("[data-close-summary-attachment-preview]").click();
    assert.equal(await panel("preview").count(), 0);
    assert(await panel("conversation").isVisible());
    assert(await panel("summary").isVisible());
    // Direct mobile preview action retains the existing attachment route.
    await page.setViewportSize({ width: 390, height: 844 });
    await open.click();
    await page.waitForURL(/\/attachment\//);
    assert.equal(await panel("preview").count(), 0);
    await capture("mobile-attachment");
    assert.deepEqual(errors, []);
    await page.close();
  }
  if (captureDir) fs.writeFileSync(path.join(captureDir, "content-panels-results.json"), JSON.stringify(results, null, 2));
  if (captureDir) fs.writeFileSync(path.join(captureDir, "content-panels-state-results.json"), JSON.stringify(stateResults, null, 2));
  console.log(`content-panels-smoke: ok (${results.length} layouts; Dark/Light, keyboard, polling, drafts, scroll, selection, mobile)`);
};
