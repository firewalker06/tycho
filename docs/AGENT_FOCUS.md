# Agent Focus

Focus is one saved current-state document for each agent. Use it for review
requests, next actions, blockers, or an orchestrator's work list. Conversation
and Summary keep the run history. Focus keeps the latest actionable state.

The Remote UI shows non-empty Focus in its own peer panel on Conversation.
Focus is outside the message list and has its own scroll area. Each section has
a title, optional subtitle, icon, and ordered items. Each item has a title,
optional subtitle, and attachment links. Empty sections show “No items”. There
is no Focus panel or shortcut when the document is absent or empty.

## Panel behavior

On entry to Conversation, an existing Focus opens by default if the measured
workspace can fit Conversation (380 px), Focus (440 px), and the 12 px gap.
The existing desktop content-panel controls manage fit from 900 px upward.
At a narrower desktop width, Focus starts as a collapsed vertical strip. Use
that strip or the Focus shortcut beside Summary to open it. Panel fit preserves
the most recently requested panel. The composer remains below a Focus-only
view, including narrow desktops. Closing Focus restores Conversation.

Below 900 px, Focus starts closed. The Focus shortcut explicitly opens it as
the visible panel, with the composer retained below it. Close Focus returns to
Conversation and its saved scroll position. Wide opening does not
request the mobile panel. A manual mobile open remains open through
polling and viewport changes until the operator closes it.

A manual close stays closed through polling, resizing, and navigation away and
back to the same agent. A width-limited automatic collapse can expand again
when space returns. Choices are kept per agent for the current browser page;
a reload starts with the viewport defaults. A Focus document created after an
empty agent detail read stays closed until explicitly opened. Polling never
requests a new panel. Summary and attachment views keep their own panel state.

Focus links use the standard attachment view. Their source files may also
appear in a user message or run Summary because Focus references an existing
attachment; that does not attach the Focus artifact to a message.

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

## Verification

`bin/test` includes store validation, concurrent-write, persistence, CLI/API,
conflict, retry, clear, and archive coverage. For actual browser checks:

```sh
TYCHO_REMOTE_UI_FOCUS_ONLY=1 bin/remote-ui-smoke
```

Set `TYCHO_REMOTE_UI_CAPTURE_DIR` to a directory outside the checkout to retain
screenshots and geometry evidence. The fixture checks long conversations near
the bottom, desktop fit defaults, narrow/mobile defaults and explicit opening,
independent scrolling, keyboard controls, polling, updates, resize/navigation
choices, drafts, Summary/attachment compatibility, empty/late Focus, invalid
URLs, conflicts, and viewport overflow in Dark and Light.
