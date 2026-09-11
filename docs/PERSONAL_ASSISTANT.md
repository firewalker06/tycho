# FRED Personal Assistant

FRED helps you set up Tycho projects, prepare and follow agents, inspect results, and manage schedules. It is an opt-in, Codex-only conversation on the current Tycho server. Project agents still use their own harness settings.

## Getting started

Visit FRED, review the model, reasoning effort, timezone, personality, and external-event preference, then confirm setup. Visiting automatically creates or resumes the current daily session; it does not run a model. Start with a recommendation or write your own request. FRED is available before you have a project.

The setup form uses the server's Codex catalog when available. Executable readiness is not a guarantee that authentication or a particular model will work. Setup keeps a manual model fallback when discovery is unavailable.

Settings can be changed without deleting your conversation. Saved changes apply to the next daily conversation, or you can explicitly restart FRED to apply them now. Restart is an advanced lifecycle action: it archives the current idle conversation and keeps settings and continuity. Reset is separate: it deletes the active session and its logs, clears settings and active continuity, and removes pending actions. It does not erase previously archived conversations or historical handoff files.

Personality presets change stable voice and interaction principles: Balanced is clear and practical, Direct is decisive and plain-spoken, Steady is calm and grounded, and Upbeat is curious and encouraging. Existing configurations without a personality use Balanced. Presets are trusted, versioned Tycho content rather than free-form prompt text, and cannot weaken factual standards, task precision, structured output, action confirmation, safety rules, or higher-priority instructions. User response-style guidance still controls presentation where it is more specific.

## Recommendations

An empty daily conversation starts with recommendation buttons instead of a current-work dashboard or a static capability list. Selecting a recommendation only fills the normal composer; it does not send a prompt or approve a mutation.

During daily rollover, the existing summary turn produces three to five bounded recommendation prompts for the next local date. The server-side FRED agent uses its installed skills and local read-only resources to inspect available daily-journal signals and new or updated Miki knowledge, then combines them with unfinished work, useful cleanup, and FRED's documented Tycho capabilities. Unavailable sources are treated as absent rather than invented. Tycho persists one set per date in the Personal Assistant lifecycle state. A same-day restart preserves that set. First use, stale state, and failed summaries show explicit starter or fallback recommendations instead of an empty or misleading generated state.

Settings owns the optional external-event prompt. The default asks for broad Yahoo/MSN-style news aggregation. Clearing it disables external-event recommendations. The prompt is bounded to 4 KB and reaches only the server-side daily handoff turn; the browser never fetches sources or receives credentials. The handoff prompt treats source content as untrusted data, requires trustworthy URLs for current-event claims, and does not treat recommendations as action authorization.

## Actions

| FRED can inspect directly | FRED asks you to confirm |
| --- | --- |
| Tycho documentation and search results | Install or update the Tycho skill |
| Projects and agents | Create or update a project |
| An agent's latest run and bounded logs | Create, message, start, or stop an agent |
| Schedules and daemon status | Create, pause, or resume a schedule |

Each mutation needs its own exact approval. Creating an agent prepares it without starting it. Review its instruction and settings, then approve starting it separately. Null values in a project update leave existing settings unchanged.

Results appear with the action and provide links to the affected resource. Tycho records bounded action receipts in the conversation so a later message can refer to what actually happened. A receipt does not itself trigger a new model run or approve another action.

Failed actions can be checked against current state. An uncertain outcome must not be retried blindly: verify it first, then prepare a new proposal if needed. Already claimed proposals cannot execute again.

## Daily continuity

FRED keeps one active conversation for the local date in its configured timezone. At midnight it waits for running work, summarizes the conversation, and archives it. The next conversation receives a bounded handoff; it does not replay every prior day.

Continuity and recent history are available from FRED. Tracked work retains stable resource references across days. The active conversation keeps the timezone and model settings it was opened with, so editing settings does not unexpectedly roll it over.

If summarization fails, Tycho preserves recent context in a fallback handoff and reports the recovery state. Archive retries do not repeat the summary. Drafts remain available while rollover is in progress.

