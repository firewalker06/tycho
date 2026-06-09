# Pull Request Diffs

## Summary

Tycho should support first-class pull request diff inspection inside scheduled review workflows. The useful version is not only "open this PR link"; it is "show every PR diff produced or referenced by this scheduled run, keep the diff fresh against the remote PR head, and let the operator move across PRs without leaving the current agent session."

The best path is to reuse the existing local diff foundation: `HQ::GitDiff`, the Remote API project diff routes, the Remote UI diff renderer, and managed-agent attachments. PR diffs can be modeled as remote diff snapshots with freshness metadata, then rendered through the same file/hunk UI that already exists for project workspace diffs.

## Current State

Tycho already has several pieces that make this feasible:

- `HQ::GitDiff` parses local Git patches into structured files, hunks, line numbers, additions, deletions, binary markers, and truncation state.
- Remote UI already has a project diff route and renderer for `#project/:key/diff`.
- Agent structured results can include attachments, and scheduled prompts already ask agents to report durable artifacts in `attachments`.
- Remote UI attachment routes can open files, Markdown, images, and links inside the owning agent view.
- Scheduled runs create fresh managed agents, so each scheduled PR review already has a durable session and memory trail.

The missing piece is that PR links are still treated as links. A GitHub PR URL or review artifact does not currently become an inspectable diff object inside Tycho.

## Operator Problem

In a scheduled PR review flow, the operator often gets one managed agent per recurring review run, with generated reviews and links to pull requests. To inspect whether the review is right, the operator must open each PR link in a browser, inspect the web diff, then return to Tycho.

That breaks the console workflow in three ways:

- It forces context switching out of Tycho for every PR.
- It gives no in-app guarantee that the visible diff is current against the latest PR head.
- It scatters inspection across separate sessions, even when the operator wants one review queue.

## Proposed Product Shape

Add a pull request diff workspace inside agent detail.

For a scheduled review agent, Tycho should expose a "PR Diffs" view that lists every PR referenced by the session, then renders the selected PR's changed files and hunks in the detail pane. The operator should be able to move through PRs and files without opening each PR in GitHub.

Useful navigation:

- PR list: repository, PR number, title, author, status, head SHA, updated time, review result, freshness badge.
- File list: path, status, additions/deletions, binary/truncated markers.
- Hunk viewer: reuse the existing unified diff renderer.
- Keyboard and button actions: previous/next PR, previous/next file, refresh selected PR, refresh all PRs, open original PR, copy selected hunk.
- Session-level route: `#agent/:key/pr-diffs` with an optional selected PR id, so all PRs from one scheduled run stay in one place.

This should also work as a cross-agent queue later: `#pr-diffs` could aggregate PR diff artifacts from recent scheduled review agents. The first version should stay agent-scoped because the current memory and attachment model already has the right ownership boundary.

## Freshness Model

Freshness should be explicit, not implied.

When Tycho fetches a PR diff, store a snapshot with:

- provider: `github`
- repository: `owner/name`
- PR number
- PR URL
- base SHA
- head SHA
- merge/base refs when available
- fetched_at
- provider updated_at
- diff byte count, file count, additions, deletions
- truncated flag

When the operator opens the PR diff view, Tycho should compare the stored snapshot metadata against the provider's current PR metadata. If the remote head SHA or updated timestamp differs, mark the snapshot stale and show a "Refresh diff" action. If the snapshot is current, show "Fresh at ..." with the head SHA.

Refresh behavior:

- Opening the PR diff view may do a lightweight metadata check.
- Fetching the full patch should happen on explicit refresh or when no snapshot exists.
- "Refresh all" should be available for a scheduled review batch, with rate-limit and failure states.
- The UI should preserve selected PR/file/hunk while refreshing.

This avoids surprising the operator with stale diffs while also avoiding expensive full patch downloads on every poll.

## Data Model

Treat PR diffs as managed-agent attachments with a richer payload, or as a new sidecar referenced by an attachment.

Suggested attachment metadata:

```json
{
  "type": "link",
  "kind": "pull_request",
  "title": "owner/repo#123: Fix attachment viewer",
  "url": "https://github.com/owner/repo/pull/123",
  "provider": "github",
  "repository": "owner/repo",
  "pull_request": 123,
  "diff_snapshot_id": "prdiff_abc123",
  "head_sha": "abc1234",
  "base_sha": "def5678",
  "fetched_at": "2026-06-09T13:00:00+07:00"
}
```

Suggested snapshot shape:

```json
{
  "id": "prdiff_abc123",
  "agent_key": "web-agent-42",
  "provider": "github",
  "repository": "owner/repo",
  "pull_request": 123,
  "url": "https://github.com/owner/repo/pull/123",
  "title": "Fix attachment viewer",
  "base_sha": "def5678",
  "head_sha": "abc1234",
  "fetched_at": "2026-06-09T13:00:00+07:00",
  "remote_updated_at": "2026-06-09T12:58:00+07:00",
  "fresh": true,
  "files": [
    {
      "path": "lib/example.rb",
      "status": "modified",
      "binary": false,
      "additions": 12,
      "deletions": 4,
      "hunks": []
    }
  ],
  "truncated": false
}
```

