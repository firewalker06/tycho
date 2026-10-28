# Experimental native agy adapter

Tycho launches Antigravity CLI directly and parses its native
`event`/`step_update`/`result` stream. No Claude wrapper or session alias
mapping is used. Claude and Pi parser behavior is unchanged.

## Configuration

Install and authenticate `agy` independently. Choose a model using `agy models`.
Start with disposable Tycho state and a scratch workspace:

```yaml
projects:
  - key: agy-poc
    name: agy PoC
    path: /absolute/path/to/disposable/workspace
    agent: agy
    model: gemini-3.8-flash-medium
```

Set `TYCHO_AGY_BIN` to override the executable. Do not configure a custom
profile named `agy`; any adapter conflicts with the built-in harness and
configuration loading rejects it. Create a fresh agent for native
verification. Old bridge agents contain aliased sessions and persisted JSON
messages; they are not migrated.
Keep their state as historical evidence rather than resuming their alias
as an agy conversation ID.

## Behavior

- Managed prompts use `--output-format stream-json --print` and a 120-second
  print timeout. Model and JSON Schema use agy's native flags. Saved
  reasoning effort is deliberately ignored; agy receives no `--effort`
  flag and uses its native default.
- Recommended model default is `gemini-3.8-flash-medium`. In live testing,
  agy's low-effort default model intermittently ignored `--json-schema`
  on the first attempt (empty result requiring a correction retry), while
  medium followed the schema in every run. The quick-agent and agent-form
  model selects preselect this default; operators can still pick any
  `agy models` entry or leave "Default" for agy's native choice.
- Tycho stores the emitted `conversation_id` and resumes with `--conversation`.
- Tool calls/results project into the conversation as events arrive.
- Assistant text appears once from the terminal result. Step deltas stay in
  the raw log because they can contain incomplete structured JSON.
- The displayed assistant message contains the human summary or inquiry.
  Structured results and raw events retain the complete payload.
- Native errors become failed results. Tycho's existing schema validation
  and bounded correction runner also support native agy responses.
- Model discovery uses `agy models`. Authentication status is unknown:
  no supported auth-status command is documented. Model listing alone
  does not prove that prompts will authenticate.

## Safety and limits

Every Tycho sandbox selection currently requests `--mode plan --sandbox`.
The adapter never adds `--dangerously-skip-permissions`, including when a
template defaults to `danger-full-access`. This deliberately conservative
PoC does not implement write-capable sandbox selections.

**These flags are not verified filesystem isolation.** The installed CLI
reported `permission_mode: always-proceed` with them while the user's existing
settings explicitly configured `toolPermission: always-proceed`. This was
not a clean-config test of agy's defaults. Use a dedicated OS
sandbox before trusting unreviewed repositories or prompts. Do not deploy
this experimental adapter to a production Tycho service yet.

Tycho state isolation does not isolate agy's credentials, global extensions,
tools, or conversation store. Tool output may be a size summary rather than
the actual file contents. Interactive launch, permission inquiries,
delegation, and scheduling are not covered by the live acceptance check.
Tycho discovers existing agy skills in `~/.gemini/config/skills` (the
documented global scope), the legacy `~/.gemini/antigravity-cli/skills`,
and the project's `.agents/skills`.
Discovery follows a symlinked skill directory to its target and deduplicates
skill names, with project skills
taking precedence. Tycho installs its bundled skills for agy into
`~/.gemini/config/skills` using the same checksummed, marker-verified
installer as codex; `agy` 1.4.7 was verified live to load skills from both
that directory and the workspace `.agents/skills`. Home `~/.agents/skills` is
not an agy skill directory and is not written or discovered for agy.

## Verification

Run `bundle exec ruby -r ./test/support/push_safety.rb test/agy_harness_test.rb`
for process-level synthetic native protocol checks without a provider.
Run `bin/test` for the full suite.

For live acceptance, start an isolated Remote UI on a spare loopback port.
Use agent-browser to create a native agy agent, read a known scratch file,
and ask it to remember a marker. In a follow-up, request the marker without
restating it. Check two successful runs, the same native conversation ID,
readable assistant messages without JSON envelopes, and raw structured
results retained on disk. Reload the page to verify saved rendering. Retain
sanitized screenshots and run metadata.
