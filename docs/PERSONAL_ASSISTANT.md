# Personal Assistant

The Personal Assistant is an opt-in, Codex-only daily session owned by Tycho. Configure it from the Remote UI with a Codex model, reasoning effort, and an IANA timezone. It never inherits a project harness and remains disabled by default.

The first opened session contains a fixed introduction before it can start a model run. Its explicit `personal_assistant_daily` role prevents public single and bulk archival. The lifecycle state is stored below `~/.tycho/logs/personal_assistant/`; it is not a normal project agent or schedule.

At local midnight Tycho closes the daily session, waits for an active run, and dispatches one internal summary-only turn in the same managed session. The daily handoff is versioned and bounded; archive retries reuse the durable handoff rather than dispatching another summary.