The `files` shape should match `HQ::GitDiff#diff_payload` as closely as possible. That keeps rendering, selection, and future agent handoff reusable for both local workspace diffs and PR diffs.

## Backend Design

Add a provider adapter rather than hardcoding GitHub into UI code.

Initial adapter:

- `HQ::PullRequestDiffProvider::GitHub`
- Accepts `owner/name`, PR number, and optional existing snapshot metadata.
- Reads current PR metadata.
- Fetches the PR patch when needed.
- Parses the patch into the same structured shape as `HQ::GitDiff`.
- Enforces max bytes, max files, max hunks, and binary handling.
- Records provider errors and rate-limit messages as operator-facing states.

Possible API routes:

- `GET /agents/:key/pull-requests`
- `GET /agents/:key/pull-requests/:id/diff`
- `POST /agents/:key/pull-requests/:id/refresh`
- `POST /agents/:key/pull-requests/refresh`

Later cross-agent queue:

- `GET /pull-requests?source=scheduled&project=:project_key`
- `GET /pull-requests/:id/diff`
- `POST /pull-requests/:id/refresh`

The provider can discover PR references from:

- structured result attachments with `kind: pull_request`
- regular link attachments whose URL matches a provider PR pattern
- conversation blocks containing PR URLs, as a fallback only

Prefer structured attachments because they are durable, dedupable, and already part of the scheduled-agent result contract.

## Remote UI Design

Agent detail should gain a PR diff workspace alongside conversation, summary, project diff, and attachment views.

Wide layout:

- Left pane remains the scheduled review conversation.
- Right pane shows PR diff navigation and the selected diff.
- The PR list stays visible above or beside the file/hunk viewer.
- The diff body scrolls independently, following the same approach as attachment and project diff detail panes.

Mobile layout:

- The PR list becomes a top drawer or segmented selector.
- File list can be inside the selected PR panel.
- The hunk viewer remains a single vertical flow.

Important UI states:

- No PRs found.
- PR metadata loading.
- Diff snapshot missing.
- Diff fresh.
- Diff stale because head SHA changed.
- Refresh failed.
- Diff too large or truncated.
- Binary-only PR.
- Provider auth unavailable.

The operator should always have an "Open on GitHub" escape hatch, but that should be secondary to the in-Tycho diff.

## Scheduled Review Prompt Contract

Scheduled PR review prompts should ask agents to emit PR attachments in a predictable form.

Example instruction to add to a review schedule prompt:

```markdown
When you review a pull request, include it in final `attachments` with:

- `kind: pull_request`
- `title`: repository and PR number
- `url`: canonical PR URL
- `description`: short review outcome
```

This lets Tycho build the PR diff list without scraping prose. Existing link attachments can still work as a fallback, but structured PR attachments should be the target.

## TUI Design

The TUI should eventually expose the same queue from the agent chat screen.

Suggested controls:

- `ctrl+p`: open PR diff list for the selected scheduled agent.
- `j/k`: move file or hunk selection.
- `n/p`: next/previous PR.
- `r`: refresh selected PR metadata and diff.
- `o`: open original PR URL.
- `c`: copy selected hunk.
- `esc`: return to conversation.

Start with read-only inspection. Sending selected hunks back to an agent can reuse the future diff-selection handoff described in `docs/research/git-diff-viewer-study.md`.

## Implementation Phases

Phase 1: PR detection and snapshots

- Detect structured `pull_request` attachments in managed-agent memory.
- Add a PR diff snapshot store under `~/.tycho/logs/agents/`.
- Add provider metadata refresh for GitHub PRs.
- Add tests for URL parsing, dedupe, stale/fresh detection, and missing auth.

Phase 2: patch fetch and parser reuse

- Fetch PR patch content on demand.
- Parse remote patches into the existing structured diff shape.
- Enforce size limits and truncation.
- Add tests for modified, added, deleted, renamed, binary, truncated, and large PR patches.

Phase 3: Remote UI PR diff workspace

- Add agent-scoped PR diff routes.
- Render PR list, freshness state, refresh actions, and selected diff.
- Preserve selected PR/file/hunk across polling and refresh.
- Verify desktop and mobile behavior in a browser.

Phase 4: one-queue workflow

- Add a cross-agent scheduled PR review queue.
- Group by schedule, project, repository, and freshness.
- Let the operator move through every PR diff from recent scheduled runs without opening each agent session.

Phase 5: agent handoff

- Allow selected files or hunks to be sent to an existing agent prompt.
- Store selection metadata in memory.
- Render selected diff context clearly in chat logs.

## Recommendation

Yes, Tycho can make PR diffs inspectable without leaving the app, and the implementation should be incremental. Start with an agent-scoped Remote UI PR diff workspace that discovers PR attachments from scheduled review agents, checks freshness through provider metadata, fetches patches on demand, and renders them with the existing structured diff UI.

After that works reliably, add the cross-agent queue. That is the feature that directly solves the operator workflow: one scheduled review session can become the place to navigate every PR diff, refresh stale snapshots, and decide which reviews need attention.

