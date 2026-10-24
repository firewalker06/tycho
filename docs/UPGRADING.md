# Upgrading Tycho

## Unreleased

## Current source checkout

Ruby 4.0.9 or later is required. Upgrade Ruby before running `bundle install`
or the setup script.

## 0.14.0

Upgrade through Homebrew or update the source checkout. Ruby 3.2 or later is
still required. No new gem dependency or manual conversion is required for
projects, schedules, agents, delegation, QueueWork, memory, credentials,
notification records, or attachments.

### Local model and reasoning catalogs

Use the new local catalog command without starting an agent:

```bash
tycho harness list
tycho harness list --json
tycho harness list --harness claude --model claude-opus-5-5 --json
tycho harness list --harness codex --discover --json
```

The default is offline: it uses the same built-in fallback catalogs and
`harness_catalogs` configuration as Settings, including configured custom
harnesses. It does not run tools, check authentication, or contact providers.
Both filters are exact and case-sensitive. A missing model means it is absent
from that catalog; it does not establish provider availability or lack of support.
This is a local command with no `--server` option or remote CLI forwarding.

Choose `--discover` only when you want local harness catalog commands to run.
Those commands can require installed tools and credentials, and can contact
providers or a network. Read `catalog_source` for the source or fallback used.
Discovery is not a live entitlement or model/reasoning validation guarantee.
The command adds no provider API query or authentication check of its own.

The Claude catalog includes `claude-opus-5-5`. Its `low`, `medium`, `high`,
`xhigh`, and `max` values are harness suggestions, not proven effort support for
that model. Model rows have `reasoning_scope`; only model-specific source data
produces a model `reasoning_efforts` list. Unknown defaults are JSON `null` and
text `unknown; harness decides`. Project/template overrides are not listed.
No new config or packaged skill update is required for this command.

### Context replacement and archive

**Start New** creates a fresh clone and archives its source after the clone is
saved. **Start with Handoff** saves a concise continuity record and archives the
source after its replacement starts. A recurring schedule follows the replacement
agent. Check the schedule target after replacement; do not create a second
schedule to continue the same work.

Context replacement blocks running agents, unresolved inquiries, and ordinary
or mixed queued work. Stop active work, answer or retire the inquiry, and process
or remove ordinary queue entries before you replace the source.

Manual archive has different behavior: it stops active work, cancels an unresolved
inquiry, and records final outcomes for queued work. It does not run that queued
work. Undelivered user prompts are declined with a reason; protected delegation
callbacks are superseded with a reason and kept in read-only history. Delivered
or in-flight work is marked aborted with uncertainty. Inquiry cancellation,
queue outcomes, and delivery evidence remain in the archive; Read queue evidence
remains in Conversation and memory.

### Remote UI and credentials

Inquiry values save locally while you type and survive refresh and reload.
Conversation opens at its latest message. Wide screens can show a selected
Summary attachment in a third column; smaller screens retain their normal
workspace navigation. The status marker uses reliable matching run evidence for completion
and honors the browser's reduced-motion setting.

The Remote UI serves its new fonts locally; no font service or separate package
installation is required. Mobile Settings uses its own content scroll area above
navigation. Existing browser token reads and peer forwarding remain supported.
Do not clear credentials as part of this upgrade.

Notification diagnostics are in Settings. An explicit test send targets the
current browser subscription and does not change the selected agent's state.
Provider acceptance and synthetic browser checks do not prove native OS display,
trusted notification activation, installed-PWA focus, or cold-window behavior.
Use the redacted trace to collect evidence when a native click still fails.

### Runtime and usage estimates

Internal runners no longer activate incompatible user Ruby gems. Managed
harnesses retain their supported environment. GPT-6 estimates use the embedded
rate card and cache-write accounting; estimates remain unavailable when required
rates or token counts are missing. This is a list-price estimate, not a bill.

