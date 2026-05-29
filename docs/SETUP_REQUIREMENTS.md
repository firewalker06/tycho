# Setup Script Requirements

This document is the dependency checklist for Tycho's `bin/setup` script. The
script separates dependencies that are required to install and boot Tycho from
optional integrations that enable specific features.

## Baseline Requirements

| Dependency | Required for | Setup behavior |
|------------|--------------|----------------|
| Ruby 3.2+ | Running `tycho`, `tycho serve`, tests, and all app code | Hard fail if missing or older than 3.2 |
| Bundler | Installing gems from `Gemfile` | Hard fail if missing; install or print the exact install command |
| Go | Building Charm Ruby native gems (`bubbletea`, `lipgloss`, `glamour`) when a prebuilt platform gem is unavailable | Hard fail before `bundle install` unless the setup script intentionally relies on prebuilt gems |
| Native build tools | Compiling Ruby native extensions and Go c-archives when needed | Hard fail for source installs; on macOS this usually means Xcode Command Line Tools |

The direct Ruby gems are declared in `Gemfile` and `hq.gemspec`: `bubbles`,
`bubbletea`, `dry-cli`, `glamour`, `lipgloss`, `logger`, `net-http`,
`rqrcode`, `uri`, `web-push`, and `yaml`.

`bubbletea`, `lipgloss`, and `glamour` are Ruby wrappers around Charm Go
libraries. Their gems include native extensions and Go source. `bubbles` is a
Ruby component layer that depends on `bubbletea` and `lipgloss`. Go is an
install/build dependency, not a Tycho runtime subprocess dependency.

## Optional Runtime Integrations

| Dependency | Used by | Current failure behavior | Setup behavior |
|------------|---------|--------------------------|----------------|
| `git` | Project metadata: branch, commit SHA, dirty file count | Soft fail. Tycho checks for `.git`, redirects Git stderr to `/dev/null`, and falls back to `n/a` / clean-looking values | Warn if missing; do not block basic TUI usage |
| `mise` | Detached Kamal actions through `mise exec` | Feature failure. Tycho looks at `TYCHO_MISE_BIN`, common install paths, then `mise` on `PATH`; missing `mise` breaks deploy/maintenance/live actions | Warn by default; hard fail only for an app-deployment profile |
| `kamal` | Deploy, maintenance, and live actions | Feature failure. Tycho prefers project `bin/kamal`, then `bundle exec kamal` inside the project | Warn if no usable project Kamal command is found for app projects |
| `codex` | Built-in Codex managed-agent harness | Soft feature fail. Agent start records a failed run if the executable is missing | Warn if missing; hard fail only for a Codex-agent profile |
| `claude` | Built-in Claude managed-agent harness | Soft feature fail. Agent start records a failed run if the executable is missing | Warn if missing; hard fail only for a Claude-agent profile |
| Custom Claude-compatible harnesses | Project-specific managed-agent execution | Soft feature fail. Tycho checks the configured executable before starting the agent | Validate configured command and warn with the harness key |
| `tailscale` | Remote UI auto-bind, MagicDNS URL, HTTPS Serve detection, terminal QR URL | Soft fail. Missing or stopped Tailscale returns `nil`; `tycho serve` falls back to localhost | Warn only when remote/tailnet access is requested |
| `osascript` | macOS terminal automation for Ghostty, iTerm, and Apple Terminal command launches | Soft fail. Tycho logs AppleScript failures and keeps the TUI running | Check only on macOS; warn if absent or if terminal automation is requested |
| `open` | macOS fallback for opening a terminal app at a project directory | Soft fail. Process spawn errors are logged | Check only on macOS; warn if absent |
| `wezterm` | WezTerm split-pane launch for interactive agent terminals | Soft fail. Process spawn errors are logged | Warn only when `TERM_PROGRAM=WezTerm` or user selects WezTerm support |

## Network Capabilities

| Capability | Used by | Setup behavior |
|------------|---------|----------------|
| RubyGems access | `bundle install` and latest `kamal` / `rails` version lookup | Hard fail for first install if gems are unavailable; latest-version lookup can remain best effort |
| App health URLs | HEAD checks for configured projects | Do not preflight globally; projects can be offline |
| Web Push endpoints | Browser push notifications through `web-push` | Optional; warn only when push notifications are enabled |
| HTTPS secure context | Browser push notifications from non-localhost Remote UI origins | Warn when Remote UI is exposed over non-local HTTP; Tailscale Serve HTTPS is preferred |

