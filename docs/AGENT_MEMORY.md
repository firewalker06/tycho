# Agent Memory & Conversation Persistence

How HQ stores managed-agent transcripts, what each store is responsible
for, and what gets sent to Claude/Codex on the next run.

## The Stores

For an agent with key `<key>`:

| Store | Path | Written by | Read by |
|---|---|---|---|
| **Raw log** | `~/.tycho/logs/agents/<project-key>-<created-at>-<nonce>.raw.log` for new agents; legacy agents may still use `<key>.raw.log` | `AgentStreamRecorder` tees unchanged harness stdout/stderr after the run marker | Recovery, diagnostics, and `AgentChatLog#rebuild_memory_from_raw_log!` |
| **Memory** | Same stem as the raw log, with `.memory.jsonl` | `AgentEventJournal` for harness, user, delegation, callback, attachment, and run events | The chat viewport, prompt composition, and finalization reconciliation |
| **Attachments** | Same stem as the raw log, with `.attachments.json` | `ManagedAgent#capture_run_memory!` when structured output includes attachments | The chat attachment summary and floating `ctrl+a` panel |
| **Conversation/system snapshots** | Same stem as the raw log, with `.conversation.log` and `.system.log` | `AgentChatLog#ensure_generated` | External tools / human inspection only |

`raw.log` is the firehose. `memory.jsonl` is the canonical transcript and
the only source of truth for both the chat viewport and prompt
composition. Attachments are durable sidecar metadata in
`attachments.json` and are mirrored into `memory.jsonl` so memory rebuilds
can restore attachment events without dropping saved artifact links.
New filenames include the project key, creation timestamp, and a nonce so a
reused key cannot accidentally point at an older log lineage when the TUI and
Remote UI observe archive/delete operations at different times.
`managed_agents.json` no longer carries a `messages` field — agent state
(`session_id`, `runs`, timestamps, etc.) is persisted, but conversation
content lives entirely in `memory.jsonl`.

Each new memory record has a top-level agent-wide `sequence`, durable
`event_id`, `schema_version`, and `recorded_at`. Stream-derived events also
carry `run_id`, `occurred_at`, and source-local sequence/offset metadata. The
journal allocates sequence and appends under one exclusive lock. On the first
post-upgrade append to a legacy file, it sequences the existing prefix in file
order before storing the new event.

## Read paths in the TUI

`AgentChatLog#chat_blocks` projects `memory.jsonl` in durable sequence order.
New runs append a `run_started` event before process launch, so their live
conversation is journal-backed from the first harness event.

- `memory_chat_blocks` is authoritative for sequenced runs.
- `live_run_chat_blocks` remains only for a running legacy process that has no
  projected event for its current `run_id`.

There is a *separate* helper, `AgentChatLog#projection_entries`, that
*does* fall back to a raw-log re-parse when `memory.jsonl` is absent —
but it's only used by `chat_text` and `ensure_generated` (the static
log files), not by the viewport.

If `memory.jsonl` is missing while `raw.log` exists, the chat viewport
prompts the user with "Rebuild memory.jsonl from raw.log? (y/n)" on
open. The user can also press `R` (when the chat content area or
summary is focused) at any time to re-trigger a rebuild.

## Write path: recorder plus finalization reconciliation

The checked-in runner owns the harness pipe:

```
harness stdout/stderr ──▶ AgentStreamRecorder ──▶ raw.log (unchanged)
                                  │
                                  ▼
                         AgentStreamProjector
                                  │
                                  ▼
                         AgentEventJournal
                                  │
                                  ▼
                         sequenced memory.jsonl
```

Codex `agent_message`, Claude complete assistant content blocks, and OpenCode
text parts persist as soon as their complete line arrives. Tool and usage
entries follow the same path. Claude token deltas are not enabled.

After exit, `capture_run_memory!` replays the process-output segment through
the same projector. Deterministic IDs derived from `run_id`, harness, source
sequence, and semantic subtype make reconciliation idempotent. Finalization
then records inquiries, attachments, cost metrics, and one run summary.

The projector's compact tool summary takes the parser's `SystemEntry`,
extracts the first non-empty content line, and prepends the tool name:

- `tool_call`: `"<ToolName>: <first line>"`.
- `tool_result`: `"tool result: <first line>"`.

This is why per-tool body formatters in the parser matter: the *first
line* of the parser's tool_call body is what becomes the persisted
summary. These stored summary strings are not length-capped; if the
first line is long, `memory.jsonl` keeps it in full.

## Memory bootstrap at agent creation

