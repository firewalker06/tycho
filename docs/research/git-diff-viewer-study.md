# Temporary Study: Git Diff Viewer for Tycho

Date: 2026-06-06

References were verified active on 2026-06-06. The implementation notes lean on the Git manuals for diff/status/apply behavior and GNU diffutils for the unified hunk shape.

## Why This Matters

Tycho already knows which project or agent workspace a user is operating in, but it currently exposes only a shallow Git summary: commit, branch, and dirty file count. That is enough to warn that something changed, but not enough to understand what changed, decide whether an agent touched the right files, or carry precise code context into an agent conversation.

A first-class diff viewer would make Tycho much more useful as an operator console. The highest-leverage version is not just "show `git diff`"; it is "let the user inspect a change, select a file, hunk, or line range, and bring that exact context into the agent conversation."

## Current State in the Codebase

Current Git metadata is collected in `HQ::Project#parse_git_status`:

- `git rev-parse --short HEAD`
- `git branch --show-current`
- `git status --porcelain`
- `dirty_files = porcelain.lines.count`

That data flows into:

- TUI project and agent chips/detail rows as `branch`, `commit_hash`, and `dirty_files`.
- Remote API project payloads as `branch`, `commit_hash`, `dirty`, and `dirty_files`.
- Web UI project chips and revision rows.

There is no current file-level status, diff endpoint, hunk parser, or line-level model. The current implementation tells the user that a project is dirty, but it cannot answer "what changed?"

## Product Shape

The feature should support two modes:

1. Read-only inspection: understand the current worktree quickly.
2. Context crafting: select diff ranges and use them as conversation material for an agent.

Patch application or staging should be a later step. The first implementation should avoid changing Git state.

## TUI Concept

Add a `D` or `ctrl+d` project shortcut that opens a diff view for the selected project.

Useful TUI layout:

- Left column: changed files, status, additions/deletions, staged/unstaged badge.
- Right column: unified hunk viewer with old/new line numbers.
- Header controls: scope toggle for `worktree`, `staged`, and `all`.
- Footer controls: next/previous file, next/previous hunk, copy selected hunk, send selection to current/new agent chat, close.

Interaction targets:

- File selection for broad review.
- Hunk selection for agent context.
- Line range selection as a later enhancement once the hunk model is stable.

The TUI should use the existing viewport/detail patterns instead of introducing a separate navigation system. Diff rendering must stay width-aware and avoid horizontal layout churn.

## Web UI Concept

Add a project-level diff panel or route, for example `/#project/:key/diff`.

Useful Web UI layout:

- Sticky toolbar with scope, refresh, collapse/expand files, and "Send to agent".
- File list with status and counts.
- Unified diff view as the initial default.
- Split diff can be a later enhancement.
- Mobile layout should put the file list behind a drawer or top segmented list.

Line and hunk actions can be richer on the Web UI:

- Click hunk gutter to select a hunk.
- Drag or shift-click line ranges in a hunk.
- Button to attach selection to an existing agent conversation.
- Button to start a new agent using selected diff context.

Polling should preserve open files, selected hunks, and compose form state.

## Backend Model

Add a small Git domain object, for example `HQ::GitRepository` or `HQ::GitDiff`.

Responsibilities:

- Validate that the configured project path is a Git worktree.
- Collect status using a parseable format such as `git status --porcelain=v1 -z` or `--porcelain=v2 -z`.
- Collect diffs with shell-safe argument arrays through `Open3.capture3`.
- Disable pagers and colors.
- Limit max bytes, max files, and max lines.
- Detect binary files and huge diffs.
- Return structured data, not raw terminal text only.

Suggested scopes:

- `worktree`: unstaged changes, equivalent to `git diff`.
- `staged`: index changes, equivalent to `git diff --cached`.
- `all`: combined view against `HEAD`, equivalent to `git diff HEAD`.
- `untracked`: synthetic additions for untracked files, guarded by size and binary checks.

Suggested structured shape:

```json
{
  "project_key": "example",
  "head": "abc1234",
  "branch": "feature/diff-viewer",
  "scope": "worktree",
  "files": [
    {
      "path": "lib/example.rb",
      "old_path": null,
      "status": "modified",
      "binary": false,
      "additions": 12,
      "deletions": 4,
      "hunks": [
        {
          "header": "@@ -10,7 +10,9 @@",
          "old_start": 10,
          "old_lines": 7,
          "new_start": 10,
          "new_lines": 9,
          "lines": [
            { "kind": "context", "old": 10, "new": 10, "text": "  def call" },
            { "kind": "removed", "old": 11, "new": null, "text": "- old_code" },
            { "kind": "added", "old": null, "new": 11, "text": "+ new_code" }
          ]
        }
      ]
    }
  ]
}
```

## Remote API Sketch

Add project-scoped routes:

- `GET /projects/:key/git/status`
- `GET /projects/:key/git/diff?scope=worktree`
- `GET /projects/:key/git/diff?scope=staged`
- `GET /projects/:key/git/diff?scope=all`

For agent handoff:

