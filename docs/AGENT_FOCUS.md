# Agent Focus

Focus is one saved current-state document for each agent. Use it for review
requests, next actions, blockers, or an orchestrator's work list. Conversation
and Summary keep the run history. Focus keeps the latest actionable state.

The Remote UI shows non-empty Focus in its own peer panel on Conversation.
Focus is outside the message list and has its own scroll area. Each section has
a title, optional subtitle, icon, and ordered items. Each item has a title,
optional subtitle, and attachment links. Empty sections show “No items”. There
is no default Focus panel or shortcut when the document is absent or empty.
The Side Conversations switcher can still open an empty Focus panel.

## Panel behavior

On entry to Conversation, existing Focus opens beside Conversation from 900 pixels.
Below 900 pixels it starts closed. The grouped Focus toggle opens it above the
retained composer. Conversation returns to chat without closing the requested
side views. A manual close stays closed through polling, resizing and navigation.
A reload uses the viewport defaults. Focus created after an empty detail read
stays closed until explicitly opened.

Panels use fixed slots, independent of open count: one below 900 pixels, two
from 900 through 1439 pixels, and three from 1440 pixels. Unused slots stay empty
on the right. At medium widths the newest peer stays visible beside Conversation;
small screens retain the selected single view. Requested peers remain available
through their grouped toggles. Detail-only mode keeps the same slot width.
There are no panel X buttons or width expansion controls.

Choices are local to each agent in the current browser page. Polling preserves
panels, drafts and section disclosure. Focus links use the standard attachment
view. Focus references existing files without adding them to a message. See
[panel slots and mobile prompt behavior](REMOTE_UI_PANEL_SLOTS.md) for exact
width calculations and browser verification.

## Read and replace

```sh
bin/tycho agent focus AGENT_KEY --json
bin/tycho agent focus AGENT_KEY --file path/to/focus.json --revision 0 --json
cat path/to/focus.json | bin/tycho agent focus AGENT_KEY --file - --revision 1
```

Use `--server SERVER_KEY` for a configured peer. The command always returns JSON.
Read returns an object with `revision`, `updated_at`, and `sections`. The input
file contains the **sections array**, not the response object:

```json
[
  {
    "title": "Ready for Review",
    "subtitle": "Your next actions",
    "icon": "todo_done",
    "items": [
      {
        "title": "Fix user registration",
        "subtitle": "PR #12 is ready",
        "attachments": [
          {
            "type": "link",
            "title": "Review PR #12",
            "url": "https://github.com/example/web/pull/12"
          }
        ]
      }
    ]
  },
  {
    "title": "In Progress",
    "subtitle": null,
    "icon": "todo_working",
    "items": []
  }
]
```

Supported icons are `todo_done`, `todo_working`, `todo_pending`, `blocked`, and
`note`. The default is `note`. Titles are required. Subtitles can be omitted or
null. Items must be an array. Attachments default to an empty array. Text is plain
text; markup is displayed as text. Array order is display order.

Link attachments require HTTP or HTTPS URLs without embedded credentials.
A file attachment uses `{"type":"file","title":"Report","path":"report.md"}`.
Its path must exactly match a file already in that agent's attachments. Reuse
paths from previous result attachments; Focus does not upload files or grant
access to new file paths. Removed source attachments show as unavailable.
File links use the existing preview and download controls.

## Update rules

1. Read Focus before each edit. Keep unrelated sections and items.
2. Replace the complete sections array with the returned revision.
3. Use the returned new revision for the next edit. For a conflict, read again
   and apply the intended change to the current document.
4. After an uncertain reply, retry the exact array and revision. An identical
   retry of the latest write returns that saved document without a new revision.
5. Send `[]` to clear Focus. Do not clear it merely because a run ends.

The initial revision is zero. A changed document advances the revision once.
An unchanged replacement is a no-op. Simultaneous writers cannot silently
replace each other's changes. The API returns 409 for a stale different write
and 422 for invalid content. Limits are 20 sections, 100 total items, 10
attachments per item, 2,000 characters per text field, and 128 KiB input.

Focus does not change agent status, add transcript messages, send a prompt, or
mark the agent unread. Agents receive Focus command guidance on each run.
Orchestrators should update Focus when actionable state changes, while using
normal result summaries for the outcome of each run.

## Persistence and API

Focus is stored as `focus.json` beside the agent's logs, with a backup and a
write lock. Writes use an atomic file replacement. A damaged primary document
is reported for repair and is not silently replaced with empty state. Keep the
primary and backup files before repair.

