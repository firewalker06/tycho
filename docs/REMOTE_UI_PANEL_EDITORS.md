# Inquiry headers and panel editors

On viewport widths from 900 CSS pixels, the answer and prompt expand controls
use vertical arrows. They expand the editor to the height of its Conversation
panel. The column width, other selected panels and fixed agent header stay in
place and remain interactive. The control exposes an expanded state and a
specific expand/collapse label. Escape collapses the editor. Answer values,
feedback, prompt drafts and selections survive polling and layout changes.

Below 900 pixels, expansion keeps the existing full-screen modal behavior,
including focus isolation and Escape. Crossing the breakpoint while expanded
saves the current form and changes between modal and panel editing. Attachment
view controls and their separate layout semantics are unchanged.

## Initial answer position on iPad

WebKit 26.0 can retain an incorrect intrinsic grid track size after side-panel
and narrow-layout navigation. With a historical Summary, newer conversation
metadata, and a long inquiry, the banner itself can have its correct height
while its `auto` row grows to several thousand pixels. The answer fields then
start below a large blank area. Scrolling or another layout pass can repair the
size, so a reachability check after scrolling misses the initial failure.

The inquiry content uses `max-content` for its banner and footer rows. Expanded
forms use it for all three rows. This keeps the fields directly after the banner
without changing the normal internal-field scroll or expanded dock scroll.

The isolated regression records geometry before a screenshot, scroll, or refresh
can repair the old WebKit state. It covers both Focus/Summary orders, Back from
the narrow layout, Summary run 8 with twenty newer messages, a paused queue,
long copy, normal/expanded editors, and polling at 1180 by 788/820 pixels:

```bash
TYCHO_REMOTE_UI_INQUIRY_INITIAL_POSITION_ONLY=1 bin/remote-ui-smoke
```

The original failure reproduces in WebKit 26.0 from Playwright 1.56.1, but not in
the tested WebKit 27.2. To run the older engine from the repository root:

```bash
ipad_tools=$(mktemp -d)
npm install --prefix "$ipad_tools" --no-audit --fund=false playwright@1.56.1
"${ipad_tools}/node_modules/.bin/playwright" install webkit
TYCHO_PLAYWRIGHT_PATH="${ipad_tools}/node_modules/playwright" \
  TYCHO_REMOTE_UI_INQUIRY_INITIAL_POSITION_ONLY=1 \
  TYCHO_REMOTE_UI_INQUIRY_INITIAL_WEBKIT=1 bin/remote-ui-smoke
```

Use an external temporary tools directory and `TYCHO_REMOTE_UI_CAPTURE_DIR`
outside the checkout to retain synthetic screenshots and measured grid rows.
Desktop WebKit with touch/mobile emulation does not reproduce physical Safari
or PWA browser chrome; the two viewport heights also cover the iPad status-bar
height difference.

## Height diagnosis

The short inquiry banner measured 58 pixels in the normal isolated tablet
fixture in Chrome and WebKit. The agent header measured about 67 pixels at a
1260 by 875 CSS-pixel viewport. The initial expand action changed the form from
559 pixels wide to the full 1260-pixel viewport and isolated the header. That
was the wrong action for a panel editor.

A controlled spare-height probe on the real inquiry form reproduced blank
warning space: assigning 1800 pixels to the form stretched its automatic rows,
including a short banner from 58 pixels to about 507 pixels. The screenshot's
exact historical browser state was not available. The probe identifies the
unsafe grid sizing rule without assuming that the font is too large.

Inquiry layout now gives the banner its intrinsic height. A bounded field area
owns the remaining height and scrolls; action controls retain a natural footer.
Expanded editors fill their panel without stretching warning copy. Multiline
answer fields receive spare editing height; other field labels and feedback
retain their natural sizes. A detail-only
Summary view can still hide the Conversation editor; returning to the balanced
view restores its saved expansion. Fonts are unchanged.

## Browser verification

```sh
TYCHO_REMOTE_UI_INQUIRY_RECEIPT_ONLY=1 TYCHO_REMOTE_UI_INQUIRY_PANEL_ONLY=1 bin/remote-ui-smoke
```

Add `TYCHO_REMOTE_UI_INQUIRY_PANEL_WEBKIT=1` for installed Playwright WebKit.
Set `TYCHO_REMOTE_UI_CAPTURE_DIR` outside the checkout to save PNG and JSON
geometry evidence.

The fixture uses persisted inquiries and real local answer submission. It checks
short/long copy, Dark/Light, tablet landscape at 1260 by 875 with a 1.5 device
scale factor, 1366 by 768, desktop at 1920 by 1080, the 900-pixel boundary,
390-pixel portrait and 844-pixel landscape. Assertions cover compact banners,
vertical controls, unchanged peer/header geometry, action hit tests, polling,
Escape, breakpoint transitions, drafts, attachment peers, Summary layout changes,
failed answer recovery, retry and acceptance. The local runner is synthetic;
no provider or real agent is used. Headless engines do not show a physical
software keyboard or operating-system browser chrome.
