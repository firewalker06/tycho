# Changelog

All notable changes to Tycho will be documented in this file.

## Unreleased

## 0.10.1 - 2026-08-27

### Highlights

- Keep agent conversations live while a harness runs: Tycho now projects
  sequenced events into its durable conversation journal as they arrive, with
  loading feedback while history is opening.
- Let users queue follow-up prompts for a running agent. Queue entries persist
  and preserve submission order across refreshes and retryable start failures;
  the Remote UI keeps the composer usable and displays optimistic entries until
  the server confirms them.
- Make delegated-agent work clearer and safer. Direct user messages explicitly
  take over a child session, parent prompts can reclaim it, and both the Remote
  UI and agent switcher provide direct parent/child navigation.
- Improve Remote UI agent health and lifecycle visibility with reliability
  cards, clearer status icons, stale-state treatment, and refresh safeguards.
- Rank agent search results and highlight the matched text, so the most useful
  result is easier to find quickly. (#85)

### Fixes

- Keep attachment popovers above surrounding Remote UI content and preserve a
  consistent mobile inquiry header.

## 0.10.0 - 2026-08-15

### Highlights

- Add durable parent-child agent delegation with CLI/API provenance, automatic
  terminal reports to parent sessions, safe parent resume, and archive-stable
  bidirectional navigation in Remote UI.
- Add auditable run and native-session usage metrics with provider-correct token
  and cost normalization, archive manifests, idempotent historical backfill,
  CLI tables and JSON, and Remote API queries.
- Add direct `--server` CLI targeting for remote project inspection and the
  complete managed-agent lifecycle. Store one bearer credential per stable
  server key with login, logout, status, verify, and migration commands;
  `token_env` remains supported and inline tokens remain a warned fallback
  through v0.10.x.
- Validate managed-agent structured output before success, request bounded
  same-session corrections for Codex and Claude-compatible harnesses, preserve
  exhausted invalid responses privately, and align the canonical result schema
  across Codex, Claude-compatible harnesses, and cold OpenCode prompts.
- Add a read-only Remote UI project workspace browser with multiserver routing,
  bounded listings, safe text previews, durable navigation, and server-enforced
  traversal, symlink, binary, size, VCS, and secret controls.

### Other changes

- Add Tycho skill status, install, and update flows for Codex, Claude Code, and
  OpenCode, plus agent CLI installation guidance during onboarding.
- Add selected pull-request diff lines to agent context, speed up PR detail
  loading, and persist agent-owned PR catalogs and snapshots for fast switching.
- Add a global speech-mode shortcut and refine speech following, inline comment
  controls, Markdown code-block copy menus, and focused PR diff behavior.
- Keep unread counts and agent switching live through compact activity endpoints
  and independent Remote UI polling, including while focused views pause page
  refreshes.
- Keep the Settings section menu sticky in one horizontally scrollable row, add
  previous/next run-summary navigation, and add quick file downloads beside
  Summary attachment detail links.

### Fixes

- Retire expired Web Push subscriptions, renew stale browser subscriptions, keep
  daemon API and browser asset builds coherent, and preserve Windows PWA display
  and click routing.
- Preserve structured inquiries, focused views, attachment menus, forms, and
  polling state across desktop and mobile layouts.
- Preserve CLI-launched agent exit status, clear leaked Bundler setup from agent
  runners, and attach correction-runner stdin to the null device.
- Fix mobile Quick Agent, attachment flyout, diff return, schedule menu, and
  flexible popup layouts.

## 0.9.0 - 2026-07-31

### Highlights

- Make multiserver Agents and Projects persistent in Remote UI, with
  server-qualified resources, bounded peer refresh, stale last-good snapshots,
  and explicit peer cache removal.
- Introduce the Remote UI design system across Settings, forms, menus, status
  badges, confirmations, detail headers, empty states, and agent ledgers.
- Show each connected server's Tycho version in Settings, and flag peers whose
  version differs from the host while keeping older peers backward-compatible as
  version unknown.

### Other changes

- Prepare for a future GitHub App workflow, including device login,
  installation guidance, guarded review posting, immutable diff snapshots, and a
  paused Review Inbox while eager aggregation is redesigned. The GitHub App is
  not applicable for general use yet.
- Compact grouped Agents and Projects lists while preserving ownership,
  filtering, bulk archive behavior, and mobile action geometry.
- Add Claude Opus 5 to Claude model suggestions.
- Track lifetime agent run counts and preserve managed-agent run log offsets
  beyond the raw-log tail window.
- Add shared confirmation flows, contextual menu behavior, and composite
  Settings section patterns.

### Fixes

- Make remote server tests independent of auth state.
- Preserve Now context menus across polling refreshes.
- Prevent schedule action menus from clipping.
- Stop agents with stale unstructured output and preserve stopped-agent signal
  exit status.
- Normalize GitHub CLI output as UTF-8.

## 0.8.0 - 2026-07-21

### Highlights

- Add `tycho project` commands to create, inspect, update, and archive projects.
  Use `--json` in scripts.
- Add session loops in Remote UI to rerun an agent until a set time.
- Keep scheduled runs in the same agent session so they retain conversation
  context.
- Add response-style to set your agent tone. For example: "Use the simplest
  accurate words, active verbs, and concrete details." (#49)
- Add a full-screen conversation editor that keeps drafts during refresh and
  works on mobile.

### Other changes

- Improve Remote UI navigation, forms, conversations, summaries, diffs, and
  attachments on desktop and mobile.
- Add controls to run, pause, resume, and edit an agent schedule.
- Let inquiry replies include optional written feedback.
- Add attachment menus, refreshed previews, focused summary and file views, and
  a smaller mobile reply box.
- Add side-by-side and unified views for uncommitted Git changes.
- Improve run activity, token usage, attachment previews, schedule status, and
  agent renaming.
- Use `no_action_needed` only when a check finds nothing to do.

### Fixes

- Pass agent prompts safely so prompt text is not read as command-line options.
- Fix copying usage details when a value is missing.
- Remove extra header spacing on standalone iPads.
- Stop model and authentication checks from hanging when an agent CLI does not
  respond.
- Read models and authentication details from OpenCode 1.18.4 reliably.
- Keep follow-up messages sent in the same second an agent run finishes.

## 0.7.4 - 2026-07-06

### Bug Fixes

- Launch custom Claude-compatible harnesses directly instead of through a Ruby
  runner, and move leading `env KEY=value` assignments into the child process
  environment so native wrappers such as `mairu` are not interpreted as Ruby
  source files.

## 0.7.3 - 2026-07-06

### Bug Fixes

- Read raw agent logs as UTF-8 bytes and write managed-agent memory JSONL as
  UTF-8, so non-ASCII Codex output still captures assistant messages and run
  summaries when Ruby's default external encoding is ASCII.

## 0.7.2 - 2026-07-05

### Notable Releases

- Add authenticated peer debugging endpoints for managed agents, including
  bounded raw/memory/app log tails, memory event counts, dry-run memory capture
  parsing, and explicit memory rebuild from raw logs.

## 0.7.1 - 2026-07-05

### Notable Releases

- Add configurable harness model and effort catalogs in `hq.yml`, with Remote UI
  editing and persisted custom suggestions merged into discovered harness
  catalogs.
- Add Remote UI harness catalog refresh controls and detailed harness readiness
  rows for model, effort, command, source, path, and auth-provider inspection.
- Update Claude model suggestions to use Anthropic documentation aliases and
  remove Tycho-only convenience aliases.

### Others

- Add `tycho debug claude` diagnostics, including a managed-agent path with
  `--run-agent`, for comparing Claude auth status with real Tycho agent runs.
- Clear Ruby/Bundler loader environment variables before spawning external
  harness commands so source-checkout Bundler state does not leak into Claude or
  wrapper processes.

## 0.7.0 - 2026-07-04

### Notable Releases

- Add OpenCode harness support, including stream parsing, fixtures, registry
  wiring, harness inventory documentation, and skill discovery behavior.
- Add daemon mode for the Remote Sessions server so local Remote UI processes
  can be supervised more directly.
- Remove the app orchestration surface and consolidate project handling around
  the current project model.

### Others

- Add Remote UI agent switcher shortcuts and improve remote chat submission
  feedback.
- Add attachment content copy actions, tidy attachment detail controls, and fix
  Remote UI attachment downloads.
- Fix pull request diff counts and PR diff snapshot handling.
- Fix Codex skill discovery roots and refresh Remote UI loading states with the
  Tycho loader.

## 0.6.1 - 2026-06-21

### Bug Fixes

- Add a Remote UI token re-authentication path for existing remote servers, so
  another browser or device can save the peer token locally after switching to a
  token-protected server. (#42)
- Show a token recovery prompt when the active remote server rejects broker
  credentials and tidy compact server-row actions on small screens. (#43)

## 0.6.0 - 2026-06-20

### Notable Releases

- Add persisted Remote UI server switching for configured `remote_servers`,
  including backend proxy routes and selected-server persistence. (#39)
- Add Remote UI skill autocomplete and a quick agent switcher for faster chat
  composition and agent navigation. (#38)
- Show run summaries in Remote UI conversations and allow any Remote UI
  attachment file type.
- Improve source-checkout execution by loading the local Bundler context from
  `bin/tycho`. (#34)

### Others

- Preserve Remote UI scroll positions, menus, embedded attachment scroll, and
  local diff scroll controls across polling refreshes.
- Fix summary attachment menu behavior.
- Split managed-agent command building, structured result normalization, and
  shared Remote UI helpers into focused modules.
- Add a throwaway Remote UI smoke script for browser checks against temp config
  and log roots.
- Add semantic `name` attributes to Remote UI form controls while preserving
  existing labels and ARIA behavior. (#37)
- Read and write FileStore JSON/YAML content as UTF-8 so persisted state remains
  readable when Ruby's default external encoding is ASCII.

## 0.5.0 - 2026-06-13

### Notable Releases

- Add Remote UI project Git diff inspection and agent-attached GitHub PR diff
  snapshots, so operators can review worktree/staged/all changes and referenced
  PR changes in-app. (#24, #32)
- Add Remote UI schedule management for schedule create/edit/delete, manual
  run/pause/resume, daemon controls, and file-backed schedule message editing.
  (#25)
- Add Quick Agent creation in the Remote UI, with project/template defaults and
  advanced harness, model, effort, and sandbox options. (#29)
- Expand managed-agent control from the CLI and Remote UI, including new
  `tycho agent` subcommands plus clone/archive/run/stop/send and bulk archive
  flows. (#28, #30)

### Others

- Add shared Remote UI More menus and expose build metadata in setup. (#23)
- Add Tycho Claude skill documentation for the current CLI surface. (#26)
- Add the direct `erb` runtime dependency and make Git diff parsing stable when
  user Git config enables mnemonic prefixes. (#27)
- Improve PR diff loading, attachment download UX, expand/collapse behavior,
  diff detail headers, long-line scrolling, and mobile diff readability.
- Preserve Remote UI scroll positions, form values, composer state, and selected
  detail state across polling refreshes. (#31)
- Add conversation message copy menus and relative timestamps.
- Fix wide attachment viewer navigation and stale schedule state when archived
  scheduled-agent targets disappear.

## 0.4.0 - 2026-06-06

### Notable Releases

- Add grouped Web Push badge support so Remote UI notifications can update
  scoped browser badges and document push behavior. (#10)
- Add managed-agent model and reasoning effort settings with config inheritance,
  harness catalog suggestions, and TUI/Remote UI editing. (#15)
- Add drag-and-drop file attachments to the Remote UI composer. (#20)

### Others

- Improve the Remote UI Summary surface and keep run summary blocks out of the
  main conversation stream. (#11)

- Fix Claude structured output schema handling so Claude-compatible runs can
  produce and parse structured results reliably. (#13)
- Resume stopped schedules safely after interactive scheduled agents are
  archived, while preserving protection for user-touched sessions. (#14)
- Keep schedule rows visible in the Remote UI as schedule and daemon state
  changes.
- Add copyable Remote UI details for operator-facing metadata. (#16)
- Add a Remote UI agent sort dropdown for faster agent list triage. (#17)
- Clarify scheduled-agent titles so recurring run history is easier to scan. (#18)
- Add Remote UI project editing with JSON API support. (#19)
- Simplify schedule status handling to `scheduled`, `paused`, and `stopped`,
  with last outcome and error diagnostics tracked separately. (#21)

## 0.3.0 - 2026-05-31

- Add first-run onboarding for pristine installs, including TUI and Remote UI
  welcome sandbox creation under `~/.tycho/workspaces/welcome`.
- Simplify the Remote UI around `Now`, `Agents`, and `Settings`, with project
  and agent filtering consolidated into the Agents workspace.
- Add Remote UI bulk archive for idle agents and keep zero-agent projects
  reachable for first-agent creation.
- Improve Remote UI agent messages and summaries with markdown rendering,
  better iPad/PWA header spacing, and safe-area handling.
- Add clipboard paste uploads for Remote UI prompt attachments.
- Dedupe attachments by normalized URL or file path and show newly added
  attachments first.

## 0.2.1 - 2026-05-29

- Add a Remote UI attachment navigation drawer.
- Add a Remote UI unread agents panel on the header logo and keep detail
  headers visible while scrolling or focusing footer controls.
- Add an Intel macOS Lipgloss compatibility backend, `tycho doctor`, and
  install/release smoke checks for the Charm Ruby native extension path.

## 0.2.0 - 2026-05-28

- Add hidden project and group visibility settings for TUI and Remote UI
  project/agent filtering.
- Add Remote UI schedule controls for manual runs, pause/resume, and scheduler
  daemon start/stop/restart.
- Add Remote UI attachment management, including uploads, previews, copy,
  refresh, and delete flows.
- Make Remote UI attachment summaries toggleable and preserve relevant state
  across polling renders.
- Preserve mobile newlines in the Remote UI composer while keeping explicit
  keyboard Enter submission.
- Scroll the active Remote UI tab to the top when its selected nav item is
  clicked again.
- Replace the old HQ loading logotype with the Tycho wide banner and update
  visible TUI product copy.
- Add README screenshots for TUI and Remote UI workflows.

## 0.1.1 - 2026-05-24

- Add release maintainer runbook.
- Add README hero image.
- Make Remote UI prompt submission use Enter while preserving Shift+Enter
  newlines and IME composition.

## 0.1.0 - 2026-05-23

- Add MIT license and public contribution/security/code-of-conduct documentation.
- Add open-source readiness plan.
- Add Homebrew-first public README with source-install fallback.
- Add CI and `bin/test` test runner.
- Add version and gemspec metadata.
- Replace real parser fixtures and tool-shape notes with synthetic examples.
- Replace provider-specific Claude wrapper support with generic custom Claude harness configuration.
- Add Remote UI warning for unauthenticated non-loopback binds.
- Use `TYCHO_*` environment variables as the public runtime override contract.
- Add `tycho serve` and `tycho schedule daemon` so packaged installs can use one `tycho` command.
- Move default config, schedule prompts, runtime state, and logs under `~/.tycho`.
- Keep Homebrew installs from writing runtime process-shim files under the Cellar.

Upgrade notes:

- Homebrew users run `tycho`, `tycho serve`, and `tycho schedule daemon`.
- Existing source-checkout users should move local config, schedules, and logs
  into `~/.tycho` before relying on the new defaults.