`AgentStore#create_from_template` seeds `memory.jsonl` with the project
context system prompt and the template's system prompt at agent
creation time, via `memory_store.append_system_prompt!`. This makes the
canonical transcript self-contained from the very first run — no
synthetic fallback path is needed.

The `ManagedAgent` constructor's `messages:` keyword still accepts an
array of `AgentMessage` objects (used by tests), and seeds
`memory.jsonl` from those entries when the file does not yet exist.
This is a convenience for tests; production code (`AgentStore`) seeds
memory directly.

## What gets sent to Claude/Codex on the next run

Decided by `prompt_for_execution`:

```ruby
def prompt_for_execution
  return composed_prompt unless native_resume?

  # native_resume: known session_id + (claude: bootstrapped / codex: any prior run)
  threshold = last_run&.finished_at || @finished_at || @started_at
  latest = memory_store.latest_user_message_after(threshold)
  latest.to_s.strip.empty? ? "Continue from the current HQ managed-agent state." : latest.to_s
end
```

Two regimes:

### Regime A — no native session yet

`composed_prompt` joins the **entire** `memory.jsonl` transcript into
one string with `SYSTEM:` / `USER:` / `ASSISTANT:` headers. There is no
slicing — every system prompt, user message, assistant message, tool
summary, and run summary in the file is replayed.

The reasoning: when there is no `session_id` the harness has zero
server-side state, so we hand it the full local context to maximize
accuracy. Token budget grows linearly with agent age in this regime;
the expectation is that `session_id` is captured on the first run and
Regime B takes over from run 2 onward.

The command builders append that blob as the harness prompt argument: after
`--` for Codex, as the final positional argument for Claude-compatible
harnesses, and as the `opencode run` message argument for OpenCode.

### Regime B — native resume active

For Claude with a `session_id` that has been bootstrapped (or Codex
with at least one prior run + a known `thread_id`), HQ runs
`claude --resume <id>` / `codex exec resume <id>` and **sends only the
latest user message** that arrived after `last_run.finished_at`.
History, system prompt, and tool context are recovered server-side
from the harness's own session state. This avoids paying the prompt
cost twice and lets prompt-cache reuse work.

## The agent-level summary cache

`ManagedAgent` exposes `@summary` and `@structured_result` as
in-memory state. They are **not** stored on `AgentRun` (per-run
summaries are intentionally discarded), but they **are** persisted to
`managed_agents.json` at the agent level (sibling of `"key"`,
`"runs"`, etc.). The Summary pane and the agent-row "Last result"
badge read from this cache.

Persisting the cache keeps boot O(1): `AgentStore#load` deserializes
`summary` / `structured_result` directly from JSON and never touches
`raw.log`. This matters in practice — agents accumulate multi-MB
`raw.log` files, and re-parsing them all on every boot used to add a
minute or more to startup.

The cache is rebuilt by `ManagedAgent#build_summary!`, which parses
the **last** `=== […] start ===` segment of `raw.log` and extracts
the structured result via `normalize_structured_result_payload`
(handling Codex `item.completed.agent_message`, Claude
`structured_output`, and Claude prose-result fallbacks). Per-run
summaries are not stored anywhere — only the latest run's summary is
ever surfaced.

`ManagedAgent#cost_snapshot` is a separate persisted cache for the native
session's estimated cost through the latest finalized run. It is deliberately
not recomputed at boot. Finalization folds the current run's normalized usage
events into the prior snapshot, saves the latest value in
`managed_agents.json`, and copies that as-of value into the run's
`run_summary` memory metadata. Claude-compatible harnesses contribute their
reported per-run estimate, OpenCode contributes the sum of `step_finish`
costs, and Codex prices cumulative token deltas with the embedded official
OpenAI standard API rate card. Each `AgentRun` persists the harness and model
used for that run so an explicit raw-log rebuild cannot price older usage with
the agent's current model. Codex snapshots persist the selected model,
input/cached-input/output prices, source URL, and price date beside the token
counters. Unknown models and incomplete telemetry remain untracked. A running
agent continues to show the previous finalized snapshot.

`build_summary!` is invoked from two places, and each is followed by
a save so the new value reaches `managed_agents.json`:

- `finalize_latest_run!` (right after a run exits — `poll_agents!`
  saves agents on the same tick).
- `App#rebuild_memory_for_chat_agent` (after a user-triggered rebuild,
  which calls `save_agents!` explicitly).

There is no longer a `backfill_run_results!` method. Boot and the
10-second poll do not re-parse `raw.log`; the persisted cache is
authoritative until the next run finalize or manual rebuild.

