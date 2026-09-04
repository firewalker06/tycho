# Personal Assistant

The Personal Assistant is an opt-in, Codex-only daily session owned by Tycho. Configure it from the Remote UI with a Codex model, reasoning effort, and an IANA timezone. It never inherits a project harness and remains disabled by default.

The first opened session contains a fixed introduction before it can start a model run. Its explicit `personal_assistant_daily` role prevents public single and bulk archival. The lifecycle state is stored below `~/.tycho/logs/personal_assistant/`; it is not a normal project agent or schedule.
