---
name: PROJECT_STATUS
description: HQ project status, key decisions, and roadmap
type: project
---

# Project Status - HQ

> **Purpose:** Living status document for HQ. Stable conventions and architectural guidance live in [CLAUDE.md](../CLAUDE.md); operational pitfalls live in [GOTCHAS.md](./GOTCHAS.md).

## Last Updated

2026-08-08

## Strategic Direction


Key references:

- [CLAUDE.md](../CLAUDE.md) — architecture, file layout, runtime behavior, coding style.
- [GOTCHAS.md](./GOTCHAS.md) — known operational pitfalls.
- [SYSTEM_PROMPT_AUDIT.md](./SYSTEM_PROMPT_AUDIT.md) — inventory of system prompts and automatically injected managed-agent context, including lifecycle timing and known contract gaps.
- [research/charm-ruby.md](./research/charm-ruby.md) — Bubbletea/Lipgloss/Bubbles Ruby usage notes.
- [research/logging-architecture.md](./research/logging-architecture.md) — `HQ.logger` design.
- [research/claude-json-schema-research.md](./research/claude-json-schema-research.md) and [research/codex-json-schema-research.md](./research/codex-json-schema-research.md) — agent stream formats.
- [research/a2a-protocol-research.md](./research/a2a-protocol-research.md), [research/agent-communication-protocol-research.md](./research/agent-communication-protocol-research.md), [research/hq-a2a-vs-acp-recommendation.md](./research/hq-a2a-vs-acp-recommendation.md) — agent protocol exploration.
- [REMOTE_SERVER.md](./REMOTE_SERVER.md) — Remote Sessions server architecture, runtime behavior, and API endpoint reference.
- [MULTISERVER_RESOURCES_PLAN.md](./MULTISERVER_RESOURCES_PLAN.md) — planned
  combined Agents and Projects catalog, peer health, explicit ownership, and
  bounded refresh model.
- [WEB_PUSH_PLAN.md](./WEB_PUSH_PLAN.md) — planned browser push notifications for Remote UI, including the hard HTTPS-over-Tailscale requirement.
- [SCHEDULED_RUNS.md](./SCHEDULED_RUNS.md) — planned cron-like scheduled runs, `tycho schedule daemon`, command targets, and prompt/message tradeoffs.
- [MODEL_ARGUMENTS_PLAN.md](./MODEL_ARGUMENTS_PLAN.md) — planned managed-agent `model` and `reasoning_effort` configuration, command mapping, and TUI/Remote UI display.
- [USAGE_METRICS.md](./USAGE_METRICS.md) — normalized run/native-session schema, provider cost semantics, query/backfill operations, archive behavior, and recovery.

