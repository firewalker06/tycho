# FRED Personal Assistant

FRED helps you set up Tycho projects, prepare and follow agents, inspect results, and manage schedules. It is an opt-in, Codex-only conversation on the current Tycho server. Project agents still use their own harness settings.

## Getting started

Open FRED, review the model, reasoning effort, and timezone, then confirm setup. Opening the conversation does not run a model. Start with a suggested task or write your own request. FRED is available before you have a project.

The setup form uses the server's Codex catalog when available. Executable readiness is not a guarantee that authentication or a particular model will work. Setup keeps a manual model fallback when discovery is unavailable.

Settings can be changed without deleting your conversation. Saved changes apply to the next daily conversation or a confirmed restart. Restart archives the idle conversation and keeps settings and continuity. Reset is separate: it deletes the active session and its logs, clears settings and active continuity, and removes pending actions. It does not erase previously archived conversations or historical handoff files.

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