The packaged Tycho skill is unchanged from v0.13.0 in this release range. Users
upgrading from an older release should apply that release's skill update steps.
Apple Silicon macOS and Linux bottles remain supported. Intel macOS users can
run from source; v0.11.0 is the last Intel bottle.

### Verify

```bash
tycho --version
tycho doctor
tycho agent list
tycho schedule list
```

Check that the version is `0.14.0`, existing sessions and schedules are present,
and the expected harness is ready. Open Conversation, an inquiry draft, an
attachment preview, and Settings. Check notification diagnostics with synthetic
data before you choose to send a real test notification.

## 0.13.0

Upgrade normally through Homebrew, or update a source checkout with Git and
rerun `bin/setup` when requested. No manual migration is required for projects,
schedules, agents, delegation, QueueWork, notifications, pull-request catalogs,
attachments, credentials, or memory.

### QueueWork behavior

A Partial result now settles delivered QueueWork with source-appropriate default
outcomes and releases later FIFO work. Failed, blocked, and input-required runs
still retain unresolved work. New queue controls can process stable-ID selections
or all pending entries when agent state blocks dispatch. Removal requires an
exact queue snapshot and confirmation; protected delegation callbacks cannot be
discarded.

Failed dispatch claims remain inspectable. Retry work that is still valid, or
discard an allowed failed batch with an audited reason. Existing queue and batch
records need no conversion.

A scheduled run that returns Partial now records that outcome, clears its
failure state, and stays scheduled for its next run. Partial does not use the
stopped or failure notification path.

If a Homebrew update removes the Ruby executable path held by a running Tycho
process, agent launches use the current `ruby` on `PATH`. If no replacement is
available, install or activate Ruby, restart Tycho, then retry the failed queue
batch. The failed claim remains available for inspection and safe recovery.

### Context pressure and pull-request diffs

Context-pressure warnings use only reliable active-context evidence. **Start
New** creates a fresh clone and archives the source after it is saved. **Start
with Handoff** adds a concise continuity record and archives the source after
the replacement starts. **Keep Going** acknowledges the warning, and
**Archive** retains the existing confirmation and safety checks.

Pull-request diff catalogs now support explicit add and remove actions in the
CLI and Remote UI. Removal creates a safe catalog tombstone but does not delete
source attachments or shared immutable snapshots.

### Skills and compatibility

The packaged `tycho` skill changed. In **Settings → Skills**, update each
Tycho-owned installation and restart a harness if it does not discover the new
version. The new guidance covers failed-batch discard, Partial settlement, and
context-pressure handoffs.

Existing notification ledgers, attachment records, and run summaries remain
valid. Legacy attachments use a safe download-name fallback. Missing or invalid
structured run summaries now use a bounded and redacted fallback instead of a
blank detail view.

Homebrew bottles are available for Apple Silicon macOS and Linux. v0.11.0
remains the final Intel macOS bottle; Intel users can continue from source.

### Verify

Run these checks after upgrading:

```bash
tycho --version
tycho doctor
tycho agent list
tycho schedule list
```

## 0.12.0

Upgrade normally through Homebrew, or update a source checkout with Git and
rerun `bin/setup` when requested. Existing project, schedule, managed-agent,
delegation, QueueWork, memory, and credential stores do not need a manual data
migration.

### Queued work

Tycho now claims queued user prompts and delegated reports into a durable
QueueWork batch. A due batch joins the inquiry answer or ordinary prompt that
starts the next run; successful processing records default per-entry outcomes
and clears the batch automatically. Partial runs keep their truthful result
label, but now use the same work-release behavior and default outcomes as
success. Failed, blocked, and input-required runs retain unresolved work.

Conversation shows this work as one right-aligned **Read queue** disclosure.
Its compact state contains the instruction snippet and lifecycle status; open
it to inspect canonical entry IDs, sources, attachments, targets, and outcomes.
Automation should not depend on the old raw queued-message projection.

### Delayed continuations and wait protection

Managed agents can enqueue a delayed continuation instead of keeping a run
open. Repeated blocking waits trigger a circuit breaker and a bounded recovery
entry. Existing schedules and ordinary queued prompts keep their current
configuration.

