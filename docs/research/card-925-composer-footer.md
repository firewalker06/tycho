# Card 925: mobile Conversation composer footer

[Card 925](https://fizzy.startkit.tech/1/cards/925) reports a clipped Send button and toolbar with an open attachment tray. The two user screenshots were compared locally. They are private references and are not included in this repository or the PR.

## Findings

The Conversation reference shows the toolbar and Send button cut at the lower edge. The front page reference shows complete bottom navigation. Both use the same narrow iPhone display.

The exact reference-image failure did not occur on current main in the basic 375x812 browser case. Earlier PR 382 already changed the dock grid placement and safe-area background. Native iOS browser chrome and home-indicator rendering remain outside this test environment.

The extended test did reproduce two related reachability failures:

- At 320x240, a full toolbar wraps into two rows. The sticky panel tabs cover its upper row after dock scrolling.
- In an expanded editor at the same height, the editor track can shrink until its absolute controls cover the file tray. A file remove control cannot receive a tap, even after scrolling.

The five-file matrix also exposed WebKit's “ResizeObserver loop completed with undelivered notifications” error while layout synchronization changed the observed dock.

## Changes

- Put safe-area padding inside the sticky action row. It stays with the actions while the outer dock scrolls. Use the same safe-area variable for full-screen editors.
- Give composer dock rows their natural content height. Include workspace grid gaps, padding, and borders in the height budget. Let panel tabs scroll away in short viewports.
- When the measured footer and tab row cannot fit together, allow the footer to scroll too. Scroll to the actions once when entering this state. Later layout checks preserve user scrolling.
- Give expanded editors a 92px minimum editor track and a scrolling content region with sticky actions. This prevents editor controls from covering file controls.
- Watch footer border-box changes, including safe-area padding, even when the outer dock height stays fixed. Schedule synchronization once per animation frame.
- Keep the full-screen Close control above the scrolling editor and footer.

## Verification

Run from the repository root:

```sh
TYCHO_REMOTE_UI_SIDE_CONVERSATIONS_ONLY=1 TYCHO_REMOTE_UI_MOBILE_PROMPT_ONLY=1 bin/remote-ui-smoke
TYCHO_REMOTE_UI_SIDE_CONVERSATIONS_ONLY=1 TYCHO_REMOTE_UI_MOBILE_PROMPT_ONLY=1 TYCHO_REMOTE_UI_MOBILE_PROMPT_WEBKIT=1 bin/remote-ui-smoke
```

Set `TYCHO_REMOTE_UI_CAPTURE_DIR` to an external directory to keep synthetic screenshots and geometry. These commands use a temporary server, config, logs, files, and fake harness. They do not use real agents.

The matrix checks one and five selected files, both disclosure states, normal and expanded editors, 375x812, 320x568, 375x340, and 320x240 viewports, with a modeled 34px bottom safe area. It checks action hit targets and first/last file-control reachability. Existing checks cover no-file long drafts, caret/focus preservation, polling, actual file removal, keyboard viewport models, orientation changes, running/idle Stop, and desktop layouts at 932 and 1440px. The front page navigation must still reach the viewport bottom.

At the shortest heights, the editor, tray, and footer cannot all fit at once. The checks scroll between them and assert that each action can receive a tap; they do not require all controls to remain on screen at the same time.

The desktop dock has a deliberate 12px lower gap. The prior browser assertion incorrectly required it to reach the screen bottom. The corrected assertion keeps the mobile edge check unchanged.

## Review limits

The tests use real Chromium and WebKit layout with synthetic visualViewport events and CSS safe-area values. They do not reproduce a native iOS keyboard, Safari toolbars, or physical home-indicator behavior. A device check against the original report is still useful before merge. No independent review has been performed in this implementation run.

## Synthetic screenshot evidence

These images contain fixture agents and synthetic files only. The 320x240 images show the footer after scrolling to the actions. File-control checks separately scroll the open tray and editor to prove reachability.

| Case | Evidence |
| --- | --- |
| Before: panel tabs cover the wrapped toolbar at 320x240 | [Before short toolbar](card-925/before-short-toolbar.png) |
| After: full toolbar and Send button, with 34px safe-area model | [After short toolbar](card-925/after-short-toolbar.png) |
| After: one open attachment at 375x812 | [Open tray](card-925/after-open-tray.png) |
| After: expanded editor at 320x240 | [Expanded editor](card-925/after-expanded-editor.png) |
| Front page: bottom navigation still reaches the viewport edge | [Front page](card-925/front-page.png) |
| Desktop: Conversation and Summary at 1440x900 | [Desktop](card-925/desktop.png) |

## Results

- Chromium: all 83 cases passed.
- WebKit: all 83 cases passed.
- `test/remote_server_test.rb`: passed.
- `test/remote_ui_asset_snapshot_test.rb`: passed.
- The full `bin/test` result and exact published-head signoff are recorded on the draft PR.
