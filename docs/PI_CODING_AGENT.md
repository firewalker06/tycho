# Pi Coding Agent

Tycho's built-in Pi harness targets the documented
`@earendil-works/pi-coding-agent` 0.84.4 RPC command and event contract. See
[setup requirements](SETUP_REQUIREMENTS.md) for dependency profiles and
readiness checks.

## Install and Authenticate

Install Tycho's supported Pi version:

```bash
npm install -g --ignore-scripts @earendil-works/pi-coding-agent@0.84.4
```

Run `pi`, enter `/login`, and authenticate a supported provider. You can
instead configure a provider API-key environment variable documented by Pi.
Keep provider credentials out of Tycho.

Verify that Pi can load at least one authenticated model:

```bash
pi --list-models
```

Tycho reports Pi authentication as ready only when `pi --list-models` returns
at least one model.

## Sandbox Behavior

Pi has tool allowlists but no native equivalent to Tycho's workspace-write or
read-only filesystem sandboxes. For `danger-full-access`, Tycho does not pass a
`--tools` restriction, so Pi keeps its native configured tool set. For every
other Tycho sandbox mode, Tycho passes `--tools read,grep,find,ls`, removing
write, edit, and shell tools.

That restricted tool list reduces capabilities, but it does not create a
filesystem boundary or distinguish workspace-write from read-only. Treat Pi's
restricted modes as a conservative tool allowlist, not as a sandbox.
`workspace-write` receives the same `read,grep,find,ls` allowlist and keeps
that restriction until a verified filesystem boundary exists for Pi.

## Prompt Transport

Managed runs use `--mode rpc`. Tycho sends the exact prompt in the JSONL
`prompt.message` field on stdin. The shared stdin transport also supplies
new runs, native `--session` resume, and structured-output correction retries.
The prompt does not enter argv or environment variables. Raw logs and
canonical memory retain the prompt; saved command descriptions contain no
prompt text.

The runner reads `get_state.sessionId` and emits the session event used by
Tycho's recorder. It forwards native event lines without changes and waits
for `agent_settled`, which includes automatic retries and compaction, before
closing stdin to request normal EOF shutdown. After prompt acceptance, the
runner also checks `get_state`: idle input handled by an extension can finish
without an agent run or `agent_settled`. Once an agent starts, an idle snapshot
does not replace `agent_settled`, so retries and compaction can finish.

RPC input and output use binary IO with explicit UTF-8 message encoding and
reply decoding. Unicode delivery does not depend on `LANG` or `LC_ALL`.
After completion, stdout drain and process exit have a five-second limit.
An early process exit, rejected request, or shutdown timeout fails the run.
On error or cancellation, the runner closes stdin and stops only its child
PID, with bounded TERM and KILL waits. Managed cancellation also stops the
owned process group.

Pi 0.84.4 is the validated baseline. Later versions must keep `get_state`,
`prompt`, `agent_settled`, native session resume, and EOF shutdown. Older
versions that emit only `agent_end` are not supported by this runner.

RPC was selected over `@file` because Pi's file reader wraps text in file
tags and removes a leading byte-order mark. RPC preserves the message text
and needs no prompt file or crash cleanup.

Run `bundle exec ruby -r ./test/support/push_safety.rb test/pi_rpc_transport_test.rb`
for real child-process checks of prompt bytes, argv/environment visibility,
large input, resume, correction, cancellation, early pipe closure, and logs.
