# Explicit Focus refresh

Global polling previously replaced the agent detail object, including Focus,
and could rebuild the displayed Focus panel. The regression fixture changes
Focus on the server while keeping a browser on the earlier document. The old
code immediately shows the new items after polling.

Focus now uses a per-agent displayed snapshot. The panel participates in the
existing retained-content mechanism, with a version for manual results, refresh
status and section choices. Unchanged Focus keeps its actual DOM node across
background renders, including internal forced reconciliations. Other panels
and agent status keep their existing refresh behavior.

The icon-only Refresh Focus button reads current Focus directly. Explicit UI
refresh, pull refresh, server refresh controls and Load new messages also request
Focus for the selected agent. Background polling and mutation reconciliation do
not. Concurrent manual requests share one read. Loading keeps old content and
keyboard focus; failure shows an error and permits retry. A valid manual result
replaces the snapshot; older agent-detail responses cannot overwrite it.
Requests started before navigation do not refresh the newly selected agent.

Section choices remain keyed by heading and occurrence. Matching headings keep
their choices after a manual refresh. The bulk icon says Collapse all when any
section is open and Expand all when all are closed. Both bulk and Refresh icons
have accessible names and native title tooltips; Enter and Space operate them.

## Verification

```sh
TYCHO_REMOTE_UI_FOCUS_REFRESH_ONLY=1 bin/remote-ui-smoke
```

Add `TYCHO_REMOTE_UI_FOCUS_REFRESH_WEBKIT=1` for installed Playwright WebKit.
Set `TYCHO_REMOTE_UI_CAPTURE_DIR` outside the checkout for PNG and JSON evidence.

The real isolated API fixture checks desktop, medium and mobile widths in both
themes. It changes the server document between reads and asserts unchanged data,
DOM identity, section state, scroll and file preview during background polling.
It holds a manual read to check loading and request coalescing, fails it to check
content retention and retry, and releases an older detail response after a newer
manual result. It checks icon labels, keyboard focus and mixed/all-closed bulk
behavior, emulated pull events, an actual Load new messages click, and drafts.
Touch events are emulated; no physical mobile keyboard or browser chrome is used.
