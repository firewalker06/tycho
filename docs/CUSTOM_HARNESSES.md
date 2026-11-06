# Custom harness profiles

Tycho can run a local wrapper or gateway through one of its five supported
native harness families: `codex`, `claude`, `opencode`, `pi`, or `agy`. A profile is
an executable prefix, not a new protocol. Tycho owns the command flags,
stream parser, native-session resume, structured-result handling, metrics,
catalog probing, permissions, readiness, and skill installation for the
declared adapter.

```yaml
custom_harnesses:
  - key: company-codex
    adapter: codex
    execution_command:
      - env
      - COMPANY_GATEWAY=work
      - HOME/bin/company-codex
      - --profile
      - work
```

Use the profile key in a project, template, CLI command, or Remote UI agent
form just as you would use `codex` or another built-in harness.

## Contract

`adapter` is a closed list: `codex`, `claude`, `opencode`, `pi`, and `agy`. Tycho
rejects any other value while loading configuration. There are deliberately no
user-configurable parser, flag, resume, or output templates. A wrapper must be
compatible with the selected adapter's native CLI and event protocol:

| Adapter | Tycho invokes | Wrapper must preserve |
| --- | --- | --- |
| `codex` | `exec` / `exec resume`, JSON output, schema output | Codex JSON events and thread IDs |
| `claude` | `--print --output-format stream-json --verbose` | Claude stream-JSON events and session IDs |
| `opencode` | `run --format json`, prompt on stdin | OpenCode text stdin, JSON events, and session IDs |
| `pi` | `--mode rpc`, prompt on stdin | Pi JSONL RPC, session state, and `agent_settled` |

Tycho adds each family’s model, reasoning, sandbox or permission, workspace,
structured-output, and resume arguments after `execution_command`. Codex,
Claude, agy, OpenCode, and Pi receive prompts through stdin. OpenCode
1.19.3 is the tested baseline; its `run` command reads a pipe with no positional
message. Custom wrappers must keep this behavior, including native resume.
Pi uses the RPC contract described in
[Pi Coding Agent](PI_CODING_AGENT.md). A profile must accept the native arguments in the same order
and emit the native event format. If a provider needs different flags or a
different wire format, implement that translation inside its wrapper rather
than adding a Tycho-specific adapter template.

The old Claude-compatible configuration remains valid without changes:

```yaml
custom_harnesses:
  - key: claude-wrapper
    adapter: claude
    execution_command: HOME/bin/claude-wrapper
```

## Version 1 prompt transport

A profile can set an explicit managed prompt transport:

```yaml
custom_harnesses:
  - key: private-wrapper
    adapter: claude
    execution_command: HOME/bin/private-wrapper
    prompt_transport:
      version: 1
      mode: file
```

The setting must have exactly two keys: integer `version: 1` and `mode`.
The supported modes are `argv`, `stdin`, and `file`. Unknown versions,
unknown modes, extra keys, null, and shorthand strings cause a configuration
error that names the profile. Interactive terminal sessions and catalog
probes keep their existing adapter contract.

| Mode | Managed wrapper input | Limits |
| --- | --- | --- |
| `argv` | Exact prompt in the final argument; stdin is closed | Process tools can read the prompt. OS argument limits apply. |
| `stdin` | Exact prompt bytes on stdin, followed by EOF | No prompt text in argv or environment. Read to EOF without trimming. |
| `file` | Final arguments `--tycho-prompt-file PATH`; stdin is closed | Read the file as binary. The path is an argument; the prompt text is not. |

Tycho still supplies native adapter flags, model settings, schema settings,
and session resume arguments. Codex keeps its `--` separator and uses
`-` only for stdin mode. For Pi, an explicit transport selects
`--mode json` and bypasses the native RPC bridge. The wrapper must emit
Pi JSON events, including the session event, and translate its selected input
to the provider. Other wrappers must also translate their selected transport
if their native CLI does not support it. In particular, the file option is a
Tycho wrapper contract, not a native provider file-attachment option.
Claude and agy keep print mode and their output flags; agy also keeps
`--input-format text`.

