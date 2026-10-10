# Pre-execution tool hooks and dangerous-command policy

Research date: 2026-10-10
Fizzy card: [#292](https://fizzy.startkit.tech/1/cards/292)

## Scope

This report studies a pre-execution policy for Tycho-managed harnesses. It does
not add runtime code. A separate card must define and implement the policy.

The local Fizzy CLI could not read Card 292 because the only saved profile had
no token. This report uses the supplied card scope. No card comments were
available in that scope.

## Result

Claude, Codex, OpenCode, and Pi have a pre-tool integration point. Cursor is a
good candidate, but its CLI was not installed and was not tested. The harnesses
do not have one common decision contract. In Tycho headless mode, `ask` must be
treated as a blocked call that asks the model to return a structured inquiry.

Tycho should use one shared policy engine and a small adapter for each harness.
The current stream sleep breaker must stay as a fallback. A pre-tool hook is a
guardrail. It is not a complete operating-system security boundary.

## Harness evidence

| Harness | Installed and headless mode used by Tycho | Pre-tool control | Deny reason and input change | One-run installation | Failure and timeout behavior | Result |
| --- | --- | --- | --- | --- | --- | --- |
| Claude Code | 2.1.296 at test time; `--print --output-format stream-json --verbose` | `PreToolUse` command, HTTP, MCP, prompt, or agent hook | `permissionDecision: deny` gives a reason to Claude. `ask` and `allow` are supported. `updatedInput` replaces the full input object. | Pass a temporary file with `--settings`. Use `--setting-sources` to limit normal settings. A temporary plugin can also use `--plugin-dir`. `--no-session-persistence` is available for tests. | Exit 2 blocks. Other errors and timeouts allow normal permission processing by default. `onFailure: "block"` is available from 2.1.295. | Supported. End-to-end test was unavailable because local OAuth refresh failed. The deny JSON contract was tested directly. |
| Codex | 0.160.0; `exec --json`; hooks feature reports stable | Synchronous `PreToolUse` for Bash, `apply_patch`, MCP, and most local function tools | A deny reason is model-visible. `updatedInput` can replace Bash or tool arguments. `ask` is parsed but is not supported. | Pass an inline hook table with `-c`, use a Tycho-owned script path, and add `--dangerously-bypass-hook-trust` only after Tycho validates that script. `--ephemeral` and `--ignore-user-config` isolate tests. | An explicit deny blocks. A callback error, malformed result, unavailable MCP hook, or timeout fails open. Background hooks cannot block. | Supported. A real ephemeral test blocked the sentinel and returned its reason to the model. |
| OpenCode | 1.18.4; `run --format json --dir WORKSPACE` | Plugin callback `tool.execute.before` | Mutate `output.args` before execution. Throw an error to stop the call and give the model the error. There is no native dynamic ask from this callback. | Set `OPENCODE_CONFIG_DIR` to a Tycho-owned run directory with a plugin. `OPENCODE_CONFIG_CONTENT` can add runtime config. These layers merge with other config unless Tycho also isolates standard config locations. | The public plugin reference shows a thrown error as the blocking method. It does not define a hook timeout or a fail-open/fail-closed switch. A stalled callback can stall the tool path. | Provisionally supported. A direct plugin-contract test passed. An isolated live model run was not done. Exact-version runtime verification is required before implementation. |
| Pi | 0.84.4; `--mode json` | Extension event `tool_call` runs before tool execution | Return `{block: true, reason}`. Mutate `event.input` in place to replace arguments. Pi does not revalidate changed input. | Use `--no-extensions --extension PATH` for a Tycho-owned per-run extension. Tests can add `--no-session`. | A `tool_call` handler error blocks the tool as a fail-safe. The primary reference does not define a handler timeout, so Tycho must keep the policy callback small and bounded. | Supported. A real no-session JSON test blocked the sentinel and returned its reason to the model. |
| Cursor candidate | CLI not installed; version unavailable | `preToolUse` and `beforeShellExecution` hooks | `preToolUse` supports deny reason and `updated_input`. `ask` is accepted but is not enforced there. `beforeShellExecution` supports allow, deny, and ask, but not input replacement. | Current docs list enterprise, team, project `.cursor/hooks.json`, and user `~/.cursor/hooks.json`. No one-run CLI hook path was verified. | Invalid JSON for permission hooks blocks. Other failures and timeouts fail open by default. `failClosed: true` changes them to block. | Candidate only. Do not add it to Tycho until the CLI, headless contract, and one-run setup are tested. |

### Primary sources

- [Claude Code hooks reference](https://code.claude.com/docs/en/hooks)
- [Codex hooks reference](https://learn.chatgpt.com/docs/hooks)
- [OpenCode plugin reference](https://docs.opencode.ai/docs/plugins/)
- [OpenCode configuration reference](https://docs.opencode.ai/docs/config/)
- [Pi extension reference](https://github.com/earendil-works/pi/blob/main/packages/coding-agent/docs/extensions.md)
- [Cursor hooks reference](https://cursor.com/docs/hooks)

The OpenAI documentation is the authority for Codex behavior. The installed Pi
package points to the same `earendil-works/pi` repository used above.

## Safe test evidence

The test prompt requested one harmless command that would write the text
`tycho-hook-probe` to a temporary marker. The policy blocked that exact token.
No destructive command was used.

| Test | Evidence |
| --- | --- |
| Codex | Ephemeral run, ignored user config, inline `PreToolUse`, and bypassed hook trust for the validated temporary script. Codex reported `Command blocked by PreToolUse hook` and repeated the policy reason. Marker absent. |
| Claude | 2.1.296 loaded the temporary settings and no-session mode, but stopped before a tool call because OAuth refresh failed. Direct invocation of the hook returned the documented deny object. Marker absent. |
| OpenCode | The installed Node runtime loaded the temporary plugin, called `tool.execute.before`, and observed the expected blocking error and reason. This was a contract test, not a full OpenCode model session. |
| Pi | JSON mode, no saved session, no discovered extensions, and one explicit temporary extension. Pi returned an error tool result with the policy reason. Marker absent. |
| Cursor | Not tested because no Cursor CLI executable was present. |

The first Codex probe used a non-Git temporary project hook. Codex did not load
that hook, and the harmless marker was written. The marker was removed. The
valid test used inline run config and blocked the command. This is evidence that
Tycho must not depend on project-hook discovery for per-run policy.

## Current Tycho behavior

`HQ::AgentCommandBuilder` has separate command builders for all four supported
harnesses:

- Codex uses `exec --json` and can use the approval-and-sandbox bypass.
- Claude uses print mode with stream JSON and can skip permissions.
- OpenCode uses `run --format json` and can use `--auto`.
- Pi uses JSON mode. In a restricted sandbox, Tycho removes its write and shell
  tools instead of adding a command policy.

`HQ::SleepCircuitBreaker` reads output after a tool call is emitted. It supports
Codex, Claude, and Pi, but not OpenCode. It stops the harness after the third
unique `sleep`, `usleep`, or `wait` call. It cannot stop the first calls before
execution.

`HQ::ShellCommandClassifier` is a useful base for shell structure. It handles
chains, pipelines, substitutions, functions, common wrappers, nested `sh -c`,
comments, quotes, and heredocs. It only answers whether a configured executable
is active. It does not resolve destructive flags, target paths, aliases,
variables, `eval`, interpreter code, remote shells, `find -exec`, or `xargs`.

## Recommended policy

The actions below are recommendations, not current Tycho behavior.

| Command class | Default action | Reason and exceptions |
| --- | --- | --- |
| Catastrophic deletion of `/`, a home directory, a workspace root, a parent directory, or a broad unresolved target | Deny | The possible loss is too large. Deny when a variable, glob, or substitution can resolve to one of these targets. |
| Recursive or multi-file deletion inside the workspace | Ask | A generated directory with a proven path can be approved. In headless mode, block and request a structured inquiry. A single known temporary file can be allowed and logged. |
| Write or deletion outside the workspace and approved temporary roots | Deny if proven; ask if ambiguous | Resolve relative paths against the tool `cwd`. Do not assume that an unresolved variable is safe. |
| Destructive Git operations that discard work, including hard reset, clean, checkout/restore discard, branch force-delete, and stash drop/clear | Deny | The user can do these operations directly after review. Preserve branches, files, and stashes by default. |
| Force push to the default or protected branch | Deny | Do not permit an override in the model loop. A force-with-lease push to another branch requires operator approval. |
| Disk, volume, partition, boot, shutdown, broad process-kill, or system-service destructive commands | Deny | Sandbox and operating-system controls must also enforce this boundary. |
| Remote script piped to a shell or evaluated through substitution | Deny | Download and inspect a pinned artifact first. A checksum does not make direct pipe execution auditable. |
| Broad secret output, credential export, keychain dump, auth-token print, or reads of known secret files | Deny | Permit status commands that redact secrets. Log only the rule and decision, not the secret-bearing command output. |
| `gh pr merge` and equivalent GitHub merge API calls | Deny | PR merge is an operator-only action. Creating or updating a draft PR stays outside this rule. |
| Long `sleep`, shell `wait`, polling loops, or repeated status commands | Deny | Tell the model to use a Tycho durable verifier callback. Allow and log a short tool-native timeout that bounds real work. |
| Read-only inspection and scoped test commands | Allow and log policy metadata | Normal reads must not be slowed by an operator prompt. Apply separate secret-file rules first. |

For an `ask` result, every current Tycho headless adapter must block the call and
give the model a stable reason such as `operator approval required`. The model
can then return Tycho structured inquiry output. Do not depend on a terminal
approval prompt.

## Shell analysis requirements

A deny list must parse commands as shell programs. Plain substring matching is
not sufficient.

1. Parse lists, pipelines, subshells, functions, command substitutions,
   process substitutions, and expanding heredocs.
2. Unwrap known launchers such as `env`, `sudo`, `command`, `exec`, `nohup`,
   `nice`, `time`, `timeout`, and nested shell `-c` arguments.
3. Inspect every pipeline stage and chained command. A safe first command does
   not make a later command safe.
4. Resolve literal and normalized paths from the event `cwd`. Compare real
   parents with the workspace and approved temporary roots. Do not follow an
   untrusted symlink as proof that a target is safe.
5. Treat unresolved variables, aliases, functions from sourced files, `eval`,
   encoded scripts, interpreter one-liners, `xargs`, `find -exec`, remote SSH,
   containers, and package-manager scripts as unknown execution. Ask or deny
   when the unknown part can carry a high-risk action.
6. Check Git remotes, refspecs, the resolved destination branch, and aliases.
   Text such as `main` in a log message must not match a force-push rule.
7. Mask quoted data, comments, non-expanding heredocs, search patterns, and
   documentation text to reduce false positives.
8. Apply a small callback timeout. Use the most secure failure option that the
   harness supports. A fail-open harness still needs operating-system sandbox
   and stream-breaker fallback.

Important bypasses remain after shell parsing. A model can call a binary that
performs destructive work internally, use a custom MCP tool, or change and run
a local script after it passed review. The shared policy must inspect all local
tool types that a harness exposes, not only Bash. Operating-system file,
network, identity, and GitHub protections remain necessary.

## Proposed Tycho shape

This design is a recommendation for a future card:

1. Add one `PreExecutionPolicy` that returns `allow`, `deny`, `ask`, or `log`, a
   stable rule ID, and a short redacted reason.
2. Add adapters that convert that result to Claude JSON, Codex JSON, an
   OpenCode plugin result, and a Pi extension result.
3. Create policy files below the Tycho run log root. Install them only for the
   process being started. Do not edit user or project harness configuration.
4. Make policy audit records run-scoped. Store the rule, action, harness, tool,
   and a redacted command digest. Do not store secret values.
5. Map `ask` to a blocked tool result plus structured inquiry guidance in all
   headless adapters.
6. Keep the sleep circuit breaker as defense in depth. Add OpenCode stream
   support only after its exact JSON start event is verified.
7. Keep the existing sandbox and permission settings. A hook must not replace
   sandboxing, protected-branch rules, credential boundaries, or operator
   ownership rules.

## Limits and next work

- Fizzy Card 292 and its comments could not be fetched because no Fizzy token
  was configured.
- Claude authentication failed before a live tool call. The installed CLI and
  direct hook contract were inspected, but the full headless deny path remains
  unverified.
- OpenCode was not tested through a live model session. Its plugin surface has
  changed in recent releases, so an exact-version acceptance fixture is needed.
- Cursor was not installed. Its headless CLI and one-run hook setup are not
  verified.
- No timeout experiment used a blocking wait. Timeout semantics come from
  primary documentation, and undocumented OpenCode and Pi timeout behavior is
  marked as unknown.

A separate implementation card must add the policy, adapters, audit format,
tests, and rollback plan. That card must include isolated acceptance tests for
each pinned harness version before Tycho enables enforcement.