### Removed experimental surface

The retired experimental assistant UI and runtime have been removed. Legacy
agent records remain hidden and removed configuration is ignored, so no data
cleanup is required. Delete obsolete configuration when convenient.

### Skills and verification

Update each Tycho-owned installed skill from **Settings → Skills**, then restart
the harness if it does not discover the new version. After upgrading, run:

```bash
tycho --version
tycho doctor
tycho agent list
tycho schedule list
```

Homebrew bottles are available for Apple Silicon macOS and Linux. Intel macOS
remains source-only, as established in v0.11.1.

## 0.11.1

Configured Remote servers now report whether their own Tycho installation can
be updated through Homebrew. In **Settings → Servers**, the overflow menu shows
**Update Tycho** only for an online peer that reports this capability. The
action confirms the restart, keeps the browser on the UI-serving server while
the peer returns, then refreshes its catalog. Source installs and peers that do
not report support remain unchanged; use Git and `bin/setup` there.

### Intel macOS Homebrew bottles

v0.11.0 is the last Tycho Intel macOS Homebrew bottle. v0.11.1 ships no Intel
macOS bottle; Apple Silicon macOS and Linux bottles remain available. Move the
installation and its `~/.tycho` data to an Apple Silicon Mac, or run Tycho from
source. This does not change source checkout support or non-macOS environments.

## 0.11.0

Upgrade from `0.10.2` normally through Homebrew, or update a source checkout
with Git and rerun `bin/setup` when its dependency check requests it. Existing
projects, schedules, managed-agent logs, delegation ledgers, and Remote UI
settings do not require manual data migration.

### Command change

The implicit project-creation shortcut has been removed. Replace every use of:

```bash
tycho project my-project
```

with:

```bash
tycho project create my-project [options]
```

Use `tycho project show my-project` to inspect an existing project. Bare or
malformed project commands now fail without writing to `hq.yml`.

### Skills

The bundled `tycho` skill changed with this release. In **Settings → Skills**,
run the confirmed **Update** action for each Tycho-owned installation, then
restart a harness if needed. Tycho never overwrites unmarked or locally changed
skills; reconcile those copies manually. See [Tycho skills](TYCHO_SKILLS.md).

### Custom profiles

Existing `adapter: claude` custom harness entries remain supported. New custom
profiles must declare a supported native adapter (`codex`, `claude`,
`opencode`, or `pi`).

### Delegation and notifications

Tycho now batches eligible child outcomes into one deterministic callback for
the parent. A terminal child turn owned by the current parent generation does
not increment the child's operator unread count or send a child completion push;
the parent callback remains the attention path. A direct user takeover, a stale
ownership generation, or a detached legacy relationship fails open to ordinary
operator attention instead of suppressing it.

### Schedules and workspace files

Schedules can now be created and updated through the CLI and Remote UI, and can
override the project harness, model, and reasoning effort. Existing schedules
continue to use project defaults when those fields are absent. The workspace
browser adds guarded plain-text editing and file search; its containment,
sensitive-file, binary, size, VCS, and symlink restrictions still apply.

### GitHub integration

The unfinished Tycho GitHub App login and review-posting workflow was removed,
including `tycho github login`, `tycho github status`, and `tycho github logout`.
Remove any automation that invokes those commands. Agent-scoped pull-request
diffs remain available as a read-only feature and now require an authenticated
local GitHub CLI; run `gh auth login` if needed. Tycho no longer posts pull-request
reviews itself.

Inline remote-server `token` values remain temporarily supported but produce a
migration warning. Move each one into Tycho's private credential store with
`tycho server migrate <server-key>` (or `tycho server migrate --all`).

### Verify

Run these checks after upgrading:

```bash
tycho --version
tycho --help
tycho doctor
tycho project list
tycho schedule list
```

For Homebrew installs, `tycho update` performs the package upgrade and safely
restarts a running local Remote server or scheduler daemon when present.