Focus survives new runs, native-session resume, and server restart. Archive
moves the document and backup with the agent logs. Archived Focus is readable
and cannot be edited. A clone is a new agent and starts with empty Focus; the
source keeps its Focus in active or archived history.

The authenticated Remote API exposes these agent resource routes, including
through configured peers:

- `GET /agents/:key/focus` returns `{ "focus": { "revision": 0, "updated_at": null, "sections": [] } }`. <!-- local-path-ok -->
- `PUT /agents/:key/focus` accepts `{ "revision": 0, "sections": [...] }` and returns the saved `focus`. <!-- local-path-ok -->

Agent detail responses also include `focus` with resolved file preview links.
The dedicated Focus read endpoint returns the saved document for editing.

## Side Conversations

Conversation is the first panel. Focus, Summary, and PR Diffs are Side
Conversations. Their shared toggles stay in the existing agent header on
desktop. On mobile, the controls stay directly above the prompt form in a
persistent composer region. Closing all Side Conversations keeps the controls
available so any view can be reopened.

A second Side Conversation opens in a third panel. Opening a third replaces
the oldest open Side Conversation. When the width cannot fit three panels,
the newest Side Conversation stays visible. Both open buttons remain
highlighted. Mobile shows one content view above the composer; it does not
squeeze multiple columns into the screen. The Conversation control returns
to chat without closing the side views. Prompt drafts remain available while
a side view is visible.

Polling preserves open panels and drafts. File attachments from Focus or Summary
replace the third panel while the source stays in the second panel. The shared toggles remain outside the attachment pane. Header clearance tracks
the actual header size, including wrapped metadata, font changes, and safe insets.
At scroll top, the first content and its controls remain below the header.
Panel X buttons are removed at all widths; grouped toggles close and reopen
side views. Modal dismiss controls remain available. The outer
workspace stays within the viewport, and only the Focus body scrolls. On mobile,
the tabs and Stop share one width-constrained row. Only the tabs scroll
horizontally; Stop stays fixed at the right when a run starts or stops.

## Verification

`bin/test` includes store validation, concurrent-write, persistence, CLI/API,
conflict, retry, clear, and archive coverage. For actual browser checks:

```sh
TYCHO_REMOTE_UI_FOCUS_ONLY=1 bin/remote-ui-smoke
```

Set `TYCHO_REMOTE_UI_CAPTURE_DIR` to a directory outside the checkout to retain
screenshots and geometry evidence. The fixture checks long conversations near
the bottom, fixed-slot breakpoints, sidebar widths, narrow/mobile defaults and selection,
reading position, drafts, Summary/attachment compatibility, empty/late Focus,
invalid URLs, conflicts, and viewport overflow in Dark and Light.

Check the Side Conversations switcher and responsive layout with:

```sh
TYCHO_REMOTE_UI_SIDE_CONVERSATIONS_ONLY=1 bin/remote-ui-smoke
```

Check wrapped mobile headers, safe-inset changes, first-content hit testing,
scrolling, polling, navigation, resize, and drafts with:

```sh
TYCHO_REMOTE_UI_SIDE_CONVERSATIONS_ONLY=1 TYCHO_REMOTE_UI_SIDE_TOP_ONLY=1 bin/remote-ui-smoke
```

For the same checks in Playwright WebKit, install its browser and add the
WebKit flag:

```sh
npx --yes playwright install webkit
TYCHO_REMOTE_UI_SIDE_CONVERSATIONS_ONLY=1 TYCHO_REMOTE_UI_SIDE_TOP_ONLY=1 TYCHO_REMOTE_UI_SIDE_TOP_WEBKIT=1 bin/remote-ui-smoke
```

`PLAYWRIGHT_BROWSERS_PATH` can select a custom browser cache. Use the same
absolute cache directory for installation and the test. These checks simulate
mobile viewports, larger text, and safe insets. They do not test physical iOS
browser chrome or its software keyboard.

Check desktop short/long Focus scroll ownership and real isolated running/idle
Stop transitions at 320, 390, and landscape widths with:

```sh
TYCHO_REMOTE_UI_SIDE_CONVERSATIONS_ONLY=1 TYCHO_REMOTE_UI_SIDE_BOUNDS_ONLY=1 bin/remote-ui-smoke
```

Add `TYCHO_REMOTE_UI_SIDE_BOUNDS_WEBKIT=1` to run these checks in installed
Playwright WebKit. The test checks document/form bounds, independent Focus
scrolling, last-tab reachability, fixed Stop geometry, touch/keyboard toggles,
and retained drafts. It uses a synthetic local harness process without a provider.

### Panel width and attachment placement