## Key Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| TUI framework | Bubbletea + Lipgloss-compatible styling + Bubbles (Charm Ruby) | Elm Architecture fits the dashboard's event-driven model; Tycho uses native Lipgloss except on Intel macOS, where a Ruby compatibility backend avoids Go cgo callback crashes from multiple Charm native runtimes |
| Default data root | `~/.tycho` for config, schedule prompts, runtime state, and logs | Source and packaged installs should never write runtime data into the repository or Homebrew Cellar by default |
| Config split | `~/.tycho/config/hq.yml` (active) + `~/.tycho/config/hq.archived.yml` (archived) | Archive without losing history; logs move to `~/.tycho/logs/projects/archived/` |
| Project lifecycle CLI | `tycho project KEY` plus explicit create/show/update/archive commands, with normalized human or JSON output | Project registration and maintenance should be automatable without duplicating config rules or opening the TUI |
| Multi-file lifecycle writes | `FileTransaction` snapshots config/state files and runs compensating log moves around project archival and session-loop creation | A failed downstream step must restore project, agent, schedule, memory, and log state instead of leaving a partially completed lifecycle operation |
| External command capture | `CommandRunner` owns bounded process-group execution for harness discovery; GitHub integration uses direct HTTPS after resolving a GitHub App session or the compatibility credential from `gh auth token` | One process owner preserves signal exit status for tools, while GitHub API behavior remains isolated from CLI response formats |
| Agent transport | Codex JSON output; Claude-compatible `--output-format stream-json` | Streaming logs render incrementally in the chat viewport |
| Agent model controls | Optional per-agent `model` and `reasoning_effort`, inherited from project/template config and passed as harness run arguments | Model catalogs change outside Tycho; use harness discovery for suggestions where available, keep free-form fallback everywhere, and keep provider-specific thinking budgets out of first-version scope |
| Managed-agent identity | Generate keys as `<project>-agent-<UTC timestamp with microseconds>`, adding a short random suffix only on an exact collision; retain legacy numeric keys when loading existing state | Timestamp identities remain sortable and avoid key reuse when agents are created concurrently or archived across Tycho instances |
| Cross-harness response style | Append the current `~/.tycho/config/response_style.md` policy to every cold and resumed run, with project/template override or opt-out; record the harness `session_id` on each run | Keep operator-facing prose consistent without coupling the policy to a harness-native role API or persisting it into conversation memory, while retaining the native session identity used for each run; explicit task formats remain higher priority |
| Agent session strategy | Persist native Claude/Codex `session_id` per managed agent and resume after the first run; keep `memory.jsonl` as HQ's canonical transcript | Native resume recovers agent-side continuity and prompt-cache reuse. HQ only replays bounded `memory.jsonl` on first run or when no native session is known |
| Structured output correction | Validate the final Codex or Claude-compatible response against the canonical agent-result schema, then allow two same-session corrections by default (`TYCHO_STRUCTURED_OUTPUT_CORRECTION_LIMIT`, clamped to `0..5`); render each failure as a collapsed TYCHO system event block | Invalid JSON must not become a successful result; same-session feedback avoids rerunning completed tools, while operators can inspect safe retry details in context and exhausted responses remain available in owner-readable diagnostic files |
| Agent log layout | New agents use a per-agent stem `<project-key>-<created-at>-<nonce>` for `.raw.log`, `.conversation.log`, `.system.log`, `.memory.jsonl`, `.attachments.json`, `.status`, `.last_message.json`, and owner-readable `.invalid_structured_output.json` diagnostics when validation retries are exhausted; legacy `<key>.raw.log` records remain readable | Raw stream + parsed conversation + tool/system events + canonical event log + durable artifact links and invalid-response diagnosis without collisions when agent keys are reused after Remote/TUI archive timing differences |
| Chat viewport rendering | Hybrid: `memory.jsonl` for history, `raw.log` tail for live streaming | User messages appear immediately (written to `memory.jsonl` on send); assistant turns commit on run finalization |
| Agent chat conversation blocks | Conversation renders selectable blocks for user messages, agent messages, system events, and collapsed tool-call groups; Enter opens the selected block in a floating scrollable detail layer | Keeps normal chat scanning compact while preserving full tool/message detail on demand |
| Agent attachments | Structured agent results can include PR/document/image attachments, persisted in `.attachments.json` and mirrored into `memory.jsonl`, surfaced from chat with a `ctrl+a` navigable list | Durable links to artifacts survive later runs and memory rebuilds instead of living only in a single assistant message |
| Remote artifact rendering | Render attached HTML in an origin-isolated iframe with a restrictive content policy and package explicitly referenced, allowlisted workspace web assets; render sanitized Markdown Mermaid fences with a pinned, conditional CDN loader in strict mode | Interactive lessons and shared course assets remain usable without granting generated HTML access to Tycho or browser storage, and ordinary Markdown does not pay the Mermaid download cost |
| Pull request review | Agent-scoped PR diff inspection remains available; the cross-agent Review Inbox is paused because its eager aggregation is too slow and unresponsive | Redesign inbox discovery and loading around bounded, incremental work before restoring its route; retain GitHub App and `gh` compatibility |
| Conversation block scrolling | Initial chat load bottom-aligns the latest block when it fits, oversized blocks start at row 1, and navigation scrolls only enough to reveal the selected block | The selected label/cursor must remain visible and predictable while keeping surrounding recent context on first open |
| Conversation viewport offsets | Block `line_offset` / `line_height` are derived from the final rendered rows; long unbroken preview tokens are hard-wrapped before entering the viewport, and footer debug is computed after viewport sync | Bubbles `Viewport` counts newline-separated lines, while terminals visually wrap long tokens; stale or mismatched offsets cause misleading `visible 0/0` debug and cropped selected blocks |
| Inquiry submission | Gated review step inside a rounded box | Prevents accidental structured submissions |
| Input handling | `BubbleteaInput` patches `Bubbletea::Program#poll_event` with a Ruby-side queue | Fixes multi-byte / bracketed paste truncation in Bubbles `TextInput`/`TextArea` |
| Logging | Centralized `HQ.logger` (stdlib `Logger`), daily rotation, 7-day retention | Single sink for lifecycle, config, process, and silently-rescued errors |
| Skill discovery | Enumerate SKILL.md from `~/.claude/skills` + workspace `.claude/skills` (Claude-compatible harnesses) and `~/.codex/skills` + `~/.agents/skills` + workspace `.agents/skills` (Codex) | Per-agent trigger character (`/` vs `$`) surfaced in the chat composer |
| Tycho skill installation | Keep a checksummed bundled source manifest behind `SkillInstaller`; install to `~/.agents/skills` (Codex), `~/.claude/skills` (Claude Code), or `~/.config/opencode/skills` (OpenCode), and update only files proven Tycho-owned | One deep module owns current path conventions, status comparison, staged/atomic replacement, exact change reporting, and collision/error safety for Remote API/UI callers |
| Remote Sessions | Local JSON API and web UI via `tycho serve`; Tailscale auto-bind; terminal QR startup URL | Remote clients can inspect and control managed agents through the same `AgentStore` / `ManagedAgent` paths as the TUI |
| Remote UI responsive shell | Mobile keeps bottom navigation; wide desktop uses a wider content frame with side navigation; creation actions live in the header and focused detail/form routes remove unrelated global actions | Prevent fixed controls from obscuring content, use desktop space effectively, and keep page actions contextual across mobile, tablet, and desktop |
| Remote UI control sizing | Shared 44 px control and touch-target tokens, 16 px mobile form text, visible focus states, and explicit validation/status text | Avoid mobile auto-zoom, undersized targets, color-only state, and inconsistent action geometry |
| Remote UI design system | Keep a no-build internal system: semantic `--ds-*` tokens and reusable CSS components in `design_system.css`, product composition in `app.css`, and a static `/design-system` preview; migrate routes incrementally | Match the existing Ruby/vanilla-JS deployment, preserve behavior, make foundations governable, and avoid a framework or package rewrite |
| Remote UI deployment coherence | Snapshot all browser assets and their shared hash when `tycho serve` starts; require a daemon restart to load source updates | Prevent an old Ruby API from serving a newer on-disk JavaScript client after a pull, which can break push subscription renewal and other cross-boundary flows |
| Remote multiserver resources | Keep one UI-serving broker, aggregate only compact Agent and Project resources through a disk-backed stale-while-revalidate catalog, and require explicit server identity for details and mutations | Combined lists stay responsive across peer failures and broker restarts; only a validated full snapshot may remove cached resources, while schedules, setup, GitHub, push, restart, and other server-level behavior remain local |
| Project workspace browsing | Keep canonical path resolution, sensitive/generated-file policy, bounded listing, and text preview in `ProjectWorkspace`; expose only relative paths through project-scoped read-only endpoints | Remote and multiserver browsing must not leak host paths or let client routing bypass traversal, symlink, VCS, credential, binary, or size controls |
| Remote credential ownership | Bind one bearer credential to each stable remote server key and verified scheme/host/effective-port origin; keep Tycho-managed values in atomic mode-`0600` `~/.tycho/config/remote_credentials.json`, with explicit per-server `token_env` overrides | CLI and broker share one resolver, multiple peers cannot select credentials by incidental names, origin changes require explicit recovery, and browser promotion removes its copy only after verified persistence |
| Scheduled runs | Dedicated `tycho schedule daemon`, definitions in `~/.tycho/config/schedules.yml`, runtime state in `~/.tycho/logs/schedules.json`, validated standard cron syntax | Scheduled work should continue independently from the TUI and Remote UI while still reusing existing agent execution paths |
| Temporary session loops | Remote UI can adopt an idle conversation as a normal recurring schedule, run it immediately with schedule context, and stop it at a configured cutoff | Review-waiting sessions need lightweight polling without losing their existing context or creating a separate agent |
| Run cost provenance | Persist harness and model on each managed-agent run; raw-log cost rebuilds use that per-run metadata and leave legacy runs unpriced when provenance is missing | Historical estimates must not silently apply the agent's current model price to older runs |
| Usage metrics | Persist idempotent v1 run records and provider-scoped native-session aggregates in one atomic, locked store; normalize Codex cumulative counters and Claude-compatible per-run/modelUsage telemetry; query active and archived history through the same CLI/API module | Historical reporting must remain auditable without raw-log joins, guessed prices/models/session IDs, or conflating runs, native sessions, and managed agents |
| Schedule daemon freshness | `tycho schedule daemon` writes heartbeat state to `~/.tycho/logs/scheduler_daemon.json`; UI surfaces derive running/stale/stopped from heartbeat age and process liveness, and report untracked running daemons without heartbeat state | Users need to know whether cron work is actually ticking, not only whether definitions are valid |
| Schedule command scope | Agent-only schedules; each schedule owns one persistent managed agent session and accepts only inline messages or files under `schedules/` | Preserve recurring context without adding arbitrary shell execution or loose existing-agent targets |
| Schedule statuses | Schedules expose `scheduled`, `paused`, or `stopped`; last outcome and error reason are tracked separately. `no_action_needed` is reserved for observational checks where no action was necessary, while completed actions and deliverables use `success` | Keep healthy no-op checks quiet without hiding meaningful completed work from unread state and notifications |
| Schedule interactive protection | A due run stops with reason `interactive` when the schedule-owned agent has later user messages; resuming records an acknowledgement boundary and keeps the same session | User conversations in scheduled sessions must not be overwritten by the next cron tick, and recovery should be one explicit action |
| Schedule management | Expose schedule list/detail/run/pause/resume/reload in both TUI and Remote UI | Interfaces should manage and observe schedules, but the daemon owns ticking, locks, missed-run policy, and dispatch |
| Open-source license | MIT | Keep adoption simple while making contribution and reuse terms explicit |