## Implementation contract

The protected `personal_assistant_daily` role cannot be controlled through ordinary agent lifecycle endpoints. Dedicated Personal Assistant APIs own setup, opening, messaging, restart, and reset. State lives in `~/.tycho/logs/personal_assistant/state.json`; versioned handoffs live in its `handoffs/` directory.

The pure `PersonalAssistantActionCatalog` defines action names, required argument keys, and nullable fields. The model schema and execution validator must match this catalog. Action proposals come only from successful finalized runs; clients cannot create arbitrary proposals. Server-generated IDs, run provenance, locked claims, and immutable arguments prevent repeated confirmation from repeating a mutation.

The model cannot supply server, parent, or actor identity. Execution reuses Tycho's existing service paths and server-local ownership rules. Returned document/log content is data, not authorization for new actions. User-owned result schemas receive the bundled `action_proposals` update through the existing schema migration.

Daily handoffs contain normalized UTF-8 text and bounded lists. The next prompt receives less than 4 KB of serialized continuity, without cutting JSON in the middle of a string. The lifecycle derives its dated recommendation set from the handoff's bounded `promotion_candidates`, with open work and documented-capability fallbacks when generation is degraded. Historical archives remain separate from the current conversation.

### Protected message and queue API

FRED message, inquiry, and prompt-queue mutations use dedicated routes. Every such request carries the captured session identity as JSON fields `active_key` and integer `generation`; a stale or missing session returns HTTP 409 with a `stale_session` or `session_unavailable` detail. Parent-declared callers cannot mutate FRED and receive HTTP 403. Setup, open, restart, reset, and exact action confirmation keep their existing separate contracts.

Message submission is `POST /personal-assistant/messages`. It requires `client_request_id` matching `client-[A-Za-z0-9-]{1,100}` and a prompt or attachment payload; `start` is optional. Inquiry answers use `POST /personal-assistant/inquiries/:inquiry_id/answer` with the same acceptance fields plus `answer` (or `prompt`) and optional `feedback`. Inquiry dismissal and restoration are `POST /personal-assistant/inquiries/:inquiry_id/dismiss` and `/restore`. Queue editing, deletion, and explicit retry are respectively `PATCH /personal-assistant/prompt-queue/:id`, `DELETE /personal-assistant/prompt-queue/:id`, and `POST /personal-assistant/prompt-queue/retry`; queue edit bodies require `prompt`, while delete and retry require the session fields. Ordinary agent control and inquiry/queue mutation routes reject the protected FRED role.

Each message ID has one server-local acceptance record. The record fingerprints the session, message kind, prompt, attachments, start request, inquiry/feedback, retirement ID, and pull-request contexts. An identical retry returns `accepted: true` with `replayed: true`; reusing the ID with another payload returns HTTP 409 with `payload_mismatch`. The acceptance lookup is `GET /personal-assistant/messages/acceptance/:client_request_id`; it returns the captured `active_key`, `generation`, IDs, and factual state without appending, importing, queueing, or starting work.

Acceptance transitions are monotonic. `staged` and `message_recorded` records become `queued`, `accepted`, `dispatched`, or `start_failed` when the corresponding journal, queue, or positive run evidence exists. If recording or launch acknowledgement is interrupted, the result is `unknown`; unknown and launch-attempted records are never replayed or launched again without positive run evidence. The lookup may advance a record only from observed journal, queue, claim, or run evidence, and evidence-only promotion does not append or launch work.

An acceptance-backed queue deletion records `queued -> unknown` with a cancellation-in-flight marker before the non-dispatching delete, then records terminal `canceled` only after the queue mutation is durable. The delete response and acceptance lookup expose the canceled receipt; an identical POST returns `409` with `canceled` and never requeues, while a repeated DELETE replays the receipt. If deletion or its receipt write is interrupted, the acceptance remains `unknown` and returns `cancellation_unknown`; absence of a queue entry is not enough to claim cancellation. If a matching run wins a cancel-versus-dispatch race, positive run evidence promotes the receipt to `dispatched` or `start_failed`, never back to `queued`. The server keeps the newest 256 full records and leaves `acceptance_expired` tombstones for evicted IDs in the active generation, so an evicted ID cannot silently append or start again during that session. Tombstones from closed generations are pruned when the next generation opens; an old request still fails the active-key/generation guard and cannot mutate the new session, while lookup of the pruned ID returns not found. Remote attachments use the request ID in their deterministic cache key, so a replay does not import a second copy.

