# Personal Assistant

The Personal Assistant is an opt-in, Codex-only daily conversation owned by Tycho. It is configured from Remote UI with a Codex model, reasoning effort, and an IANA timezone. It never inherits a project harness, starts disabled, and is neither a project agent nor a schedule.

The first opened conversation contains Tycho's fixed introduction before a model run can start. Its `personal_assistant_daily` role prevents both individual and bulk archive operations. The lifecycle state lives in `~/.tycho/logs/personal_assistant/state.json`; bounded, versioned handoffs live in its `handoffs/` directory.

## Daily lifecycle

1. A confirmed setup saves the model, reasoning effort, and IANA timezone, then enables the feature.
2. Opening is lazy and idempotent: one protected session exists for the active local date.
3. At the active session's local midnight, Tycho marks it `closing` and stops accepting new prompts. Existing work is allowed to finish.
4. Tycho dispatches exactly one internal summary-only turn using the same native Codex session. It records the summary intent before launching the harness, so launch failures cannot append duplicate summary messages.
5. A successful structured handoff is bounded before it is written. If summary execution fails, Tycho writes a bounded fallback from the recent user context.
6. Tycho archives internally. If archive fails, later reconciliation retries only the archive; it never re-summarizes.

The active session keeps the timezone it was opened with. A later setup change applies to the next day, preventing an accidental early rollover. Every Remote API read and open request also reconciles the lifecycle, so midnight rollover does not depend on the schedule daemon. Missed ticks and offline periods safely catch up without creating overlapping daily sessions; the old run always finishes before its summary, handoff, archive, and next-day creation.

## Remote API

- `GET /personal-assistant` returns readiness, lifecycle state, active key/date, fixed introduction, and saved configuration.
- `POST /personal-assistant/setup` requires `confirmed: true` with `model`, `reasoning_effort`, and `timezone`.
- `POST /personal-assistant/open` lazily opens the protected daily conversation.

Manual archive endpoints return a conflict for this role. Prompt submission is rejected while the daily session is closing.

## Action proposals

Codex may return optional `action_proposals` only in a finalized successful structured result from the currently active daily agent. There is no client proposal-creation API. Tycho accepts only typed declarative proposals with the exact argument object coupled to each action type. Proposals are persisted with a server-generated ID, source-run ID, and digest. Claiming is locked and durable before execution; an interrupted claim is never retried automatically. Read-only actions run directly; every mutation needs one exact Tycho confirmation and can execute at most once.

The model cannot provide a server key, parent key, or actor identity. Tycho injects local-server and user/delegation provenance before calling the existing SkillInstaller or managed-agent paths. Replayed, modified, unsupported, and previously executed proposals are rejected.

Handoffs retain only normalized UTF-8 text and bounded lists. The next day receives at most 4 KB of the prior handoff as a fixed system continuity block; run IDs, timestamps, and other server provenance remain outside this promptable body.
