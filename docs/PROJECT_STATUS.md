---
name: PROJECT_STATUS
description: Tycho project status, key decisions, and roadmap
type: project
---

# Project Status - Tycho

> **Purpose:** Living status document for Tycho. Stable conventions and architectural guidance live in [CLAUDE.md](../CLAUDE.md); operational pitfalls live in [GOTCHAS.md](./GOTCHAS.md).

## Last Updated

2026-11-14

## PWA startup screen

The startup screen selects one of two animations at random once per startup:
the original rotating mark with radial particles, or three fast sequential
curved strokes around a fixed mark. Both use equal gaps between the logo dots.
Reduced motion stops motion and removes particles. Startup text uses responsive
21–35 pixel bold type. Appearance Settings has a plain-text textarea with one
candidate per line (8,000 characters total, 240 per displayed candidate). Blank
lines are ignored; one candidate is selected once per startup. Absent or blank
lists use “The factory must grow” and “Orchestrating the orchestrator”. Existing
single-message values remain compatible.

The preference belongs to this browser and server origin, as with appearance;
it is read safely inline before app scripts. It does not change project or
account settings. Inline recovery offers Retry if the app script cannot load.
App readiness and its existing timeout, offline, authentication, and retry paths
control the shell without an artificial startup delay. Neither Retry nor
Settings rotates the selected animation mid-load. The preserved legacy source
snapshot remains intact. See [Remote UI appearance](REMOTE_UI_APPEARANCE.md).

## DeepSeek Harness

The native `dsh` headless adapter targets DeepSeek Harness 0.2.2-rc.1. It uses
stdin, native JSON events and session adoption, explicit permission presets,
and Tycho's structured-result correction. Model selection uses an invocation
only overlay for the native DeepSeek route. Authentication remains operator
managed and unknown to readiness checks. This preview adapter does not route
Claude Code to DeepSeek. See [DeepSeek Harness](DEEPSEEK.md) for its contract,
verification, and unsupported features. The shared Remote UI harness label now
includes the official DeepSeek whale icon, with unchanged upstream SVG bytes
and palette-aware rendering in Settings and existing agent surfaces.

## Progressive PR diff fetching

Remote UI **Fetch all diffs** uses the existing three-request queue. It fetches
the selected PR first and renders completed diffs before the batch ends.
Failed refreshes preserve saved diffs; a final list read reconciles metadata.
The per-PR server membership checks, explicit refresh behavior, and shared
snapshot store remain in use. See [the timing investigation](research/card-867-pr-diff-loading.md).

## Empty queue migration audit retention

The local `queue-work cleanup-migrations` command reports obsolete empty
migration receipts. Explicit apply retains 100 eligible receipts and removes
at most 1,000 per run under the lifecycle lock and recoverable queue journal.
It preserves all queue records, generations, archive references, creation
receipts, and completion evidence. Missing queues never qualify as empty.
Dry run never installs a pending transaction: it returns a recovery-required
error without a plan and leaves queue, agent, archive, journal, and backup data
unchanged. Apply retains lifecycle recovery before it plans cleanup.
See [retention policy](QUEUE_MIGRATION_RETENTION.md) for selection and limits.
No operator cleanup is part of this change.

## Manual Remote UI project creation

The Agents page and onboarding screen provide New project. Only Project Name
is initially visible; Options contains Project Key and Group. Explicit custom
keys survive Name edits, polling and reload; Use name restores automatic keys.
The form uses the default starter location without a folder control or preview.
A confirmed creation opens a native modal with project information and one Okay
button. Navigation waits for acknowledgment. Durable request receipts support
safe manual retries after uncertain replies and confirmed-modal reload recovery.
Desktop/mobile Dark/Light browser checks cover the minimal form, modal keyboard
focus, polling, errors, lost replies and malformed replies. Existing custom-path
API, configuration and CLI/agent behavior stay in place.

