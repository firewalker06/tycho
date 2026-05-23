# Gotchas

## Charm Ruby textarea cursor

`Bubbles::TextArea` uses a `Bubbles::Cursor` internally.

In the current Ruby gem, the default cursor mode is blinking and typing does not
reset the blink timer. That means the cursor can disappear while you are still
holding a key down.

If an input should keep the cursor visible, set it to static:

```ruby
input = Bubbles::TextArea.new(width: 80, height: 4)
input.cursor.set_mode(Bubbles::Cursor::MODE_STATIC)
```

HQ does this for `ChatComposer`.

## PID reuse after HQ restart

`ManagedAgent#start!` spawns children with `pgroup: true` and persists
the resulting `@pid` to `logs/managed_agents.json`, and `stop!` signals
the whole process group with `Process.kill("TERM", -@pid)`.

After HQ restarts (including via `ctrl+r`), a persisted `@pid` can refer
to a PID the OS has recycled to a different owner. `ProcessLiveness.alive?`
treats `EPERM` from `kill(0, pid)` as "alive" — correct for foreign
running processes in general, but a trap here: it made `running?` return
true for a recycled PID, and `stop!` then tried to signal a pgroup we
did not own and raised `Errno::EPERM`.

Guard against this by additionally checking that the PID still belongs
to our spawned process group before treating it as live:

```ruby
Process.getpgid(pid) == pid
```

Since we spawn with `pgroup: true`, the child's PGID always equals its
own PID. A recycled foreign PID will have a different PGID (or raise
`EPERM`/`ESRCH` from `getpgid`, which must be rescued as "not ours").

Any code that signals a persisted PID across process restarts needs the
same ownership check, not just a `kill(0)` liveness probe.

## Glamour markdown renders inside Bubbletea

Calling `Glamour.render` directly from inside a running Bubbletea
program stalls for seconds (observed 1.7s – 11s, variable) because both
gems embed a Go runtime and their schedulers contend inside one MRI
process.

HQ renders markdown via `bin/worker --type glamour`, a per-render Ruby
subprocess spawned from
`HQ::UI::Rendering::ChatRendering.glamour_subprocess_render`. Results
are cached process-wide; the UI polls via `ChatRenderPollMessage` until
the render lands. Tests force the synchronous path with
`ENV["TYCHO_GLAMOUR_SYNC"] = "1"`.

Background, rationale, and gotchas (style `"auto"` emitting plain text
over a pipe, document padding, list-continuation indent) are documented
in `docs/research/glamour_bubbletea.md`. Don't switch back to in-process
rendering without re-measuring latency under a live Bubbletea loop.

## Claude `--json-schema` is not reliably reapplied on `--resume`

HQ passes `--json-schema` on every Claude-compatible invocation (both
fresh sessions via `--session-id` and follow-ups via `--resume`). On a
fresh session the model honors the schema: the final
`{"type":"result"}` event in `raw.log` arrives with `result: ""` and a
populated `structured_output: {status, summary, inquiry}`.

On resumed sessions — observed across multiple runs that share a single
`session_id` — the schema is often *not* honored on later turns.
`structured_output` is absent entirely and the top-level `result` field
holds the assistant's prose instead. Public Claude Code docs
(`cli-reference.md`, `headless.md`) describe `--json-schema` as a
per-invocation `-p`-mode flag but say nothing about `--resume`
interaction or degradation across turns, so the root cause is not
documented. The most plausible explanations are (a) resume not
re-registering the internal `StructuredOutput` tool, (b) context
compaction dropping the schema instruction, or (c) model drift on long
sessions. The log alone cannot distinguish these.

HQ defends against this in `ManagedAgent#normalize_structured_result_payload`:
when the parsed `{"type":"result"}` event has no `structured_output`
but does have a non-empty prose `result` field, synthesize
`{status, summary}` from it (`status` derived from `is_error`, `summary`
is the prose). Without this fallback, `summarize_run` drops through to
`summarize_from_log`, which slices the last three raw-log lines into a
177-char truncation — producing a JSON-looking Summary in the TUI
because those lines are giant stream-json events.

The tradeoff: resumed Claude runs that lose the schema also lose the
structured `inquiry` field, so they cannot trigger the gated inquiry
review form. Inquiries still work on fresh sessions and on any resumed
turn where Claude does honor the schema. Codex is unaffected — it uses
`--output-schema` + `-o last_message.json`, which is a separate
mechanism, and its event stream does not use `type: "result"` with a
prose `result` field.

Don't remove the `--json-schema` flag for Claude-compatible harnesses to "simplify"
things — losing it sacrifices inquiries on every run, not just resumed
ones. Keep the flag and keep the fallback.