## Current Focus

**v0.9 release**: persistent multiserver Agent and Project catalogs and the
second Remote UI design-system pass are complete. The Remote UI now aggregates
peer agents and projects through a stale-while-revalidate broker catalog, keeps
server-qualified detail and mutation routes explicit, persists last-good peer
snapshots, and shows each connected server's Tycho version in Settings with
host-version mismatch detection. GitHub App groundwork is present, including
device login, guarded review posting, and immutable diff snapshots, but the
canonical App workflow is not applicable for general use yet and the Review
Inbox route remains paused until discovery is redesigned around bounded
incremental loading. The remaining v0.9.0 work is to merge the release-prep
commit, tag the release, publish GitHub notes, update the Homebrew tap, and
verify the bottle.

## Roadmap

> Future milestones are directional, not commitments. Scope and priorities may change. Items below `Current` are candidate work surfaced from CLAUDE.md, recent commits, and research notes.

### v0.1 — Dashboard Foundation ✓

- [x] Bubbletea/Lipgloss/Bubbles TUI scaffold (`hq.rb` + `lib/hq/app.rb`)
- [x] Project registry from `~/.tycho/config/hq.yml` (`lib/hq/registry.rb`)
- [x] Concurrent project metadata refresh
- [x] Managed-agent persistence and restoration via `~/.tycho/logs/managed_agents.json`
- [x] In-app sidebar log viewer; `g` shortcut to open project terminal

