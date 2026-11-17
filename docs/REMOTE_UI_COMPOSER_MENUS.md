# Composer flyout layering

The Attachments flyout could extend above the scrolling composer dock in layout,
but the dock clipped its paint and pointer targets. A 1920 by 1000 fixture
measured the flyout at y=599 through 939, while the dock began at y=776. Its
upper corners hit Conversation content instead of the flyout. The dock had
`overflow: auto`; changing only the flyout z-index cannot escape that clip.

Attachments, Linked agents and Skills now share a manual native popover layer.
Their DOM ownership, labels, actions and existing dismissal handlers stay intact.
The dock keeps its scroll budget. No ancestor overflow or delegated-family
border clipping is changed, and no large z-index is added. Native modal dialogs
remain above an earlier open popover.

Positioning follows each trigger. Width is limited by the composer and visible
viewport. The flyout uses available space above or below, keeps clearance below
the app header, and retains internal scrolling. Polling restores its open state;
scroll, viewport resize and visual viewport changes update its position. Escape
and outside click retain the existing close and focus behavior.

## Verification

```sh
TYCHO_REMOTE_UI_COMPOSER_MENUS_ONLY=1 bin/remote-ui-smoke
```

Add `TYCHO_REMOTE_UI_COMPOSER_MENUS_WEBKIT=1` for installed Playwright WebKit.
Set `TYCHO_REMOTE_UI_CAPTURE_DIR` outside the checkout for evidence.

The isolated fixture uses real registered file attachments, a linked child and a
Focus peer. Both themes are checked at 1920 by 1000, 1440 by 900, 900 by 700,
390 by 844 and 844 by 390. Tests hit all flyout corners against the actual DOM,
click filters/downloads/delete-cancel, check modal hit targets, resize while
open, poll, scroll lists, dismiss with Escape/outside click and retain long drafts.
Physical mobile keyboards and browser chrome animations are not exercised.
