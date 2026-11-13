# DeepSeek Harness

Tycho supports the official DeepSeek Harness as `dsh`. This is a native
headless adapter. The contract is based on `@deepseek-ai/dsh` **0.2.2-rc.1**,
whose source tag resolves to `66491b05e3f05ad35bcdd4f6cd7ed26041d9e3db`.
The npm `latest` tag reported that version on 2026-11-12. The package requires
Node.js 24.9.0 or later. DeepSeek describes the harness as a developer preview
with breaking changes. Other versions require verification before use.

DeepSeek also documents how to use its API through Claude Code. That uses
Tycho's existing `claude` adapter and a separately configured wrapper. It is a
different integration. The `dsh` adapter runs the native DeepSeek executable.

## Operator setup

Install the selected upstream release using the
[official project instructions](https://github.com/deepseek-ai/deepseek-harness).
Keep installation and credentials under operator control. Tycho does not
install dsh, create credentials, or edit persistent profile overrides. The
native launcher can initialize its own runtime files. Set `TYCHO_DSH_BIN`
to an executable path to override `dsh` lookup. This setting accepts an
executable, not a shell command. Custom Tycho harness profiles can use
`adapter: dsh` with an `execution_command`; only stdin prompt transport is
supported for that adapter.

The shipped headless profile reads credentials from the launch environment,
then the current workspace's `.env`, then `DSH_HOME`'s `.env`. It ignores GUI
sign-in by default. See the
[released headless credential contract](https://github.com/deepseek-ai/deepseek-harness/blob/dsh-v0.2.2-rc.1/packages/bundle/headless/README.md#credentials).
Keep keys out of prompts, command arguments, result attachments, and Tycho
configuration. Tycho's normal spawn boundary removes server-only remote and
GitHub credentials. The readiness view reports authentication as unknown;
listing a model does not prove that the account can use it.

Use an existing registered project:

```sh
bin/tycho harness list --harness dsh --json
bin/tycho agent create PROJECT_KEY "Read the project instructions" --harness dsh --model deepseek-flash
```

Add `--run` only when the operator has prepared the executable and credentials
and intends to make model requests. Creating an agent alone does not call the
provider. The offline model catalog suggests `deepseek-flash`; it does not
claim account access or provide a complete live model list.

## Command and model contract

Tycho launches the headless profile in the registered workspace, uses `--json`,
passes the whole prompt on stdin, and uses `--session-id` after it captures the
opening event's `sessionId`. It repeats the selected permission preset and
`--approval-policy never` on every invocation. Calls that need approval are
rejected by that policy. The native presets are `read-only`, `workspace-write`,
and `danger-full-access`. Tycho rejects other presets and adds no extra write
roots. The upstream sandbox has platform limits; Tycho does not certify
confinement. See the
[released CLI contract](https://github.com/deepseek-ai/deepseek-harness/blob/dsh-v0.2.2-rc.1/docs/cli-help.md)
and
[released sandbox contract](https://github.com/deepseek-ai/deepseek-harness/blob/dsh-v0.2.2-rc.1/packages/sandbox/sandbox-local/README.md).

Headless has no model or effort flags. A small Ruby runner creates a mode-0600
JSON overlay, passes it through `--patch`, waits for dsh, then removes the file.
The overlay sets `agent-default-model` to provider `deepseek-official`, the
saved model (or `deepseek-flash` when empty), and the saved `reasoningEffort`
when supplied. Model and effort values are serialized as data. No prompt or
credential enters this file. The runner does not change persistent profiles.
This adapter selects the native DeepSeek API-key route; it is not a generic
provider router. Unsupported model/effort pairs remain upstream errors. See
[released model selection configuration](https://github.com/deepseek-ai/deepseek-harness/blob/dsh-v0.2.2-rc.1/packages/core/agent-default-model/src/index.ts).

## Results and limits

The runner requires exit code zero plus a terminal `final` event whose
`reason.kind` is `completed` and whose `sessionId` matches the opening event.
An error event, a missing final, a mismatched identity, an aborted/null reason,
or a nonzero process exit fails the run. A completed tool event does not prove
that its inner shell command succeeded.

The parser preserves tool calls/results and available per-step token counts.
Unknown token fields and dollar costs remain unavailable. Intermediate text
and reasoning are progress records. dsh can truncate those strings; the final
answer is unbounded and becomes the canonical assistant answer. Tycho keeps
the received raw stream. It does not claim that this projection contains the
complete native session log. See the
[released JSON projection implementation](https://github.com/deepseek-ai/deepseek-harness/blob/dsh-v0.2.2-rc.1/packages/bundle/headless/src/json-stream.ts).

There is no native JSON Schema flag. Tycho supplies its result instructions,
validates the final answer, and can request correction in the same native
session. Native adoption is limited to a compatible profile and the same
working directory. If native identity is absent, Tycho retains its existing
canonical transcript replay behavior.

Interactive terminal chat, Tycho skill installation/discovery, and the typed
sleep circuit breaker are not supported for dsh. Use Tycho Conversation for
follow-up. Configure native skills through the operator's dsh profile. The
Remote UI shows the official DeepSeek icon through its shared harness labels; see [Harness logos](HARNESS_LOGOS.md).

## Verification

Run the fixture checks without a provider:

```sh
bundle exec ruby -r ./test/support/push_safety.rb test/dsh_harness_test.rb
bin/test
```

The released CLI help and a JSON model overlay were also checked with an
isolated package installation and an empty credential environment on Node.js
26.0.0. No model request was made.

The fixture checks exact stdin bytes for a large Unicode prompt, private model
overlay cleanup, cold/resumed commands, permission selection, terminal failure
conditions, event projection, token mapping, persisted session identity, and
same-session structured-result correction. These checks do not prove live
model access or native sandbox enforcement. No paid request is required.