### v0.2 — Managed Agents ✓

- [x] Codex / Claude-compatible execution paths
- [x] `AgentLogParser` for JSON / stream-json demultiplexing
- [x] Per-agent log artifacts: `raw.log`, `conversation.log`, `system.log`, `memory.jsonl`
- [x] Agent create/edit forms loaded from `~/.tycho/config/system_prompts.yml`
- [x] Structured inquiry form with gated review submission
- [x] Multi-select inquiry support; expandable wrapped inquiry text fields

### v0.3 — Chat & Memory ✓

- [x] Hybrid chat viewport: `memory.jsonl` history + `raw.log` live tail
- [x] `AgentMemory` canonical event log with bounded replay
- [x] `capture_run_memory!` finalization on run completion
- [x] Token usage persisted across runs
- [x] Collapsible/focusable agent chat summary section
- [x] Skill picker invoked from chat composer (per-agent trigger char)

### v0.4 — Input & Paste Hardening ✓

- [x] `BubbleteaInput` Ruby-side input queue
- [x] Raw + bracketed paste regression coverage in `test/rendering_test.rb`
- [x] Word-boundary chat composer wrapping; cursor visibility preserved

### v0.5 — Project Lifecycle & DX ✓

- [x] Project archiving (config + logs move to archived locations)
- [x] Project create/show/update/archive CLI with JSON output
- [x] New-project form with live path autocomplete
- [x] Per-project log organization under `~/.tycho/logs/projects/{project}/`
- [x] Centralized `HQ.logger` with daily rotation and 7-day cleanup
- [x] Loading screen with progress bar; deferred slow startup work
- [x] Global `ctrl-g` terminal shortcut; `ctrl-r` HQ restart

