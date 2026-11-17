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
Expanded editors fill their panel without stretching warning copy. A detail-only
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
