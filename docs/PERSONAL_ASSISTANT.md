# FRED Personal Assistant

FRED helps you set up Tycho projects, prepare and follow agents, inspect results, and manage schedules. It is an opt-in, Codex-only conversation on the current Tycho server. Project agents still use their own harness settings.

## Getting started

Visit FRED, review the model, reasoning effort, and timezone, then confirm setup. Visiting automatically creates or resumes the current daily session; it does not run a model. Start with a suggested task or write your own request. FRED is available before you have a project.

The setup form uses the server's Codex catalog when available. Executable readiness is not a guarantee that authentication or a particular model will work. Setup keeps a manual model fallback when discovery is unavailable.

Settings can be changed without deleting your conversation. Saved changes apply to the next daily conversation, or you can explicitly restart FRED to apply them now. Restart is an advanced lifecycle action: it archives the current idle conversation and keeps settings and continuity. Reset is separate: it deletes the active session and its logs, clears settings and active continuity, and removes pending actions. It does not erase previously archived conversations or historical handoff files.

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

Daily handoffs contain normalized UTF-8 text and bounded lists. The next prompt receives less than 4 KB of serialized continuity, without cutting JSON in the middle of a string. Historical archives remain separate from the current conversation.

### Protected message and queue API

FRED message, inquiry, and prompt-queue mutations use dedicated routes. Every such request carries the captured session identity as JSON fields `active_key` and integer `generation`; a stale or missing session returns HTTP 409 with a `stale_session` or `session_unavailable` detail. Parent-declared callers cannot mutate FRED and receive HTTP 403. Setup, open, restart, reset, and exact action confirmation keep their existing separate contracts.

Message submission is `POST /personal-assistant/messages`. It requires `client_request_id` matching `client-[A-Za-z0-9-]{1,100}` and a prompt or attachment payload; `start` is optional. Inquiry answers use `POST /personal-assistant/inquiries/:inquiry_id/answer` with the same acceptance fields plus `answer` (or `prompt`) and optional `feedback`. Inquiry dismissal and restoration are `POST /personal-assistant/inquiries/:inquiry_id/dismiss` and `/restore`. Queue editing, deletion, and explicit retry are respectively `PATCH /personal-assistant/prompt-queue/:id`, `DELETE /personal-assistant/prompt-queue/:id`, and `POST /personal-assistant/prompt-queue/retry`; queue edit bodies require `prompt`, while delete and retry require the session fields. Ordinary agent control and inquiry/queue mutation routes reject the protected FRED role.

Each message ID has one server-local acceptance record. The record fingerprints the session, message kind, prompt, attachments, start request, inquiry/feedback, retirement ID, and pull-request contexts. An identical retry returns `accepted: true` with `replayed: true`; reusing the ID with another payload returns HTTP 409 with `payload_mismatch`. The acceptance lookup is `GET /personal-assistant/messages/acceptance/:client_request_id`; it returns the captured `active_key`, `generation`, IDs, and factual state without appending, importing, queueing, or starting work.

Acceptance transitions are monotonic. `staged` records become `message_recorded`, `queued`, or `accepted`; positive run evidence becomes `dispatched`, and an explicit start failure becomes `start_failed`. If recording or launch acknowledgement is interrupted, the result is `unknown`; unknown and launch-attempted records are never replayed or launched again without positive run evidence. The lookup may advance a record only from observed journal, queue, claim, or run evidence. The server keeps the newest 256 full records and leaves `acceptance_expired` tombstones for evicted IDs in the active generation, so an evicted ID cannot silently append or start again during that session. Tombstones from closed generations are pruned when the next generation opens; an old request still fails the active-key/generation guard and cannot mutate the new session, while lookup of the pruned ID returns not found. Remote attachments use the request ID in their deterministic cache key, so a replay does not import a second copy.