### v0.6 — Agent UX Polish and Stabilize ✓

- [x] Project git info surfaced in agent detail
- [x] Managed-agent unread-state fixes
- [x] Tycho logotype on loading screen
- [x] Run Tycho through `bin/tycho` as its own executable
- [x] Project’s icon statuses, similar to Agent’s icon statuses
- [x] Omnisearch floating fuzzy finder for agents and projects
- [x] Agent chat attachments from structured output (`ctrl+a` floating panel)
- [x] Remote UI multiserver broker foundation for configured `remote_servers`
- [x] Remote UI skill autocomplete and quick agent switching
- [x] Remote UI run summaries, broader attachments, and state preservation fixes
- [x] Sandboxed HTML attachment previews and lazy Mermaid chart rendering
- [x] Source-checkout `bin/tycho` Bundler boot fix

### v0.7 — Open Source Readiness ✓

- [x] Add MIT license, README, contributing guide, code of conduct, security policy, changelog, issue templates, PR template, and CI workflow
- [x] Add `bin/test` as the public CI-equivalent test runner
- [x] Replace real parser fixtures and tool-shape notes with synthetic examples
- [x] Replace provider-specific Claude wrapper code with `custom_harnesses` configuration
- [x] Add Remote UI warning for unauthenticated non-loopback binds
- [x] Run gitleaks history secret scan with documented false-positive allowlist
- [x] Publish from a clean public repository instead of exposing private history
- [x] Publish `v0.1.0` GitHub release
- [x] Add release maintainer runbook
- [x] Publish public Homebrew tap formula
- [x] Add README screenshots for TUI and Remote UI workflows

### v0.8 — Remote Workflows and Release Hardening ✓

- [x] Add project lifecycle commands with JSON output
- [x] Add persistent scheduled sessions and temporary Remote UI session loops
- [x] Add global and scoped cross-harness response-style policy
- [x] Complete the responsive Remote UI design remediation and full-screen
      conversation workflows
- [x] Validate Codex 0.144.6, Claude Code 2.1.216, and OpenCode 1.18.4 cold and
      resumed sessions
- [x] Bound harness catalog probes and normalize OpenCode catalog output
- [x] Document the Homebrew bottle `pr-pull` publishing workflow

### v0.9 — Multiserver and Review Workflows ✓

- [x] Add persistent multiserver Agent and Project catalogs in Remote UI
- [x] Persist last-good peer snapshots across broker restarts and failed refreshes
- [x] Route peer Agent and Project details and mutations through explicit server keys
- [x] Add direct `--server` CLI control for remote project reads and managed-agent lifecycles
- [x] Show peer health, token state, and Tycho version compatibility in Settings
- [x] Prepare GitHub App device login and guarded pull request review posting
- [x] Store immutable pull request diff snapshots separately from review state
- [x] Promote Remote UI design-system contracts across forms, menus, badges,
      confirmations, detail headers, and empty states
- [x] Pause the eager Review Inbox until bounded discovery and loading are redesigned

## Features Candidates

### Release Hardening

- [ ] Formalize specs
- [x] Stabilize source packaging and pre-release browser/TUI checks
- [ ] Publish and verify the 0.9.0 Homebrew bottles

### Canonical Tycho GitHub App

- [ ] Build and publish a Tycho homepage for marketing and use it as the
      canonical GitHub App homepage URL
- [ ] Register the public Tycho GitHub App with Device Flow enabled and the
      documented repository permissions
- [ ] Copy the App's public client ID and canonical slug into Tycho defaults,
      while retaining environment overrides for forks, development, and
      GitHub Enterprise

### Pull Request Review Inbox

- [ ] Redesign cross-agent discovery so opening the inbox does not synchronously
      fetch metadata and review context for every pull request
- [ ] Restore the Review Inbox route only after bounded loading, cancellation,
      and responsive desktop and mobile behavior pass browser checks

### Multiserver Agents And Projects

- [x] Add compact Agent and Project resource snapshots without Git work in list
      requests
- [x] Add a broker-owned stale-while-revalidate catalog with bounded peer
      refresh, independent health, and last-good snapshots
- [x] Persist last-good peer snapshots across broker restarts; retain them on
      failed or incomplete refreshes and forget them on explicit cache clear or
      peer removal