## Rebuilding from `raw.log`

Two entry points, both backed by `AgentChatLog#rebuild_memory_from_raw_log!`
plus `ManagedAgent#build_summary!`:

1. **Auto-prompt on chat open** — when the user opens the chat
   viewport for an agent whose `memory.jsonl` is absent but whose
   `raw.log` exists, HQ shows a `(y/n)` confirm:
   "Rebuild conversation and summary?".
2. **`R` keybinding** — pressing `R` while the **Conversation** pane
   is focused opens the same confirm. The chat footer surfaces
   `R: rebuild` when content is focused. The conversation and summary
   can be rebuilt from scratch at any time.

Both paths perform two operations:

- **Conversation** — `AgentChatLog#rebuild_memory_from_raw_log!` walks
  every `=== […] start ===` segment of the raw log, runs
  `HQ::Parser.parse_run` with the current per-tool formatters, and
  **overwrites** `<key>.memory.jsonl` with `system_prompt`,
  `user_message`, `assistant_message`, `tool_summary`, `token_usage`,
  synthetic `run_summary` events, plus attachment events restored from
  `<key>.attachments.json`.
- **Summary** — `ManagedAgent#build_summary!` re-derives
  `@structured_result` and `@summary` from the **last** raw.log
  segment, then `save_agents!` persists the (otherwise unchanged)
  `managed_agents.json`.

Caveats:

- Run summaries inside `memory.jsonl` are synthetic
  (`(rebuilt from raw.log run #N)`); the real per-run structured
  results and prose summaries are not preserved historically — only
  the latest run's summary is recoverable, into the agent-level cache.
- The conversation rebuild overwrites the existing `memory.jsonl`.
  Attachments survive through `<key>.attachments.json`; other
  non-rebuildable memory events still need a manual backup first.
- Inquiry events inside `memory.jsonl` are not rebuilt (raw.log
  doesn't carry them separately from the assistant's structured
  output payload). However, the latest run's inquiry **does** land in
  `@structured_result["inquiry"]` via `build_summary!`, so the
  inquiry form will reappear after a rebuild if the last run was
  awaiting input.

The explicit rebuild also folds every raw-log run into cost snapshots and
stores each as-of value on its synthetic `run_summary`. This is the backfill
path for agents created before cost tracking; legacy Codex runs without
per-run model provenance remain unpriced rather than receiving the current
model's rate. Startup remains O(1).

## Second Brain handoffs

Each `AgentRun` may include a `metadata.memory_handoff` object. It stores only
the semantic handoff body: `outcome`, `decisions`, `continuing_context`, and
`references`, with optional `lessons` and `promotion_candidates`. Run ID,
status, project, timestamps, project group, and server identity remain
Tycho-owned provenance outside that object.

Tycho persists a validated handoff only when a run finalizes with structured
status `success`. Older runs and successful runs without a handoff remain
readable and are simply absent from the feed. Existing user copies of
`schemas/agent_result.json` receive the additive `memory_handoff` definition
when Tycho starts; no other schema fields are changed.

Use `bin/tycho memory handoffs --json` locally, or add `--server SERVER_KEY`
for a configured remote Tycho. Remote Sessions also exposes the same
source-shaped JSON at `GET /memory-handoffs`. The payload is intended for the
Second Brain reconciler and includes only live `Personal` and `Cookpad`
projects plus their successful persisted handoffs.

## See also

- `docs/research/tool_log_shapes.md` — per-tool raw-log JSON shapes and
  formatter design notes.
- `lib/hq/parser/claude.rb` — per-tool body formatters.
- `lib/hq/domain/agent_memory.rb` — append APIs, prompt/conversation
  message builders.
- `lib/hq/domain/agent_event_journal.rb` — locked sequence allocation,
  deduplication, legacy migration, and durable append/replace behavior.
- `lib/hq/domain/agent_stream_recorder.rb` — detached harness pipe and raw-log
  tee.
- `lib/hq/domain/agent_stream_projector.rb` — line-oriented cross-harness
  semantic projection.
- `lib/hq/domain/agent_chat_log.rb` — viewport projection, raw-log
  rebuild.
- `lib/hq/domain/managed_agent.rb` — `capture_run_memory!`,
  `compact_system_summary`, `prompt_for_execution`, `composed_prompt`.
- `test/parser_test.rb` — pins per-tool parser output.
- `test/agent_event_journal_test.rb` and `test/agent_stream_recorder_test.rb` —
  pin ordering, concurrency, deduplication, and incremental persistence.
- `test/memory_entries_test.rb` — pins finalization reconciliation output.
