# Pi Coding Agent

Tycho's built-in Pi harness targets the documented
`@mariozechner/pi-coding-agent` 0.73.1 command and event contract. See
[setup requirements](SETUP_REQUIREMENTS.md) for dependency profiles and
readiness checks.

## Install and Authenticate

Install Tycho's supported Pi version:

```bash
npm install -g --ignore-scripts @mariozechner/pi-coding-agent@0.73.1
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