- [x] Merge server-qualified Agents, Now, and Projects lists in Remote UI
- [x] Route Agent and Project details and mutations through explicit server keys
- [x] Remove global peer switching and restrict generic peer proxying after the
      qualified resource flow is stable

### Model And Effort Arguments

- [x] Add planning doc for managed-agent model and reasoning effort fields in `docs/MODEL_ARGUMENTS_PLAN.md`
- [x] Add Codex catalog-driven model and effort suggestions from `codex debug models`
- [x] Add Claude alias/help-derived suggestions without hard validation
- [x] Add config inheritance and persisted `ManagedAgent` fields for `model` and `reasoning_effort`
- [x] Add dirty-field-aware dynamic model/effort suggestions when harness, template, or model selection changes
- [x] Pass model and effort through Codex, Claude, and Claude-compatible command builders
- [x] Display and edit model and effort in the TUI and Remote UI

### Scheduled Runs

- [x] Decide scheduler owner: dedicated `tycho schedule daemon`
- [x] Decide config source: `~/.tycho/config/schedules.yml` with cron syntax validation
- [x] Decide management surfaces: TUI and Remote UI
- [x] Decide command scope: persistent schedule-owned agent only; no shell, templates, loose existing-agent targets, or clones
- [x] Decide prompt sources: inline text or files under `schedules/`
- [x] Decide failure/success notifications: stop and web-push on failure; notify only first success and first success after failure
- [x] Add `ScheduleRegistry` / `ScheduleStore` and persisted runtime state in `~/.tycho/logs/schedules.json`
- [x] Persist scheduler daemon heartbeat state in `~/.tycho/logs/scheduler_daemon.json`
- [x] Add `tycho schedule daemon` with `--once`, `--dry-run`, and long-running daemon modes
- [x] Support persistent schedule-owned agents with repeated scheduled messages in the same session
- [x] Stop due runs when the schedule-owned agent has unacknowledged user conversation
- [x] Simplify schedule status to scheduled/paused/stopped with separate last-outcome details
- [x] Add quiet `no_action_needed` structured outcomes for recurring checks with nothing to act on
- [x] Support editable schedule system messages and inline run messages in one form; legacy file-backed run messages load into the form and save inline
- [x] Append the final-output attachment checklist at scheduled execution time without storing repeated checklist text in memory
- [x] Add Remote JSON API schedule list/run/pause/resume/reload
- [x] Show schedules and daemon freshness in the TUI and Remote UI Now view
- [ ] Add TUI schedule management
- [x] Add Remote UI schedule management
- [x] Add configurable Remote UI session loops with prompt templates and end-of-day expiry

### Omnisearch

- [x] Press `<space>` from the Agent/Projects sidebar focus to open a floating fuzzy search panel above the current screen
- [x] Search both managed-agent names and project names from one input
- [x] Show unread agents by default, then ranked active results while typing
- [x] Navigate results with up/down arrows and press Enter to select the matched agent or project on its screen
- [x] Keep Omnisearch inactive outside sidebar focus so it does not interfere with detail panels, chat composers, forms, text areas, or overlays

### Session Continuity

- [x] Persist Claude/Codex `session_id` on `ManagedAgent` and `AgentStore`
- [x] Pass `--resume <session-id>` (or `--session-id <uuid>` on first run) to recover native prompt-cache reuse
- [x] Decide replay-vs-resume policy: HQ-side `memory.jsonl` replay vs. native session resume per agent type
- [x] Document tradeoffs in CLAUDE.md and update agent prompt budgeting
- [x] Ability to switch Chat to Interactive Mode (resume in agent harness, e.g. codex, claude) via `ctrl+t` agent terminal shortcut
- [x] Validate structured output and request bounded same-session corrections across Codex and Claude-compatible harnesses

### Agent Protocol

- [ ] Evaluate A2A vs ACP for managed-agent transport (see `docs/research/hq-a2a-vs-acp-recommendation.md`)
- [ ] Prototype protocol adapter behind `ManagedAgent`
- [ ] Decide whether to keep direct CLI invocation or move to a protocol-mediated runtime

### Observability

- [x] Structured run/native-session usage, cost, timing, completeness, and lifecycle metrics
- [ ] In-app log filter / search for `~/.tycho/logs/hq.log`
- [ ] Agent run timeline view

### Personality Tweaks

- [ ] Revamp header: inverse background with the font color, let font color to white. Add quote of the day
- [ ] Implement Claude wordy quirkiness to Header and Loading Screen