- Reuse `POST /agents/:key/messages`.
- Include diff selection metadata in the message payload.
- Store selected diff context in memory as a normal user message plus metadata so it appears in both TUI and Web conversations.

Example agent message body:

```json
{
  "message": "Review this hunk and suggest the smallest safe fix.",
  "diff_selection": {
    "project_key": "example",
    "scope": "worktree",
    "file": "lib/example.rb",
    "hunk_index": 0,
    "line_range": [11, 18]
  }
}
```

For the first version, the server can expand `diff_selection` into bounded text before appending to agent memory. Later, it can persist references and rehydrate them from snapshots.

## Custom Diff Crafting

"Craft our own git diff" should be treated as a patch draft workspace, not as immediate mutation of the Git index.

Initial safe version:

- User selects whole files or hunks.
- Tycho builds a bounded patch bundle from those selections.
- The patch bundle can be copied, attached, or sent to an agent.
- Nothing is applied to disk.

More advanced version:

- User selects individual added/removed/context lines.
- Tycho recalculates hunk ranges and preserves enough context for `git apply`.
- Tycho validates with `git apply --check`.
- Applying the patch requires explicit confirmation.

Line-level custom patching is useful, but it is also where complexity spikes. Hunk-level selection should come first because it gives most of the agent-conversation benefit with far less parser and correctness risk.

## Implementation Phases

Phase 1: backend and read-only viewer

- Add a Git diff domain object with command timeouts and size limits.
- Add remote API endpoints for status and diff.
- Add tests with temp Git repos for modified, added, deleted, renamed, staged, unstaged, untracked, binary, and path-with-spaces cases.
- Add a Web UI project diff view.
- Add a TUI read-only diff view from the Projects screen.

Web-first implementation note:

- Start with `GET /projects/:key/git/status` and `GET /projects/:key/git/diff?scope=worktree|staged|all`.
- Render a project-level `#project/:key/diff` Web route with scope toggles and hunk-level read-only inspection.
- Preserve the TUI work for the next slice so the backend shape can settle against browser-visible behavior first.

Phase 2: agent conversation integration

- Add hunk selection.
- Add "send selected diff to agent" from both TUI and Web UI.
- Store selected context in agent memory with metadata.
- Render selected diff context clearly in chat logs.

Phase 3: patch bundle crafting

- Add file/hunk selection basket.
- Generate a patch bundle from selected hunks.
- Allow copy, download, or agent handoff.
- Keep this read-only by default.

Phase 4: guarded mutation

- Add `git apply --check`.
- Add explicit apply confirmation.
- Consider staged/unstaged patch workflows only after read-only and agent handoff are stable.

## Testing Notes

Backend tests should use temp repos and real Git commands. Important cases:

- Modified tracked file.
- Newly added tracked file.
- Deleted file.
- Rename detection.
- Staged-only change.
- Mixed staged and unstaged changes in one file.
- Untracked text file.
- Untracked or changed binary file.
- File path with spaces.
- Large diff truncation.
- Repository unavailable or not a Git worktree.

TUI tests should cover:

- Empty diff state.
- Dirty project with file list.
- Hunk rendering width behavior.
- Selection state across refresh.
- Agent handoff prompt text.

Web tests should cover:

- Diff route rendering.
- Scope toggles.
- File and hunk expansion.
- Selection surviving polling refresh.
- Mobile layout.
- Sending selected diff to an agent conversation.

## Risks and Guardrails

- Large diffs can make the TUI slow and the browser heavy; enforce byte and file limits.
- Diffs may contain secrets; do not automatically attach full project diffs to agents.
- Untracked files need special handling because plain `git diff` does not include them.
- Binary files should show metadata only.
- Shell interpolation should be avoided for Git commands.
- Submodules, worktrees, symlinks, and merge conflicts need explicit status labels.
- Diff parsing must preserve enough context to avoid misleading line references.

## Recommendation

This is a strong feature direction. The current "dirty file count" is a useful warning, but a diff viewer would turn Tycho into a real workspace inspection tool.

The best next step is a read-only diff viewer plus hunk-level agent handoff. That gets most of the productivity benefit without taking on the risk of applying or staging patches. Once hunk selection is stable, custom patch crafting can build on the same parsed diff model.

## Source References

- Git `diff` manual: https://git-scm.com/docs/git-diff. Verified active on 2026-06-06. Used for the three initial scopes: unstaged worktree diff, staged/index diff through `--cached`/`--staged`, and working tree against `HEAD`.
- Git `status` manual: https://git-scm.com/docs/git-status. Verified active on 2026-06-06. Used for the recommendation to parse `--porcelain` output because Git documents it as stable for scripts and independent of user configuration.
- Git `apply` manual: https://git-scm.com/docs/git-apply. Verified active on 2026-06-06. Used for the later patch-crafting guardrail around validating generated patches with `git apply --check` before any explicit mutation.
- GNU diffutils unified format manual: https://www.gnu.org/software/diffutils/manual/html_node/Detailed-Unified.html. Verified active on 2026-06-06. Used for hunk parsing concepts: file headers, `@@` hunk ranges, context lines, added lines, and removed lines.