File mode uses the shared stdin seam to send bytes to a small runner.
The runner creates an exclusive file with mode `0600` in a new private
directory with mode `0700`. The file stays available for reading by the wrapper
until that child exits. Tycho removes the file and directory after success,
failure, a failed child launch, or handled TERM, INT, and HUP cancellation.
On cancellation it stops only its owned child PID. SIGKILL, a host crash,
or power loss can prevent cleanup. An operator can remove a remaining
`tycho-custom-prompt-*` directory from the system temporary directory after
checking that its run has stopped. Files are never reused across attempts.

Each new run, resume, and structured-output correction uses the same selected
mode. Correction configuration and stdin/file prompts pass through the shared
UTF-8 runner on stdin, including under `LANG=C`. The wrapper must preserve
multiline text, Unicode, trailing newlines, and empty input. Stdin and file
mode support prompts above 1 MB. Argv mode cannot promise this because OS
limits also include the environment. Tycho keeps the exact prompt in its raw
log and canonical transcript. Saved command descriptions redact argv prompt
text and do not contain stdin/file prompt text.

### Migration

Omit `prompt_transport` to keep the current adapter behavior without changes:
Codex, Claude, agy, and OpenCode use native text stdin; Pi uses native stdin
RPC. There is no automatic switch to argv. Existing profiles need no edit.

For an older wrapper that requires a final prompt argument, explicitly select
version 1 `argv`. To remove prompt text from process arguments, update that
wrapper to read raw stdin or the file option, then select the matching mode.
Do not put prompt text or prompt-bearing runner configuration in environment
variables.

## Environment and security

An `execution_command` may start with `env KEY=value ...`. Tycho removes that
prefix from the executable argv and gives the assignments only to the child
process and its catalog probes. A prefix `PATH` is also used to resolve a bare
wrapper command. It clears inherited Ruby/Bundler loader state;
an explicitly declared wrapper assignment remains authoritative for compatible
wrappers. Tycho's server-only `TYCHO_GITHUB_TOKEN` and `TYCHO_REMOTE_TOKEN` are
always removed at the harness boundary, even if a profile declares them.

Configuration is readable local data. Do not put credentials in
`execution_command`; have the wrapper obtain credentials from its normal local
keychain, credential helper, or provider configuration instead. Remote Settings
redacts values in an `env` prefix when it shows the configured command.

## Operator surfaces

Profiles appear with their adapter in TUI and Remote UI harness pickers and
Remote Settings readiness. The setup script validates the configured wrapper
and treats it as the declared adapter when a matching setup profile is
requested. Model and effort suggestions use that adapter’s catalog protocol;
Claude-compatible profiles retain Tycho's stable Claude defaults.

Remote Settings lists one skill row per profile. Installing a skill for a
profile targets the declared adapter's standard root, so `company-codex` uses
the Codex root and `company-pi` uses the Pi root. Multiple profiles for the
same adapter intentionally share that one installation.

## Compatibility limits

Profiles are for compatible executable substitutions, gateways, and wrappers;
they do not make every external agent CLI interchangeable. Adapter-specific
semantics remain native: Codex's schema flags, Claude's stream JSON, OpenCode's
variant and permission model, and Pi's tool allowlist and structured-result
correction behavior. Keep the profile adapter aligned with the protocol the
wrapper actually implements.

Codex profiles use the same versioned OpenAI list-price estimator as the
built-in Codex harness. A gateway may qualify an OpenAI model with the
`openai.` prefix, for example `openai.gpt-5.6-sol`; Tycho preserves that
configured name for attribution and records the canonical OpenAI model used by
the price table in the pricing metadata. A model without a recorded OpenAI
price remains unpriced with an explicit reason instead of being treated as
zero.