- [x] Add Tycho tools to be executed by harnesses

### Planning Flow Tools

- [ ] Open markdown document (e.g. plan/spec) from agent or project context
- [ ] Open Neovim filtered by `git status` (changed files only) for quick review/edits

### Expand Tools messages

- [x] Expand all summarized tool calls
- [x] Creates different styling for tool calls
- [x] Will it be performant if the tool calls in chat logs are collapsible?

### Agent Chat Follow-ups

- [x] [ui] Move Conversation block diagnostics (`Block 71/81`, visible line count / viewport height) to the right side of the Conversation section header as compact icons and numbers
- [x] [ux] In Conversation block detail view, allow left/right to move to previous/next block and show compact (`Block 71/81`, visible line count / viewport height) detail metadata on the right side of the detail header

### Restart Agent Feature

- [x] Ability to Clone/Copy agents as the user-facing "restart with fresh logs" flow:
  - [x] Add an Agents-screen clone action that copies the selected agent's template/workspace/prompt/sandbox/harness into a new managed agent with a fresh key, empty logs, no runs, and no native session id
  - [x] Use `C` as the shortcut because `c` already opens chat and `ctrl+c` currently means quit/interrupt in the TUI
  - [x] After cloning, prompt whether to archive the old agent or keep it. Default: archive
  - [x] Select the new cloned agent and open chat so the next run starts from a clean transcript

### Remote session

- [x] Ability to start webserver (`tycho serve`)
- [x] Tailscale auto-bind, MagicDNS URL display, HTTPS Serve detection, and compact terminal QR for phone setup
- [x] Mobile Remote UI shell at `/` with simplified `Now`, `Agents`, and `Settings` tabs
- [x] Footer navigation sticks to the viewport, hides on downward scroll, and reappears on upward scroll
- [x] Read agent conversation (`GET /agents/{key}/conversation`)
- [x] Submit prompt to agent (`POST /agents/{key}/messages`)
- [x] Start / Stop an agent (`POST /agents/{key}/start`, `POST /agents/{key}/stop`)
- [x] Creates / Edit an agent (`POST /agents`, `PATCH /agents/{key}`)
- [x] Archive one agent (`DELETE /agents/{key}` or `POST /agents/{key}/archive`) or bulk archive idle agents (`POST /agents/archive`)
- [x] Project list/detail endpoints and mobile project detail screens
- [x] Remote setup/readiness endpoint and Settings screen
- [x] Remote Settings editor for the global `response_style.md` policy with atomic persistence and backup
- [x] Client-side Remote UI filtering across agents and projects
- [x] Remote UI skill discovery for chat insertion
- [x] Browser push subscription/test-notification foundation, with HTTPS MagicDNS support and HTTP MagicDNS warnings ([WEB_PUSH_PLAN.md](./WEB_PUSH_PLAN.md))
- [x] Automatic browser push notifications when agents require response or finish
- [x] Dedicated mobile structured inquiry submission UI
- [x] Full-screen inquiry editor with trailing unstructured Leave feedback field
- [x] Poll-safe inline and full-screen Conversation/inquiry forms that remain attached and focused during shell refreshes
- [x] Attachment detail context menus with exclusive Balanced/Widen/Full layouts, content/path copy, and forced cache refresh
- [x] Responsive desktop/mobile shell with persistent, header-aligned in-shell desktop navigation across top-level and detail routes, consistently named New agent action, shared control sizing, and fixed-region safe-area handling
- [x] Sticky Settings section navigator over one continuous page and copyable native session ID in Conversation Settings
- [x] In-flow desktop conversation composer with resize-aware mobile content reservation
- [x] Accessible full-screen Conversation editor with polling-safe autosaved drafts, focus containment, mobile visual-viewport sizing, and Escape-to-exit
- [x] Focused Summary/Attachment full-view controls and compact mobile follow-up composer
- [x] Finalized-run estimated session-cost snapshots on latest and historical Summary pages, including Codex token-delta estimates from an auditable OpenAI model rate card, explicit rebuild backfill, and no startup log scan
- [ ] Dedicated mobile activity/log detail page
- [x] Full mobile agent create/edit form
- [x] First-class run/native-session usage metrics, idempotent historical backfill, archive manifests, and CLI/Remote API reporting

## Known Issues

Documented in [GOTCHAS.md](./GOTCHAS.md)