## Environment Overrides

The setup script should respect the same executable overrides that Tycho uses:

| Variable | Purpose |
|----------|---------|
| `TYCHO_HOME` | Override default `~/.tycho` root |
| `TYCHO_CONFIG_DIR` | Override default user config directory |
| `TYCHO_CONFIG_PATH` | Override project registry path |
| `TYCHO_SYSTEM_PROMPTS_PATH` | Override system prompt template path |
| `TYCHO_SCHEDULES_PATH` | Override scheduled-agent config path |
| `TYCHO_SCHEDULES_ROOT` | Override schedule message file root |
| `TYCHO_HOOKS_PATH` | Override global hooks config path |
| `TYCHO_SCHEDULES_STATE_PATH` | Override scheduler runtime state path |
| `TYCHO_SCHEDULER_DAEMON_PATH` | Override scheduler daemon heartbeat path |
| `TYCHO_MISE_BIN` | Override `mise` executable |
| `TYCHO_CODEX_BIN` | Override Codex executable |
| `TYCHO_CLAUDE_BIN` | Override Claude executable |
| `TYCHO_TAILSCALE_BIN` | Override Tailscale executable |
| `TYCHO_LOGS_ROOT` | Override runtime logs directory |
| `TYCHO_REMOTE_TOKEN` | Protect non-loopback Remote UI/API access |
| `TYCHO_LOG_LEVEL` | Override log verbosity |
| `TYCHO_WEB_PUSH_VAPID_PUBLIC_KEY` / `TYCHO_WEB_PUSH_VAPID_PRIVATE_KEY` | Provide browser push VAPID keys |
| `TYCHO_WEB_PUSH_VAPID_SUBJECT` | Configure browser push VAPID subject |

## Setup Script

Run the default setup:

```bash
bin/setup
```

Run checks without installing gems or creating config files:

```bash
bin/setup --check
```

Escalate optional tools to hard requirements for specific feature profiles:

```bash
bin/setup --profile app
bin/setup --profile codex --profile claude
bin/setup --profile all
```

## Setup Phases

1. Check baseline tools: Ruby, Bundler, Go, and native build tools.
2. Create `~/.tycho/logs`, `~/.tycho/schedules`, and missing sample config files:
   - `config/hq.yml.example` to `~/.tycho/config/hq.yml`
   - `config/system_prompts.yml.example` to `~/.tycho/config/system_prompts.yml`
   - `config/schedules.yml.example` to `~/.tycho/config/schedules.yml`
   - `config/hooks.example.yml` to `~/.tycho/config/hooks.yml`
3. Check optional CLIs and print a feature readiness summary.
4. For app projects, validate whether `mise` and a Kamal command are available.
5. For managed-agent projects, validate the selected built-in or custom harness.
6. For Remote UI setup, check `TYCHO_REMOTE_TOKEN` when binding outside loopback and
   check Tailscale/HTTPS readiness when phone or push-notification use is requested.
7. Run `bundle install` only when hard requirements and requested profiles pass.
8. Run `tycho doctor` as a post-install smoke check so native extension
   compatibility issues, including the Intel macOS Lipgloss backend, fail
   during setup instead of at first TUI launch.

## Hard-Fail Policy

The setup script should hard fail only when Tycho cannot be installed or the user
explicitly requested a feature profile whose toolchain is missing.

Recommended hard failures:

- Ruby is missing or older than 3.2.
- Bundler is missing and cannot be installed.
- Go or native build tools are missing for a source install that must compile
  Charm Ruby native extensions.
- `bundle install` fails.
- A requested profile cannot run, such as app deployment without `mise`/Kamal or
  a Codex-only setup without a Codex executable.

Recommended soft failures:

- Git is missing.
- Tailscale is missing or stopped.
- `osascript`, `open`, or `wezterm` terminal automation is unavailable.
- Codex, Claude, or custom harnesses are missing when the user did not request
  that agent profile.
- Browser push prerequisites are missing.

Soft failures should be reported as feature warnings with the affected Tycho
surface area and the command or setting needed to fix them.