Initial Focus and shared Side Conversations use identical fixed slots. Slot count
is based on viewport CSS width: one below 900, two from 900, three from 1440.
Each slot is `(W - 12 * (N - 1)) / N` pixels, where W is the workspace grid content
width after navigation and page padding, and N is the slot count. All gaps are
reserved even when slots are empty. See [panel sizing](REMOTE_UI_PANEL_SLOTS.md).

A file opened from Focus or Summary keeps Conversation and its source. The source
moves to panel two if necessary, and the attachment replaces panel three.
External links keep their existing navigation. The attachment uses internal
scrolling and the shared tabs; it has no panel close button.

```sh
TYCHO_REMOTE_UI_SIDE_CONVERSATIONS_ONLY=1 TYCHO_REMOTE_UI_PANEL_PLACEMENT_ONLY=1 bin/remote-ui-smoke
```

Add `TYCHO_REMOTE_UI_PANEL_PLACEMENT_WEBKIT=1` for installed Playwright WebKit.
Set `TYCHO_REMOTE_UI_CAPTURE_DIR` outside the checkout to retain screenshots and
geometry measurements. PR 372 remains separate; its polling reconciliation
changes overlap this preview renderer and need explicit integration.

Summary layout actions select Summary explicitly and remove a dismissed
attachment peer. This prevents a stale Summary route from showing only Focus
after Full View. See [Summary layout selection](REMOTE_UI_PANEL_SLOTS.md#summary-layout-selection).

### Collapse Focus sections

Each section heading is a keyboard-accessible button with an expanded state and
an explicit item-list target. Collapse hides only that section's items; the
heading, subtitle, icon and count stay visible. Enter and Space toggle a section.
The Focus header offers **Collapse all** if any section is open, including a
mixed state, and **Expand all** when every section is closed.

Choices are local to the agent in the current browser session and survive
polling, panel replacement and navigation. Section title and duplicate-title
occurrence identify each choice, so item edits do not reset it. New or renamed
sections start expanded. Focus data and other browsers are not changed.
The panel-placement smoke checks section and bulk actions, keyboard states,
polling, attachment opening and desktop/mobile geometry in Chrome and WebKit.

### Focus attachment cards

Focus reuses Summary attachment rows and type icons, including image and link
icons. Registered files have the same panel-open and Download controls. The
panel-open action keeps Focus in panel two and replaces panel three. Download
uses the registered original filename, including when Focus has a custom title.
Ordinary external links retain their external navigation and have no unsupported
download or preview action. Removed files show as unavailable without actions.

Attachment grids use the Focus panel as an inline-size container. They show one
column below 640 pixels of container content width, two columns from 640 pixels,
and three from 960 pixels. Opening another peer does not change slot width. Sidebar width changes can
change the grid at the same viewport width. Long attachment titles stay on one line with an ellipsis; accessible labels and title
attributes keep their complete text. Shared Focus/Summary file tiles and their
panel-open/download actions form one joined group, with a thin outer border and
internal dividers. Link-only tiles fill the same outer width without reserved
action tracks or gaps. Controls remain separate siblings with standard hit sizes.

```sh
TYCHO_REMOTE_UI_SIDE_CONVERSATIONS_ONLY=1 TYCHO_REMOTE_UI_FOCUS_ATTACHMENTS_ONLY=1 bin/remote-ui-smoke
```

Add `TYCHO_REMOTE_UI_FOCUS_ATTACHMENTS_WEBKIT=1` for installed Playwright WebKit.
Set `TYCHO_REMOTE_UI_CAPTURE_DIR` outside the checkout for current screenshots
and measured panel/grid geometry. The fixture checks actual downloads and bytes,
external navigation, type icons, unavailable files, keyboard actions, long
labels, same-viewport panel changes, polling, drafts and desktop/mobile bounds.

## Manual refresh in the Remote UI

Displayed Focus data is a per-agent snapshot. Global polling keeps the same
Focus node, section choices, scroll and attachment selection. It does not fetch
Focus or accept replacement Focus data from an agent-detail read. A document
that first becomes available can still expose Focus without opening it.

The icon-only Refresh Focus control retrieves current Focus directly. Explicit
agent/message fetching, manual refresh controls and pull refresh also retrieve
Focus. Background and mutation reconciliation do not. Busy state keeps keyboard
focus and coalesces duplicate requests. A failed read leaves the old content
visible with a retryable error. Older detail replies cannot overwrite a newer
manual Focus result.

Collapse all and Expand all are icon-only controls with accessible names and
tooltips. Mixed state still means Collapse all; all closed means Expand all.
See [Focus refresh verification](REMOTE_UI_FOCUS_REFRESH.md).