The operator explicitly approved trusting same-user and root processes.
Hostile same-UID lifetime isolation and earlier storage/guard research are
superseded. Held directory handles, owner/mode checks, native macOS ACL checks,
and a qualified local-filesystem set protect against other-user ancestor
relocation. Sticky parents require trusted child ownership. Unknown permission
or filesystem evidence fails clearly. New entries are private; existing files
and ACLs are preserved. This is not isolation from trusted root disk services.
See [the current path and trust contract](REMOTE_SERVER.md#manual-project-creation).

Deterministic tests cover path escape, parent/starter replacement, permission
rejection, sticky parents, ACL grants, Welcome preservation and existing safe
aliases. Desktop/mobile checks use an isolated server home. PR346 stays
published; each changed head requires fresh independent review.

## Scheduler startup intent

Daemon ticks preserve paused and stopped schedule state. A stopped target now
holds due automatic work even when the saved schedule still reports success.
An explicit schedule resume records the stopped target key and persistent run
ID, even before the first due tick, and waits for the next due time. This
acknowledgement cannot permit a later stopped run in the same second after
reload. Automatic acceptance checks the current stop again under the agent
lock before adding a message or starting work, so a newer stop committed after
the scheduler snapshot stays held. Legacy timestamp-only records require a
new explicit acknowledgement.
Manual Run remains available. Idle, successful, and partial targets keep
normal scheduled execution. Restart regression tests use isolated runtime roots.
Archive integration tests cover paused, stopped, acknowledged, and awaiting-input
schedules: archived schedules stay inactive, retain history and delayed work,
and reject manual or automatic resume.

## Remote UI Schedules navigation

Schedules now has a dedicated `#schedules` page with the existing status,
management, and session controls always visible. Desktop and mobile primary
navigation contains Now, Agents, and Schedules. Desktop Settings is a plain
link with the existing gear icon at the bottom of the desktop sidebar; mobile
Settings stays in the context menu.
Schedule save, cancel, and Back actions return to Schedules. The Now empty-state
follow-up remains separate in card #860.

## Manual queue delivery with inactive schedules

The agent queue offers a one-time selected or full delivery while its linked
schedule is paused or stopped. CLI and API calls use the same locked selection
path. Schedule state remains unchanged and later automatic dispatch stays off.
This action reports inquiry, workspace, running-agent, and recovery blockers
before saving selection. Failed launches retain claims for explicit Retry.
See [Remote Sessions queue processing](REMOTE_SERVER.md#post-agentskeyprompt-queueprocess).

## Central queue storage

Queue state now lives in `queues.json`, keyed by target agent. Active agent
records and new archive manifests keep references and matching generations.
A durable journal completes interrupted queue and agent writes before any new
claim. Migration retains identifiers and checksums, while the existing server
timer, scheduler daemon, and every dispatch gate remain in use. See
[Central queue storage](QUEUE_STORE.md) for migration, deployment, and recovery
boundaries. Development does not migrate operator data.

## Managed prompt transport

Custom profiles can select a validated version 1 `argv`, raw `stdin`, or
private `file` transport. An omitted setting preserves the current native
adapter behavior, including Pi RPC. File mode uses the shared stdin and
UTF-8 correction path. Durable ownership records and process locks allow
parent cleanup after managed cancellation and stale-file recovery at startup
and the next run, while preserving active files. See [Custom harness profiles](CUSTOM_HARNESSES.md).


Command builders declare the prompt transport. Codex managed runs use stdin
with `exec -` or `exec resume ID -`; Claude uses print-mode text stdin; agy
uses `--print --input-format text` with stdin for new and resumed runs. Pi uses JSONL RPC
over stdin, including resume and correction. Pi 0.84.4 is the validated
baseline. The runner waits for `agent_settled`, or confirms idle handled input
after acceptance, before EOF shutdown. It bounds process exit and stops only
its child PID if needed. Explicit UTF-8 RPC bytes also work with the C locale.
It maps `get_state.sessionId` to the existing session event. OpenCode 1.19.3
uses text stdin with `run --format json` and no positional message, including
native resume and structured-output correction. Its source reads the pipe as
UTF-8 without trimming; a real CLI check with a local mock provider preserved
a 1.8 MB Unicode prompt under the C locale. No separate API server is needed.
Pi prompt files are not used: file expansion wraps and changes the input.
The correction runner receives its configuration through stdin, so command
arrays with prompt text do not enter the runner environment. Shared correction
configuration, schema and result reads, feedback, and output use explicit UTF-8
with binary IO. All five adapters preserve Unicode under the C locale. Pipe
writers run concurrently with stdout reads. Raw logs and canonical memory keep their
existing prompt content; saved command descriptions redact prompt arguments.
Installed Codex CLI 0.166.0 help confirms both stdin forms. agy CLI 1.5.1 help
confirms text stdin, print mode, conversation resume, JSON Schema, and
stream-json output. Follow-up harness transport work is tracked separately in
cards #812 through #816.

## Message acceptance and background reads

The Remote UI uses an opt-in small message receipt. Durable acceptance and
required schedule/activity effects finish before acknowledgment. Other callers
keep the full response. Accepted IDs and request fingerprints remain with the
agent, so retry after queue consumption does not append another message.
Definite input rejections, including stale PR context, fence their IDs after
transaction rollback. Schedule resume effects bind to the original stop and
persist their completion and result; old retries cannot resume a newer stop.
Pending browser messages retain their exact destination and payload in
IndexedDB until acceptance or a bound rejection. Credentials are never stored
with them. Writes stay ordered per agent; coalesced background reads do not
hold that write lane. Receipt-only queue rows stay read-only until canonical
queue data arrives. See [Remote Sessions](REMOTE_SERVER.md#small-message-receipts).

Agent detail now supplies read-only acceptance proofs bound to the original
request, raw agent, and server IDs. A matching proof clears a stale browser retry
without another write; text equality is not evidence. Incomplete schedule effects
still require exact retry. Cancel retry persists an atomic browser-wide stop, keeps accepted
server work, and ignores late responses. Live-tab notifications update views;
transactional stop checks protect stale writes and dispatch even without them.
Lane tokens let read proof release an accepted request while its old HTTP reply
is held. Late replies cannot unlock newer work. Compact stop markers have no
age expiry; safe collection needs a fence against every older writer. Uncertain payloads stay separate from
new drafts; only bound rejections restore correction drafts.

## Inquiry answer recovery

Remote UI inquiry answers use a separate bounded intent contract. Exact retry
resolves the original answer after an uncertain response. The record binds the
inquiry, server, payload, ownership, run decision and schedule stop IDs. Newer
inquiries, user stops and ownership changes supersede unfinished effects.
Browser recovery retains form values, feedback and file bytes through reload
and navigation, and requires an explicit Retry answer action. Unbound errors
remain uncertain. The existing display response and read remain for Card789.
See [Inquiry answer recovery](INQUIRY_ANSWER_RECOVERY.md) for bounds and limits.

## Agent read latency

Agent detail, conversation, setup summary, and project reference reads use a
committed store snapshot when the shared cache expires or an unrelated write
invalidates it. These reads do not acquire the lifecycle maintenance lock.
Polling and mutation paths keep recovery, queue dispatch, and delegation work.
Initial agent routes render before nonessential setup and schedule reads finish.
Shell completion preserves the current route, draft, focus, and scroll; shell
failures still use the authentication and retry flow. Setup responses use their
own request order, so a late summary cannot erase newer detailed Settings data. See
[Remote Sessions](REMOTE_SERVER.md) for snapshot and timing details.

## Project Git metadata demand

Remote Sessions refreshes Git metadata only when a detail view requests it. The server shares a 10-second cache and at most two background workers. Startup, list browsing, registry reloads, and archived-agent search do not start a metadata sweep. Cold, stale, and failed values are not shown as Clean. Failed fields retain their last good values. Archived branch search uses only the last branch observed by this server; cold branches have no match. Metadata reads and completion polls belong to a view token. Navigation, blur, hide, and close cancel the token and pending reads; late replies cannot restart work. Closed HTTP requests cannot add new demand. TUI and CLI refresh behavior is unchanged. See [Remote Sessions API](REMOTE_SERVER.md).

## Remote connection admission

Remote Sessions keeps 32 workers and limits each TCP peer address to 24 open
worker connections by default. Extra connections get a prompt HTTP 429 or close.
Headers have a separate 1-second total deadline. Bodies retain a 10-second read
budget; response lifetimes are unchanged. Shared brokers can configure up to 31
connections per address. See [Remote connection limits](REMOTE_SERVER.md#connection-limits).

## Remote UI appearance

Card 772 selects Nord Light alongside the existing default Dark appearance.
The selected conversation mapping is nord5 canvas, nord6 assistant surfaces,
and nord8 user messages with nord0 text. Settings offers an explicit local
Dark/Light/System preference; System follows the OS only when selected.
Card 773 adds faithful Light PNG variants for the symbol and wordmark, with
Polar Night details and the original orange segment. Dark and installed icons
remain unchanged. Persistence, platform limits, and verification are documented in
[Remote UI appearance](REMOTE_UI_APPEARANCE.md).

## Optimistic agent creation

Quick Agent and Project New agent now open a pending Conversation immediately.
Requests keep their prompt, options, and server binding through retry and tab
reload. Definite rejections permit correction or discard; uncertain acceptance
keeps the original retry ID. Completed tab records retain no prompt or catalog.
A durable creation receipt returns the same readable active or archived agent
after a lost response and prevents a second run. A retry after a saved creation
but interrupted startup returns the existing agent for explicit inspection or
start. Measurements and limits are in
`docs/research/agent-creation-card-750.md`.

Receipt lookup separates missing historical records from receipt uncertainty.
A missing manifest and backup can be excluded only for an exactly dated archive
whose name and directory modification time precede receipt capability on
2026-10-29 (first source `0429119`, merged in PR 281). Creation reports unavailable
archive history through API metadata, a UI warning, and the application log.
This does not certify archive health. Invalid or unknown dates, recent metadata,
symlinked directories, present damaged records, access failures, and missing
receipt-era records remain strict. Manifest writing began earlier, in `e04dcfb`
on 2026-08-08; the 2026-08-14 change added archive browsing.

## Quick Agent opening

Quick Agent opens an editable prompt before option reads finish. A local
`GET /quick-agent/options` supplies eligible projects, template defaults, and <!-- local-path-ok -->
shared offline harness catalogs without Settings discovery. Cached peer choices
arrive through the existing resource catalog; only the selected peer needs a
project detail read. Creation waits for the selected project's known options,
with server validation unchanged. Session/request guards reject stale replies.
Close retains the in-memory draft until submission; reload starts a new opening
draft. Create saves an idle agent with `start: false`. Create and run and Enter
use `start: true`. Both footer actions share readiness and pending gates and the
existing creation snapshot and receipt protocol.
See [Card 770 evidence](research/quick-agent-options-card-770.md).

## Experimental native agy support

Tycho adds a native Antigravity CLI adapter with independent
event parsing, model discovery, native conversation resume, and structured
result validation. Claude and Pi behavior is unchanged. agy always requests
plan mode and terminal restrictions, but filesystem isolation is unverified.
This is not a production deployment. See [AGY.md](AGY.md).

## Latest Fix

Run Summaries now keep a snapshot of delegated create, confirmed start, and
accepted or queued send actions from the parent run. Tycho builds this snapshot
from durable domain events at Summary generation. Conversation and the full
Summary show the saved actions and target links. Reads apply current reference
visibility without rebuilding actions; older summaries remain unchanged. Queued
launches retain the accepting parent run ID, so an unrelated later parent run
does not inherit their confirmed start actions. Already-confirmed native markers
are recovered before parent polling can finalize a Summary. Recovery of a finished
but unpolled parent requires the matching origin and a marker file time strictly
before a matching native-wrapper exit receipt and a valid run-scoped status.
The receipt is an internal `.status.native-exit` run artifact; monitor fallback
status writes do not produce it. Missing or equal source times do not justify
attribution, and completed summaries are never rewritten.

Tycho now requires Ruby 4.0.9 or later. The gem requirement, Bundler
requirement, lockfile, and setup checks use this minimum version.

The Remote UI **Clone and archive** form now requests source archival. Unstarted
independent clones become active in the same locked store transaction that
archives the source. Failed archives retain source work and do not publish a
replacement. Started and scheduled context replacements retain their existing
recovery and schedule ownership rules.

The Remote UI queue summary shows processor activity from the server's most recent
successful agent check, plus the applicable queue gate or earliest delayed time.
Failures that prevent a successful pass do not refresh the heartbeat. A pass
completed from a valid backup counts as successful under the existing store rules.
The five-second check interval is an estimate of the next check, not a launch
guarantee. Start queue uses the existing locked manual queue control and appears
only for eligible, due-only work when the automatic processor has no recent check.
Pending queue times use relative eligibility labels. A local clock updates them
while polling is paused, without changing queue state or promising a launch time.

## Strategic Direction

Managed agents support explicit same-server parent references, ownership generations for direct-user takeover and parent reclaim, durable terminal report-back, safe automatic parent resume, reversible callback disconnects, archive-stable navigation, and typed Remote UI relationship links. See [AGENT_DELEGATION.md](./AGENT_DELEGATION.md) for the CLI/API and callback contract.


Key references:

- [CLAUDE.md](../CLAUDE.md) — architecture, file layout, runtime behavior, coding style.
- [GOTCHAS.md](./GOTCHAS.md) — known operational pitfalls.
- [research/charm-ruby.md](./research/charm-ruby.md) — Bubbletea/Lipgloss/Bubbles Ruby usage notes.
- [research/logging-architecture.md](./research/logging-architecture.md) — `HQ.logger` design.
- [research/claude-json-schema-research.md](./research/claude-json-schema-research.md) and [research/codex-json-schema-research.md](./research/codex-json-schema-research.md) — agent stream formats.
- [REMOTE_SERVER.md](./REMOTE_SERVER.md) — Remote Sessions server architecture, runtime behavior, and API endpoint reference.
- [HARNESS_INVENTORY.md](./HARNESS_INVENTORY.md) and [CUSTOM_HARNESSES.md](./CUSTOM_HARNESSES.md) — native harness behavior, compatibility, and custom profile contracts.
- [design-system/DESIGN_SYSTEM.md](./design-system/DESIGN_SYSTEM.md) — Remote UI design tokens, components, accessibility, and migration rules.
- [WEB_PUSH_BEHAVIOR.md](./WEB_PUSH_BEHAVIOR.md) — current browser push grouping, silent-notification, and PWA badge behavior.
- [SCHEDULED_RUNS.md](./SCHEDULED_RUNS.md) — scheduled-run configuration, daemon behavior, command targets, and runtime semantics.
- [USAGE_METRICS.md](./USAGE_METRICS.md) — normalized run/native-session schema, provider cost semantics, query/backfill operations, archive behavior, and recovery.

## Key Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Conversation motion | Small native pixel SVG based on the retired FRED avatar; active-process loop and one-shot confirmed-success marker | Motion follows existing run state, retains its time across polling, and becomes static under reduced motion; see [CONVERSATION_ANIMATIONS.md](./CONVERSATION_ANIMATIONS.md) |
| TUI framework | Bubbletea + Lipgloss-compatible styling + Bubbles (Charm Ruby) | Elm Architecture fits the dashboard's event-driven model; Tycho uses native Lipgloss except on Intel macOS, where a Ruby compatibility backend avoids Go cgo callback crashes from multiple Charm native runtimes |
| Homebrew bottle platforms | Apple Silicon macOS and Linux; no Intel macOS bottle from v0.11.1 onward | v0.11.0 is the final Intel bottle. Intel users retain the source-install path, while the bottle workflow and release checks must not publish Intel artifacts or checksums |
| Default data root | `HOME/.tycho` for config, schedule prompts, runtime state, and logs | Source and packaged installs should never write runtime data into the repository or Homebrew Cellar by default |
| Config split | `HOME/.tycho/config/hq.yml` (active) + `HOME/.tycho/config/hq.archived.yml` (archived) | Archive without losing history; logs move to `HOME/.tycho/logs/projects/archived/` |
| Project lifecycle CLI | Explicit `tycho project create KEY`, plus list/show/update/archive commands with normalized human or JSON output | An explicit mutation verb prevents help text, command names, and typos from registering projects while keeping lifecycle automation clear |
| Multi-file lifecycle writes | `FileTransaction` snapshots config/state files and runs compensating log moves around project archival and session-loop creation | A failed downstream step must restore project, agent, schedule, memory, and log state instead of leaving a partially completed lifecycle operation |
| Callback-only agent archive | Archive protected `delegation_callback` queues into read-only conversation history, while rejecting ordinary and mixed pending queues | Obsolete delegated results must not trap a stopped parent, but ordinary user work must never disappear implicitly |
| External command capture | `CommandRunner` owns bounded process-group execution for harness discovery; GitHub PR diffs use the local `gh auth token` credential through direct HTTPS | One process owner preserves signal exit status for tools, while GitHub API behavior remains isolated from CLI response formats |
| Custom harness profiles | Allow a configured executable prefix only for the closed Codex, Claude, OpenCode, and Pi adapter families; use the declared adapter for every native command, parser, session, result, metric, readiness, catalog, permission, and skill path | Wrappers can replace a compatible native executable without turning Tycho into an unbounded parser/flag-template engine; existing Claude-compatible profiles remain unchanged |
| Agent transport | Codex JSON output, Claude-compatible `--output-format stream-json`, OpenCode JSON, and Pi JSONL RPC pass through `AgentStreamRecorder`, which preserves `raw.log` and projects complete semantic events immediately | One recorder gives every harness the same durable streaming path without changing native wire formats |
| Managed-agent environment boundary | Clear server-only `TYCHO_GITHUB_TOKEN` and `TYCHO_REMOTE_TOKEN` values at the harness spawn boundary; delegation uses an explicit trusted parent key instead of an injected capability | A daemon may load server credentials from `.env`, but managed harnesses must not inherit those bearer credentials |
| Agent model controls | Optional per-agent `model` and `reasoning_effort`, inherited from project/template config and passed as harness run arguments | Model catalogs change outside Tycho; use harness discovery for suggestions where available, keep free-form fallback everywhere, and keep provider-specific thinking budgets out of first-version scope |
| Managed-agent identity | Generate keys as `<project>-agent-<UTC timestamp with microseconds>`, adding a short random suffix only on an exact collision; retain legacy numeric keys when loading existing state | Timestamp identities remain sortable and avoid key reuse when agents are created concurrently or archived across Tycho instances |
| Managed-agent CLI delegation | `--parent-agent KEY` explicitly declares delegated ownership locally and remotely; omitting it creates a root or takes over an existing child, while `--root` is an explicit unrelated-root marker | The same visible command semantics apply across custom and resumed harnesses without secret capability propagation |
| Delegation ownership | Persist `parent`/`user` ownership and a monotonic generation on each relationship; stamp delegated runs and report only matching parent-owned generations | Direct user takeover must suppress stale callbacks immediately, while a later parent prompt can reclaim only that edge without results crossing ownership boundaries |
| Cross-harness response style | Append the current `HOME/.tycho/config/response_style.md` policy to every cold and resumed run, with project/template override or opt-out; record the harness `session_id` on each run | Keep operator-facing prose consistent without coupling the policy to a harness-native role API or persisting it into conversation memory, while retaining the native session identity used for each run; explicit task formats remain higher priority |
| Agent session strategy | Persist native Claude/Codex/OpenCode/Pi `session_id` per managed agent and resume after the first run; recover legacy run-level identity and keep `memory.jsonl` as HQ's canonical transcript | Native resume recovers agent-side continuity and prompt-cache reuse. HQ only replays bounded `memory.jsonl` on first run or when no native session is known |
| Managed-agent store recovery | Validate every save, reject unapproved reductions that remove at least five records and at least half of all active records, retain a private session/archival recovery ledger, and create checksum-verified atomic daily snapshots with configurable 30-day default retention | Lost session IDs self-heal from run history or last-known state; archived-key resurrection and accidental whole-store replacement are rejected; explicit batch archive and validated restore retain supported escape hatches with transactional safety artifacts |
| Structured output correction | Give Codex and Claude-compatible runs native schema enforcement; give cold OpenCode and Pi runs the canonical schema as hidden execution-only guidance; validate every result and allow Codex, Claude, and Pi two same-session corrections by default (`TYCHO_STRUCTURED_OUTPUT_CORRECTION_LIMIT`, clamped to `0..5`) | One contract prevents harness drift; invalid JSON must not become a successful result; Pi can correct in its native session without rerunning completed tools even though it lacks a schema flag |
| Agent log layout | New agents use a per-agent stem `<project-key>-<created-at>-<nonce>` for `.raw.log`, `.conversation.log`, `.system.log`, `.memory.jsonl`, `.attachments.json`, `.status`, `.last_message.json`, and owner-readable `.invalid_structured_output.json` diagnostics when validation retries are exhausted; `memory.jsonl` records receive an agent-wide sequence and durable event identity; legacy records are sequenced on the next append | Raw firehose + one ordered semantic journal + durable artifact links and invalid-response diagnosis without collisions when agent keys are reused after Remote/TUI archive timing differences |
| Chat viewport rendering | Project complete harness events into `memory.jsonl` while the run is live and render by durable sequence; retain `raw.log` parsing only as legacy/recovery fallback | Assistant, delegation, callback, user, tool, and summary events share one cross-process order instead of batching assistant turns at finalization |
| Agent chat conversation blocks | Conversation renders selectable blocks for user messages, agent messages, system events, and collapsed tool-call groups; Enter opens the selected block in a floating scrollable detail layer | Keeps normal chat scanning compact while preserving full tool/message detail on demand |
| Agent attachments | Structured agent results can include PR/document/image attachments, persisted in `.attachments.json` and mirrored into `memory.jsonl`, surfaced from chat with a `ctrl+a` navigable list | Durable links to artifacts survive later runs and memory rebuilds instead of living only in a single assistant message |
| Summary attachment workspace | At viewport widths of 1760 px or more, a separate Preview button opens a third independently scrolling pane beside Conversation and Summary; narrower screens use the existing attachment detail route | Minimum pane widths of 380/440/440 px keep content readable. Agent/run changes clear selection, and previews reuse authenticated attachment endpoints and the existing sandboxed renderers. External links use an explicit new-tab fallback. |
| Remote artifact rendering | Render attached HTML in an origin-isolated iframe with a restrictive content policy and package explicitly referenced, allowlisted workspace web assets; keep sanitized Mermaid fences as code on every Markdown surface and toggle each block between `Preview chart` and `Show code` through a DOM-local action menu, using a pinned Mermaid 12.2.0 conditional CDN loader in strict mode with the dark Redux colour theme, Neo look, and ELK state layout to render only that block | Interactive lessons and shared course assets remain usable without granting generated HTML access to Tycho or browser storage, while Mermaid work happens only for the chart the operator chooses and preview state remains reversible |
| Pull request diffs | Agent-scoped PR diff inspection remains available through an authenticated `gh` CLI; manual membership and removal tombstones are revision-guarded | Keep GitHub fetching read-only. Detaching a PR must preserve source attachments and shared immutable snapshots. |
| Agent pull request catalog | Persist canonical PR references and origin title/status metadata in an agent-owned `<agent-stem>.pull_request_catalog.json` sidecar; keep ordinary agent PR listing network-free | Opening one agent reads only that agent's catalog; displayed titles and Open/Draft/Closed/Merged state come from cached GitHub metadata, refreshes remain explicit, and archiving moves the catalog with the agent |
| Agent pull request switching | Paint the route shell before asynchronously attaching its diff, give foreground navigation a reserved request slot, cancel stale background work outside the open PR route, preload at most six saved snapshots, retain at most twelve payloads plus six visited viewers and per-PR scroll positions, and render lines in 100-line containment chunks | Persistent snapshots remain authoritative; navigation never shares a frame with diff layout, while immutable parsed-store reuse and bounded browser caches preserve each PR's form, selection, and desktop/mobile scroll state |
| Managed-agent completion status | Let a validated structured result define Success, Partial, or Failed after a run; retain the process exit code as transport diagnostics | A usable structured result must not remain labeled Failed solely because its harness process exited nonzero, while missing or explicitly failed results still surface failure |
| Conversation block scrolling | Initial chat load bottom-aligns the latest block when it fits, oversized blocks start at row 1, and navigation scrolls only enough to reveal the selected block | The selected label/cursor must remain visible and predictable while keeping surrounding recent context on first open |
| Conversation viewport offsets | Block `line_offset` / `line_height` are derived from the final rendered rows; long unbroken preview tokens are hard-wrapped before entering the viewport, and footer debug is computed after viewport sync | Bubbles `Viewport` counts newline-separated lines, while terminals visually wrap long tokens; stale or mismatched offsets cause misleading `visible 0/0` debug and cropped selected blocks |
| Inquiry submission | Gated review step inside a rounded box | Prevents accidental structured submissions |
| Inquiry suspension | Record dismiss, restore, and ordinary-prompt retirement as inquiry-ID-scoped events in the canonical agent journal; keep active and restorable inquiries as prompt-queue blockers. Dismiss/restore use read-only references and primary-only, retired-ledger-filtered records under the store lock, without rebuilding conversation in the response | Dismissal remains durable across clients without polling or rewriting the fleet on a stale cache; archived backups cannot recreate live memory. Stale clients cannot transition a different inquiry, and only the ordinary composer that rendered the suspended inquiry may retire it |
| Queue ingestion with direct input | Atomically claim due QueueWork when an inquiry answer or ordinary prompt is accepted, append one structured Read queue block after the direct message, and deliver both in the same native run | Pending delegated replies and user queue entries inform the answer immediately without a second run; concurrent arrivals remain queued, while canonical IDs, sources, attachments, targets, and dispositions stay available without raw-contract duplication |
| Input handling | `BubbleteaInput` patches `Bubbletea::Program#poll_event` with a Ruby-side queue | Fixes multi-byte / bracketed paste truncation in Bubbles `TextInput`/`TextArea` |
| Logging | Centralized `HQ.logger` (stdlib `Logger`), daily rotation, 7-day retention | Single sink for lifecycle, config, process, and silently-rescued errors |
| Skill discovery | Resolve the configured harness key through its native adapter, then enumerate that adapter's Codex, Claude, OpenCode, Pi, or agy skill roots | Per-agent trigger character and roots stay protocol-correct for built-ins and custom profiles |
| Tycho skill installation | Keep a checksummed bundled source manifest behind `SkillInstaller`; install to `HOME/.agents/skills` (Codex), `HOME/.claude/skills` (Claude Code), `HOME/.config/opencode/skills` (OpenCode), `HOME/.pi/agent/skills` (Pi), or `HOME/.gemini/config/skills` (agy), and update only files proven Tycho-owned | One deep module owns current path conventions, status comparison, staged/atomic replacement, exact change reporting, and collision/error safety for Remote API/UI callers |
| Agent auto-name | The first launch requests an optional `agent_title_suggestion`. A valid terminal result can replace a title only while it exactly matches the stored default-name provenance, on any run. Once a suggestion or manual rename gives the agent a custom title, later suggestions do nothing. Legacy records without provenance and clones keep their names. Manual renames invalidate pending suggestions, including rename-and-restore. Each run processes its title at most once, including after reload and summary rebuilds. Quick Agent keeps the current project name visible as read-only text; a separate editable Project selector and optional Name stay inside initially collapsed Options. Selection changes update the summary and create target together. Alphabetical project choices use a stable key tie-break. A server-owned `quick_agent.default_project_key` preference in `hq.yml` governs global launches on that host, with explicit scoped/manual choices taking priority and a valid available-project fallback. The modal backdrop uses a darker translucent fill without blur. Codex receives a required-nullable schema copy while canonical validation still accepts omitted titles. | Reduces form input while preserving user names and making title handling durable across reloads and summary rebuilds |
| Remote Sessions | Local JSON API and web UI via `tycho serve`; Tailscale auto-bind; terminal QR startup URL | Remote clients can inspect and control managed agents through the same `AgentStore` / `ManagedAgent` paths as the TUI |
| Homebrew update lifecycle | A successful Homebrew update resolves the stable `.../bin/tycho` launcher, restarts any running scheduler with that launcher, and asks a running local Remote server to self-replace through its authenticated restart endpoint; absent local services are reported as no-ops | Homebrew Cellar paths are versioned and may disappear during upgrade, so replacement server and daemon processes must never inherit the old Cellar executable; server lifecycle remains local rather than broker-proxied |
| Peer Homebrew updates | Publish a peer's Homebrew-only update capability in its compact resource snapshot and expose one dedicated, explicitly confirmed broker update action | The generic multiserver proxy remains limited to agent/project/attachment resources; unsupported, offline, and source-installed peers never receive an enabled update control |
| Distribution compiler | Keep bottled Homebrew releases; do not port Tycho to Spinel | Spinel cannot load Tycho's CRuby/Go native extensions or ordinary Bundler graph, and the feasibility compile produced no Tycho artifact; a direct-download path must preserve CRuby behavior and prove the full platform/runtime matrix |
| Remote UI responsive shell | Mobile keeps bottom navigation; wide desktop uses a wider content frame with side navigation; creation actions live in the header and focused detail/form routes remove unrelated global actions | Prevent fixed controls from obscuring content, use desktop space effectively, and keep page actions contextual across mobile, tablet, and desktop |
| Remote UI control sizing | Shared 44 px control and touch-target tokens, 16 px mobile form text, visible focus states, and explicit validation/status text | Avoid mobile auto-zoom, undersized targets, color-only state, and inconsistent action geometry |
| Remote UI design system | Keep a no-build internal system: semantic `--ds-*` tokens and reusable CSS components in `design_system.css`, product composition in `app.css`, and a static `/design-system` preview; migrate routes incrementally | Match the existing Ruby/vanilla-JS deployment, preserve behavior, make foundations governable, and avoid a framework or package rewrite |
| Remote UI deployment coherence | Snapshot all browser assets and their shared hash when `tycho serve` starts; require a daemon restart to load source updates | Prevent an old Ruby API from serving a newer on-disk JavaScript client after a pull, which can break push subscription renewal and other cross-boundary flows |
| Remote UI agent activity | Keep a server-owned in-memory activity snapshot updated by lifecycle mutations and the existing notification reconciliation pass; poll its compact read-only endpoint independently from page refreshes | Logo unread counts and agent switching stay current while forms pause page polling, without adding another server loop or letting slower catalog responses overwrite newer activity |
| Notification click diagnostics | Keep a bounded, origin-local trace for debugger records, with the executing worker build, route/load results, and export after navigation | Distinguish provider acceptance, handled click, page boot, and loaded Conversation without storing message text or subscription capabilities; native fault attribution remains unproved |
| Durable push targets | Persist notification target, read, and recovery metadata; route clicks through `/#notification/{id}` before opening an active or archived agent | Queue failures stay actionable after archive, missing targets get a useful fallback, and repeated polls cannot recreate one failure alert |
| Remote UI performance profiling | Keep an opt-in, deterministic Chrome profiler outside normal CI; use cached aggregate peer activity, a lightweight setup summary on ordinary routes, and archive-local revisions/lookups | Unavailable peers and cold harness discovery must not block local page navigation, while maintainers retain repeatable route, trace, DOM, heap, and long-task measurements |
| Interaction Profiler | Use optional JSON action scenarios and HTML timing/screenshot reports when adding or changing interactions; keep feature profiles and the Chrome smoke check outside normal CI and required signoff | Feature reviews can retain repeatable interaction evidence without adding a compulsory browser profiling gate; see the [process guide](REMOTE_UI_INTERACTION_PROFILER.md) |
| Remote UI linked-agent navigation | Expose direct parent/child links beside composer attachments and mark linked sessions in the quick agent switcher; clicking the link symbol or pressing Tab drills into the selected agent's direct links | Delegation topology stays reachable after the conversation's relationship card scrolls out of view without adding another route or duplicating relationship state |
| QueueWork lifecycle | Move each receiver-owned pending queue into one durable internal batch under the agent-store lock; preserve canonical FIFO entries, attachments, and newest-entry ownership stamp while projecting user instructions before structured delegated reports. Reading removes entries from the pending queue and records an idempotent Conversation block. The visible pending-queue projection hides only claimed entries while its agent is running, then resurfaces unresolved entries for failed, blocked, input-required, and stopped results with the real agent-state explanation; the durable batch and `Read queue` record remain intact throughout. Operators can process all or stable-ID selections in FIFO order, or confirm count-aware removal that records source-appropriate audited dispositions. Every mutation requires an exact queue snapshot and returns a stale no-op after concurrent changes. A successful, no-action-needed, or partial processing run auto-records source-appropriate default outcomes (`completed`/`incorporated`); `partial` remains the truthful result label but has the same work-release behavior as success. Explicit dispositions retain needs-input and reasoned alternatives. Undelivered work remains gated and receives one bounded same-session continuation. Right-aligned `Read queue` Conversation disclosures default to a compact instruction snippet and open/resolved state, then expose canonical FIFO details, attachments, sources, and dispositions when expanded. | Processed work clears without manual cleanup, active work is not duplicated or resurrected by polling, mixed user/delegated work retains durable evidence, new arrivals stay isolated, concurrent readers and controls cannot target the wrong entries, and non-consuming runs cannot silently retire work. |
| Queue auto-dispatch | After a process exits or Stop terminates it, atomically claim all due entries into one canonical QueueWork batch and start only an eligible agent; durably record the prior eligible terminal delegation report at the shared start boundary before replacing its run; retain queues for archived or blocked agents, active/restorable inquiries, paused/stopped schedules, dispatch failures, and workspace contention | Pending work must not depend on another manual retry or polling race, while the store lock and existing claim record prevent overlapping stop/status/callback paths from starting duplicate runs. |
| Remote attachment reads | Resolve visible active attachment owners from the committed agent snapshot without lifecycle maintenance; read source files for each accepted request and retain preview limits and MIME checks | Attachment previews and downloads do not wait for the global lifecycle lock; file changes remain visible on refresh |
| Remote multiserver resources | Keep one UI-serving broker, aggregate only compact Agent and Project resources through a disk-backed stale-while-revalidate catalog, and require explicit server identity for details and mutations | Combined lists stay responsive across peer failures and broker restarts; only a validated full snapshot may remove cached resources, while schedules, setup, GitHub, push, restart, and other server-level behavior remain local |
| Project workspace browsing | Keep canonical path resolution, sensitive/generated-file policy, bounded listing, Markdown/image previews, and optimistic-lock plain-text edits in `ProjectWorkspace`; expose only relative paths through project-scoped endpoints | Remote and multiserver browsing must not leak host paths or let client routing bypass traversal, symlink, VCS, credential, binary, encoding, or size controls |
| Remote credential ownership | Bind one bearer credential to each stable remote server key and verified scheme/host/effective-port origin; keep Tycho-managed values in atomic mode-`0600` `HOME/.tycho/config/remote_credentials.json`, with explicit per-server `token_env` overrides | CLI and broker share one resolver, multiple peers cannot select credentials by incidental names, origin changes require explicit recovery, and browser promotion removes its copy only after verified persistence |
| Scheduled runs | Dedicated `tycho schedule daemon`, definitions in `HOME/.tycho/config/schedules.yml`, runtime state in `HOME/.tycho/logs/schedules.json`, validated standard cron syntax | Scheduled work should continue independently from the TUI and Remote UI while still reusing existing agent execution paths |
| Temporary session loops | Remote UI can adopt an idle conversation as a normal recurring schedule, run it immediately with schedule context, and stop it at a configured cutoff | Review-waiting sessions need lightweight polling without losing their existing context or creating a separate agent |
| Run cost provenance | Persist harness and model on each managed-agent run; raw-log cost rebuilds use that per-run metadata and leave legacy runs unpriced when provenance is missing | Historical estimates must not silently apply the agent's current model price to older runs |
| Usage metrics | Persist idempotent v1 run records and provider-scoped native-session aggregates in one atomic, locked store; normalize Codex cumulative counters and version-aware Claude run cost/modelUsage telemetry; query active and archived history through the same CLI/API module | Historical reporting must remain auditable without raw-log joins, guessed prices/models/session IDs, or conflating runs, native sessions, and managed agents |
| Context pressure | Warn only from a harness-reported active-context window, compaction, or overflow; label measured, reported, stale, and unknown evidence; keep cumulative usage metrics separate; compaction replacements save the successor, start a handoff successor when requested, then archive the source; serialize schedule state before managed-agent state while atomically moving a scheduled source's runtime, configured target, recurring system context, memory, and PR catalog to its context-pressure replacement | Operators need an actionable quality warning without false precision, while concurrent scheduler saves, queued work, inquiries, schedule status and future dispatch, delegation, PR links, rollback, and audit history must survive any context recovery choice |
| Schedule daemon freshness | `tycho schedule daemon` writes heartbeat state to `HOME/.tycho/logs/scheduler_daemon.json`; UI surfaces derive running/stale/stopped from heartbeat age and process liveness, and report untracked running daemons without heartbeat state | Users need to know whether cron work is actually ticking, not only whether definitions are valid |
| Schedule command scope | Agent-only schedules; each schedule owns one persistent managed agent session and accepts only inline messages or files under `schedules/` | Preserve recurring context without adding arbitrary shell execution or loose existing-agent targets |
| Schedule statuses | Schedules expose `scheduled`, `paused`, or `stopped`; last outcome and error reason are tracked separately. `no_action_needed` is reserved for observational checks where no action was necessary, while completed actions and deliverables use `success` | Keep healthy no-op checks quiet without hiding meaningful completed work from unread state and notifications |
| Schedule interactive protection | A due run stops with reason `interactive` when the schedule-owned agent has later user messages; resuming records an acknowledgement boundary and keeps the same session | User conversations in scheduled sessions must not be overwritten by the next cron tick, and recovery should be one explicit action |
| Schedule management | Expose schedule list/detail/run/pause/resume/reload in both TUI and Remote UI | Interfaces should manage and observe schedules, but the daemon owns ticking, locks, missed-run policy, and dispatch |
| Open-source license | MIT | Keep adoption simple while making contribution and reuse terms explicit |
| Pull-request test attestation | Enforced GitHub `signoff` ruleset requiring `signoff/tycho-bin-test`, posted locally with pinned `basecamp/gh-signoff` v0.4.1 after `bin/test` passes on the pushed head | Keep test execution local while retaining a branch-protected, commit-specific merge gate; document repeatable success, failure, and cross-clone attestation workflows |

## Current Focus

**v0.15.0 release preparation**: a minor release for native stdin prompt
transport, custom transport contracts, experimental agy support, message and
inquiry recovery, faster Remote reads, Nord Light appearance, attachment
filters, and delegated Summary actions. Pi now targets the 0.84.4 RPC contract;
custom wrappers must preserve the selected input protocol. The release-prep
PR updates version, changelog, release notes, and upgrade guidance. Operator
merge, tag, GitHub release, Homebrew, and website delivery remain pending.
Website work starts in the registered `tycho-site` project after merge and the
exact tag exists. See [v0.15.0 notes](releases/v0.15.0.md).

**v0.14.1 release preparation**: a patch release for delegation-grouped Agents,
harness marks, cached Remote reads, optimistic archive, Quick Agent naming, and
the Ruby 4.0.9 floor. The floor and the new `jwt` direct dependency are
compatibility changes that the release notes call out. Website delivery and
Homebrew publication remain separate gates after the exact tag exists.

**v0.14.0 release preparation**: improves context replacement and schedule
continuity, safe archive, Read queue evidence, inquiry drafts, attachment review,
Conversation spacing and FRED states, mobile Settings, retained notification
routing and diagnostics, runner isolation, and GPT-6 usage estimates. Merged
harness catalog CLI PR 245 is integrated: `tycho harness list` is local only,
offline by default, and supports exact filters, JSON, and optional discovery
that may contact providers. Catalog sources and unknown defaults stay explicit;
harness effort suggestions are not proof of model support. Packaged skills remain
unchanged from v0.13.0. The release workflow now requires separate website delivery
and production verification after the exact published tag exists. The website is
on hold until v0.14.0 is published. Independent review of the integrated head and
operator approval remain required before publication.

**v0.13.0 release preparation**: adds safe context-pressure guidance, blocked
queue controls, failed-batch recovery, Partial QueueWork settlement, recurring
schedule continuation after Partial, stale Ruby-path recovery, and manual
pull-request diff catalog management. It also improves Remote UI performance,
Summary and Conversation rendering, attachment download names, durable failure
notifications, and custom Codex cost attribution. No manual data migration is
required; installed Tycho-owned skills must be updated after upgrade.

**v0.12.1 release**: improves rollout visibility by refreshing stale Summary
workspaces in place and showing active QueueWork only in its canonical **Read
queue** disclosure. It also compacts Claude image tool results before memory
projection, preserves harness exit status through finalization, and raises the
per-file attachment and workspace image-preview limit to 20 MB.

**v0.12.0 release preparation**: consolidates durable QueueWork batching,
structured Read queue disclosures, same-run inquiry/prompt ingestion, automatic
successful settlement, stop-time dispatch, delayed continuations, sleep-loop
protection, and managed-agent store recovery. It also removes the retired
experimental assistant surface, windows long Conversation histories, and moves
the merge gate from hosted CI to exact-head local signoff.

**v0.11.1 release preparation**: adds a capability-gated, explicitly confirmed
Remote UI update action for configured Homebrew peers. The action waits for the
peer restart, refreshes its resources, restores polling after failure, and
does not expose source-installed or unknown peers as updateable.

**v0.11.0 release preparation**: adds native-adapter custom harness profiles,
safer editable/searchable workspace
files, lifecycle update controls, explicit project creation, and batched,
operator-quiet delegated callbacks. Upgrade guidance records the intentional
project-command break and bundled-skill update.

**v0.10.2 release**: successful managed runs can now persist validated Second
Brain memory handoffs and expose them through local or remote CLI and API
feeds. Pi is a first-class managed harness with native session resume,
structured result correction, setup discovery, usage metrics, skills, and UI
support. Structured results can also render ordered prose, links, and
attachments beneath the concise run summary. Operators can dismiss and restore
inquiries without rewriting conversation history, while the Remote UI adds a
branded, retryable startup shell for browser and installed-PWA launches. The
release also corrects run finalization races, running-agent empty summaries,
and queued-run push notification behavior. Schedule-management work remains on
`wip/tui-schedule-management` for a later release.

## Roadmap

> Future milestones are directional, not commitments. Scope and priorities may change. Items below `Current` are candidate work surfaced from CLAUDE.md, recent commits, and research notes.

### v0.1 — Dashboard Foundation ✓

- [x] Bubbletea/Lipgloss/Bubbles TUI scaffold (`hq.rb` + `lib/hq/app.rb`)
- [x] Project registry from `HOME/.tycho/config/hq.yml` (`lib/hq/registry.rb`)
- [x] Concurrent project metadata refresh
- [x] Managed-agent persistence and restoration via `HOME/.tycho/logs/managed_agents.json`
- [x] In-app sidebar log viewer; `g` shortcut to open project terminal

### v0.2 — Managed Agents ✓

- [x] Codex / Claude-compatible execution paths
- [x] `AgentLogParser` for JSON / stream-json demultiplexing
- [x] Per-agent log artifacts: `raw.log`, `conversation.log`, `system.log`, `memory.jsonl`
- [x] Agent create/edit forms loaded from `HOME/.tycho/config/system_prompts.yml`
- [x] Structured inquiry form with gated review submission
- [x] Multi-select inquiry support; expandable wrapped inquiry text fields

### v0.3 — Chat & Memory ✓

- [x] Incremental chat viewport: complete harness events enter sequenced `memory.jsonl` during the run
- [x] `AgentMemory` canonical event journal with durable sequence, identity, and bounded replay
- [x] `capture_run_memory!` reconciliation and idempotent run summary on completion
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
- [x] Per-project log organization under `HOME/.tycho/logs/projects/{project}/`
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
- [x] Add Pi Coding Agent 0.73.1 command, JSON event, session, catalog,
      authentication, skill, structured-result, safety-gap, and usage support
- [x] Bound harness catalog probes and normalize OpenCode catalog output
- [x] Document the Homebrew bottle `pr-pull` publishing workflow

### v0.9 — Multiserver and Review Workflows ✓

- [x] Add persistent multiserver Agent and Project catalogs in Remote UI
- [x] Persist last-good peer snapshots across broker restarts and failed refreshes
- [x] Route peer Agent and Project details and mutations through explicit server keys
- [x] Add direct `--server` CLI control for remote project reads and managed-agent lifecycles
- [x] Show peer health, token state, and Tycho version compatibility in Settings
- [x] Store immutable agent pull request diff snapshots
- [x] Promote Remote UI design-system contracts across forms, menus, badges,
      confirmations, detail headers, and empty states

### v0.10 — Agent Operations and Observability ✓

- [x] Add remote project and managed-agent CLI operations with private,
      server-bound credential management
- [x] Validate structured output and request bounded same-session corrections
- [x] Add normalized run/native-session usage metrics and historical backfill
- [x] Add safe Remote UI workspace browsing and Tycho skill installation
- [x] Add selected PR diff context and persistent agent PR catalogs
- [x] Add durable managed-agent delegation and terminal parent callbacks
- [x] Keep agent activity live during focused Remote UI workflows
- [x] Add verified provenance and ancestor-operation rejection for delegated agents
- [x] Add persistent, multi-client prompt queueing for running agents
- [x] Reconcile resolved failed queue claims, keep failed batches inspectable, and provide source-safe retry/discard recovery
- [x] Add durable delayed agent messages with due-aware FIFO batching, restart-safe dispatch, and local/remote CLI parity
- [x] Add a structured sleep circuit breaker with process-tree termination, dedicated stop rendering, and cancellable one-shot recovery

## Features Candidates

### Release Hardening

- [ ] Formalize specs
- [x] Stabilize source packaging and pre-release browser/TUI checks
- [x] Publish and verify the 0.9.0 Homebrew bottles

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

- [x] Add Codex catalog-driven model and effort suggestions from `codex debug models`
- [x] Add Claude alias/help-derived suggestions without hard validation
- [x] Add config inheritance and persisted `ManagedAgent` fields for `model` and `reasoning_effort`
- [x] Add dirty-field-aware dynamic model/effort suggestions when harness, template, or model selection changes
- [x] Pass model and effort through Codex, Claude, and Claude-compatible command builders
- [x] Display and edit model and effort in the TUI and Remote UI

### Scheduled Runs

- [x] Decide scheduler owner: dedicated `tycho schedule daemon`
- [x] Decide config source: `HOME/.tycho/config/schedules.yml` with cron syntax validation
- [x] Decide management surfaces: TUI and Remote UI
- [x] Decide command scope: persistent schedule-owned agent only; no shell, templates, loose existing-agent targets, or clones
- [x] Decide prompt sources: inline text or files under `schedules/`
- [x] Decide failure/success notifications: stop and web-push on failure; notify only first success and first success after failure
- [x] Add `ScheduleRegistry` / `ScheduleStore` and persisted runtime state in `HOME/.tycho/logs/schedules.json`
- [x] Persist scheduler daemon heartbeat state in `HOME/.tycho/logs/scheduler_daemon.json`
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
- [x] Protect native session identity with regression detection, daily rolling backups, and validated CLI restore
- [x] Pass `--resume <session-id>` (or `--session-id <uuid>` on first run) to recover native prompt-cache reuse
- [x] Decide replay-vs-resume policy: HQ-side `memory.jsonl` replay vs. native session resume per agent type
- [x] Document tradeoffs in CLAUDE.md and update agent prompt budgeting
- [x] Ability to switch Chat to Interactive Mode (resume in agent harness, e.g. codex, claude) via `ctrl+t` agent terminal shortcut
- [x] Validate structured output and request bounded same-session corrections across Codex and Claude-compatible harnesses

### Managed-agent communication

- [x] Use direct CLI invocation and explicit same-server parent delegation; see [AGENT_DELEGATION.md](./AGENT_DELEGATION.md) for the maintained contract.

### Observability

- [x] Structured run/native-session usage, cost, timing, completeness, and lifecycle metrics
- [ ] In-app log filter / search for `HOME/.tycho/logs/hq.log`
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
- [x] Read agent conversation (`GET /agents/{key}/conversation`) <!-- local-path-ok -->
- [x] Submit prompt to agent (`POST /agents/{key}/messages`) <!-- local-path-ok -->
- [x] Start / Stop an agent (`POST /agents/{key}/start`, `POST /agents/{key}/stop`) <!-- local-path-ok -->
- [x] Creates / Edit an agent (`POST /agents`, `PATCH /agents/{key}`) <!-- local-path-ok -->
- [x] Archive one agent (`DELETE /agents/{key}` or `POST /agents/{key}/archive`) or bulk archive idle agents (`POST /agents/archive`) <!-- local-path-ok -->
- [x] Discover read-only archived agents through paginated API and CLI filters; keep Remote UI archives reference-only and outside the unbounded Agents browser
- [x] Project list/detail endpoints and mobile project detail screens
- [x] Remote setup/readiness endpoint and Settings screen
- [x] Remote Settings editor for the global `response_style.md` policy with atomic persistence and backup
- [x] Client-side Remote UI filtering across agents and projects
- [x] Remote UI skill discovery for chat insertion
- [x] Browser push subscription/test-notification foundation, with HTTPS MagicDNS support and HTTP MagicDNS warnings
- [x] Automatic browser push notifications when agents require response or finish
- [x] Dedicated mobile structured inquiry submission UI
- [x] Full-screen inquiry editor with trailing unstructured Leave feedback field
- [x] Poll-safe inline and full-screen Conversation/inquiry forms that remain attached and focused during shell refreshes
- [x] Focused Summary, Attachment, PR Diff, and agent-backed project Diff routes show that conversation polling is paused, poll only the lightweight resource catalog, preserve their workspace DOM, and reconcile status/lifecycle controls in place; normal route polling resumes on Conversation and top-level live views
- [x] Keep logo unread counts and agent switching live through a compact activity snapshot and independent client poll, including while full-screen forms pause page refreshes
- [x] Attachment detail context menus with exclusive Balanced/Widen/Full layouts, content/path copy, and forced cache refresh
- [x] Responsive desktop/mobile shell with persistent, header-aligned in-shell desktop navigation across top-level and detail routes, consistently named New agent action, shared control sizing, and fixed-region safe-area handling
- [x] Sticky Settings section navigator over one continuous page and copyable native session ID in Conversation Settings
- [x] Bounded mobile Settings scrolling above persistent navigation, consistent section headings, compact healthy readiness checks, and grouped connection facts with visible warnings
- [x] In-flow desktop conversation composer with resize-aware mobile content reservation
- [x] Accessible full-screen Conversation editor with polling-safe autosaved drafts, focus containment, mobile visual-viewport sizing, and Escape-to-exit
- [x] Focused Summary/Attachment full-view controls and compact mobile follow-up composer
- [x] Version-aware Claude resumed-session totals and per-run Summary estimates; saved historical estimates remain unchanged. See [Claude run cost](./research/claude-run-cost.md).
- [x] Finalized-run estimated session-cost snapshots on latest and historical Summary pages, including Codex token-delta estimates from an auditable OpenAI model rate card, explicit rebuild backfill, and no startup log scan
- [ ] Dedicated mobile activity/log detail page
- [x] Full mobile agent create/edit form
- [x] First-class run/native-session usage metrics, idempotent historical backfill, archive manifests, and CLI/Remote API reporting

## Known Issues

Documented in [GOTCHAS.md](./GOTCHAS.md)

### Schedule archive

- Replaced schedules can be archived with configuration and run history intact.
  Archive refuses running targets, hides schedules from default lists, and blocks
  automatic and manual schedule execution. See [Scheduled runs](SCHEDULED_RUNS.md#archive-replaced-schedules).
- Production schedule retirement remains a separate operator action after merge.
