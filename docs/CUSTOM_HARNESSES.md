# Custom harness profiles

Tycho can run a local wrapper or gateway through one of its four supported
native harness families: `codex`, `claude`, `opencode`, or `pi`. A profile is
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
      - /Users/you/bin/company-codex
      - --profile
      - work
```

Use the profile key in a project, template, CLI command, or Remote UI agent
form just as you would use `codex` or another built-in harness.

## Contract

`adapter` is a closed list: `codex`, `claude`, `opencode`, and `pi`. Tycho
rejects any other value while loading configuration. There are deliberately no
user-configurable parser, flag, resume, or output templates. A wrapper must be
compatible with the selected adapter's native CLI and event protocol:

| Adapter | Tycho invokes | Wrapper must preserve |
| --- | --- | --- |
| `codex` | `exec` / `exec resume`, JSON output, schema output | Codex JSON events and thread IDs |
| `claude` | `--print --output-format stream-json --verbose` | Claude stream-JSON events and session IDs |
| `opencode` | `run --format json` | OpenCode JSON events and session IDs |
| `pi` | `--mode json` | Pi JSON events and session IDs |

Tycho adds each family’s model, reasoning, sandbox or permission, workspace,
structured-output, and resume arguments after `execution_command`. It passes
the prompt as that command’s final argument rather than through standard
input. A profile must therefore accept the native arguments in the same order
and emit the native event format. If a provider needs different flags or a
different wire format, implement that translation inside its wrapper rather
than adding a Tycho-specific adapter template.

The old Claude-compatible configuration remains valid without changes:

```yaml
custom_harnesses:
  - key: claude-wrapper
    adapter: claude
    execution_command: /Users/you/bin/claude-wrapper
```

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