### Durable action worker and history

FRED action proposals are a durable queue with monotonic receipts. A single
bounded worker starts after Remote Server daemonization, periodically recovers
only expired leases, and holds each action's execution lock through claim,
effect, and receipt. Duplicate confirmation reads the stored receipt without
waiting for that lock. A server-owned `precondition_token` accompanies the
proposal digest; confirmation freezes the displayed preview and effective
create-agent settings, including explicit null values and the resolved
workspace. Later GETs do not replace that frozen preview. Unavailable previews
return HTTP 409 with `details.code: "preview_unavailable"` and never queue or
execute the action. Null fields in an update-project proposal remain
unchanged; they are not expanded into a stale snapshot of the project.

Before an effect, the worker checks the active FRED generation and the frozen
material precondition. Verification does not use that pre-effect token as
proof: current matching state is only an observation. Without a committed
receipt or a durable marker unique to the proposal, verification remains
`outcome_unknown` and cannot claim completion or no effect. Start and create
operations use AgentStore's read-modify-write transaction; delegated creation
commits the child, relationship, and delegation memory together, so a failed
relationship cannot leave an orphan.

`GET /personal-assistant/history/:id` includes the selected historical
`generation` and `agent_key`, plus old-generation proposals as
`archived_actions`. `expired_actions` is only the subset of unconfirmed
`ready` and `awaiting_confirmation` proposals that became `state: "expired"`
with their original `historical_state`. Accepted, in-flight, failed,
uncertain, executed, and rejected actions remain in `archived_actions` with
their factual `state` and `recovery` data. Every archived action is read-only
and omits preflight and precondition authority. When the archived agent is
available, `archived_conversation` supplies read-only agent and conversation
paths. These records are factual continuity only; they cannot be confirmed,
retried, or executed in the new generation.

### Progress and measured latency

Conversation polling reads the durable `AgentEventJournal` projection. Stable
`event_id`, `run_id`, source, and journal sequence metadata make repeated full
reads safe across reconnects; partial structured output never enters the
action proposal store. A projected semantic assistant event is visible through
conversation before the final structured result is persisted.

The Remote Server shares a bounded timezone snapshot cache across its short-lived
services. It computes the local date and next daily boundary together in a
child-only timezone environment, reuses them until the derived boundary, and
never changes process-global `TZ`. The synthetic 101-agent inventory/progress
fixture (100 non-running agents plus one FRED session with a projected semantic
event) reduced status serialization from roughly 476 ms to 123 ms; warm
status/actions/current-work reads measured about 0.6/0.7/0.6 ms. No harness
ran in this fixture. These are fixture measurements, not production SLAs.
Bootstrap `/setup` remained a separate 3.47 s catalog step.

The focused Remote UI defers catalog, setup, and schedule discovery on the
initial configured-FRED conversation path. Unconfigured onboarding and normal
Settings/navigation still load setup discovery and keep the model, effort,
timezone, and confirmation controls available. When actual FRED work or an
unresolved submission is active, visible polling uses a 1.5 s cadence; idle
polling uses 12 s, and hidden polling uses 30 s. Focused read failures reuse a
bounded policy: the first visible failure backs off to idle cadence, repeated
failures reach the hidden cadence, and the count is capped at two. A successful
refresh restores the normal active/idle choice, while online, tab-return, and
manual refreshes retry immediately.

Refresh reconciliation keeps the composer draft, focus, and conversation scroll
usable while a background read is pending. The compatibility current-work API
remains available to non-UI clients, but the focused FRED view no longer fetches
or renders it. The 3.47 s `/setup` measurement above is a historical synthetic
catalog observation, not a claim
about configured-FRED first-render or end-to-end latency.
