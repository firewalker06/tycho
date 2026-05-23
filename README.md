# Tycho

Tycho is a local-first terminal dashboard for monitoring Kamal-deployed
projects and supervising managed coding agents.

<p align="center">
  <img src="docs/assets/tycho-hero.jpg" alt="Tycho terminal dashboard and remote agent control interface" width="100%">
</p>

It combines a Bubbletea/Lipgloss TUI, detached Kamal actions, persistent agent
logs, and an optional lightweight Remote UI for checking agent state from a
browser on your local network or tailnet.

## Status

Tycho is early open-source software. It is designed around a single-operator
workflow and is currently macOS-first, with Linux expected to work where the
same Ruby and CLI dependencies are available.

## Features

- Project registry from `~/.tycho/config/hq.yml`.
- Concurrent HEAD-based health checks for Kamal apps.
- Detached Kamal deploy, maintenance, and live actions.
- Managed Codex, Claude, and custom Claude-compatible agents with persistent chat memory.
- Scheduled managed-agent runs from cron-style local config.
- In-app log views, agent detail views, project detail views, and omnisearch.
- Local JSON API and mobile Remote UI through `tycho serve`.
- Optional Tailscale MagicDNS URL and terminal QR code for Remote UI access.
- Optional browser push notifications for agent completions and inquiries.

## Requirements

- Homebrew for the packaged macOS install.
- Ruby 3.2 or newer for source installs.
- Bundler for source installs.
- Go, when Charm Ruby native gems need to be compiled during install.
- Optional: `mise`, `kamal`, `tailscale`, `codex`, and `claude`.

Tycho can run without every optional tool, but features backed by missing tools
will show as unavailable.

See [docs/SETUP_REQUIREMENTS.md](docs/SETUP_REQUIREMENTS.md) for the
dependency checklist and hard/soft failure policy used by `bin/setup`.

## Installation

### Homebrew

Homebrew is the primary install path for users:

```bash
brew tap firewalker06/tycho
brew install tycho
tycho
```

The formula installs one executable, `tycho`. Remote Sessions and scheduled
agents run through subcommands:

```bash
tycho serve
tycho schedule daemon
```

Optional integrations are intentionally not installed by the formula. Install
and configure `mise`, `kamal`, `tailscale`, `codex`, `claude`, or custom
Claude-compatible harnesses only for the features you use.

### Source Checkout

Use a source checkout when contributing or when Homebrew is not suitable.

One-line setup:

```bash
curl -fsSL https://raw.githubusercontent.com/firewalker06/tycho/main/setup.sh | bash
cd tycho
bin/tycho
```

Pass setup options after `bash -s --`:

```bash
curl -fsSL https://raw.githubusercontent.com/firewalker06/tycho/main/setup.sh | bash -s -- --profile codex
```

Set `TYCHO_DIR` to clone into a different directory, or `TYCHO_REPO_URL` to use
another Git remote.

Manual source setup:

```bash
git clone https://github.com/firewalker06/tycho.git tycho
cd tycho
bin/setup
bin/tycho
```

`bin/setup` installs gems, creates missing user config files from examples
under `~/.tycho`, and prints hard failures plus soft feature warnings for
optional tools. Use `bin/setup --check` to inspect readiness without changing
files, or pass feature profiles such as `bin/setup --profile app`,
`bin/setup --profile codex`, or `bin/setup --profile claude` to make those
optional tools mandatory.

Run through Bundler if your shell has conflicting gem versions:

```bash
bundle exec bin/tycho
```

Command mapping for source users:

| Homebrew command | Source checkout command |
|------------------|-------------------------|
| `tycho` | `bin/tycho` |
| `tycho serve` | `bin/tycho serve` |
| `tycho schedule daemon` | `bin/tycho schedule daemon` |

## Configuration

Project definitions live in `~/.tycho/config/hq.yml` by default.

```yaml
projects:
  - key: my-app
    name: My App
    group: Personal
    path: /Users/you/Code/my-app
    apps: true
    agent: codex
```

System prompt templates live beside the project registry as
`system_prompts.yml`.

Real config files, `.env`, runtime logs, and generated agent artifacts are
gitignored. Keep secrets and machine-specific paths out of committed files.
Runtime state and logs default to `~/.tycho/logs`.

### Where Tycho Writes Files

Homebrew and source installs use the same user-scoped defaults:

| Purpose | Default |
|---------|---------|
| Project registry | `~/.tycho/config/hq.yml` |
| System prompts | `~/.tycho/config/system_prompts.yml` |
| Schedules | `~/.tycho/config/schedules.yml` |
| Schedule prompt files | `~/.tycho/schedules/` |
| Hooks | `~/.tycho/config/hooks.yml` |
| Runtime state and logs | `~/.tycho/logs/` |
| Project logs | `~/.tycho/logs/projects/` |
| Agent logs and artifacts | `~/.tycho/logs/agents/` |
| Browser push state | `~/.tycho/logs/push_*.json` and `~/.tycho/logs/web_push_vapid.json` |

Tycho does not write runtime files under the Homebrew Cellar. Set the
`TYCHO_*` environment variables below to move config or state for tests,
temporary runs, or multi-profile setups.

### Environment Variables

Use the `TYCHO_` prefix for runtime overrides.

| Variable | Purpose |
|----------|---------|
| `TYCHO_HOME` | Override the default `~/.tycho` root. |
| `TYCHO_CONFIG_DIR` | Override the default user config directory. |
| `TYCHO_CONFIG_PATH` | Override the project registry path. |
| `TYCHO_SYSTEM_PROMPTS_PATH` | Override the system prompt template path. |
| `TYCHO_SCHEDULES_PATH` | Override scheduled-agent config path. |
| `TYCHO_SCHEDULES_ROOT` | Override schedule message file root. |
| `TYCHO_HOOKS_PATH` | Override global hooks config path. |
| `TYCHO_LOGS_ROOT` | Override runtime state and logs root. |
| `TYCHO_SCHEDULES_STATE_PATH` | Override scheduler runtime state path. |
| `TYCHO_SCHEDULER_DAEMON_PATH` | Override scheduler daemon heartbeat path. |
| `TYCHO_MISE_BIN` | Override `mise` executable lookup. |
| `TYCHO_CODEX_BIN` | Override Codex executable lookup. |
| `TYCHO_CLAUDE_BIN` | Override Claude executable lookup. |
| `TYCHO_TAILSCALE_BIN` | Override Tailscale executable lookup. |
| `TYCHO_REMOTE_TOKEN` | Require bearer auth for non-local Remote UI/API access. |
| `TYCHO_LOG_LEVEL` | Set Tycho's log level, such as `DEBUG` or `INFO`. |

Web Push can also use `TYCHO_WEB_PUSH_VAPID_PUBLIC_KEY`,
`TYCHO_WEB_PUSH_VAPID_PRIVATE_KEY`, and `TYCHO_WEB_PUSH_VAPID_SUBJECT`.

## Commands

Homebrew users run `tycho`. Source checkout users can replace `tycho` with
`bin/tycho` in the examples below.

Open the TUI:

```bash
tycho
```

Run app commands:

```bash
tycho app list
tycho app status <project-key>
tycho app deploy <project-key>
tycho app maintenance <project-key>
tycho app live <project-key>
```

Start the Remote Sessions server:

```bash
tycho serve
```

Bind explicitly to localhost:

```bash
tycho serve --host 127.0.0.1 --port 7373
```

Run scheduled agents:

```bash
tycho schedule list
tycho schedule daemon --once --dry-run
tycho schedule daemon
```

Manage schedules without opening the TUI:

```bash
tycho schedule validate
tycho schedule list
tycho schedule run <schedule-key>
tycho schedule pause <schedule-key>
tycho schedule resume <schedule-key>
tycho schedule reload
```

The TUI includes a Schedules screen, and the Remote UI `Now` view shows
scheduler daemon freshness plus schedules that are paused, failed, stale, due,
or skipped because of an interactive user conversation. The Remote UI keeps the
schedule card compact by showing daemon status, PID, and last tick in the
header, while schedule rows show project, next run, and a humanized cron
cadence such as `every 15 minutes`.

## Scheduled Agents

Schedules create fresh managed agents for projects. They do not run shell
commands directly, do not model project actions as first-class schedule targets,
and do not resume old agent sessions. This keeps recurring work reviewable and
prevents stale context from accumulating across runs.

Definitions live in `~/.tycho/config/schedules.yml`, which is local and gitignored.
Long prompts should live as Markdown files under `~/.tycho/schedules/`.

```yaml
schedules:
  - key: pull-request-review
    name: Pull request review
    enabled: true
    cron: "*/15 * * * *"
    timezone: local
    target:
      type: agent
      project_key: my-app
      name: Pull request review
      message_source: file
      message_file: schedules/pull-request-review.md
    policy:
      overlap: skip
      missed: run_once_on_start
      archive_previous_agent: true
```

Use `message_source: inline` with `message: "..."` for short prompts. Use
`message_source: file` and `message_file: schedules/<name>.md` for anything
longer than a few lines. Tycho validates cron syntax, project references, and
that prompt files stay inside `~/.tycho/schedules/`.

Each run automatically appends Tycho's final-output attachment checklist to the
scheduled prompt, so reports, Markdown files, PRs, reviews, images, and other
durable artifacts should be returned in `attachments`.

Prompt tips for reliable schedules:

- Make the task idempotent. Tell the agent to check current state first and
  skip work that is already done.
- Give the agent stable dedupe keys, such as PR URL, issue number, date bucket,
  or output path.
- Prefer deterministic output locations like `tmp/<schedule-key>/...`, and say
  whether files should be overwritten, updated in place, or left untouched.
- Require explicit skip conditions. For example: skip a PR that was already
  reviewed after its latest commit, or skip a report that already exists for
  the current date.
- Separate review from mutation. For risky workflows, ask the agent to write a
  review file or plan first and wait for human approval before posting,
  deploying, deleting, merging, or sending messages.
- Keep prompts narrow. A scheduled agent should have one recurring job, one
  project, and a clear completion condition.
- Include a no-op result. Tell the agent what to output when there is no work,
  such as `No new PRs to review.`
- Mention artifact expectations. If the run creates or references durable
  output, name the expected files or links so they appear in `attachments`.

If you converse with a scheduled agent, Tycho protects that session. A later
due run skips with reason `interactive` instead of archiving the user-touched
agent. Archive that agent manually when you want the recurring schedule to
continue with a fresh session.

`tycho schedule daemon` writes daemon heartbeat state to `~/.tycho/logs/scheduler_daemon.json`.
The schedule UI treats a missing or stale heartbeat as daemon attention. If it
finds a running scheduler process without heartbeat state, it reports the
daemon as `untracked`; restart `tycho schedule daemon` to restore tick freshness.

## TUI Tutorial

Start the TUI:

```bash
tycho
```

### Create A Project

1. Press `2` to switch to the Projects screen.
2. Press `N` to open the New Project form.
3. Enter the local project path first. Tycho will offer path suggestions and can
   prefill the project key/name as you tab through the form.
4. Fill in the project key, name, and group.
5. Use left/right arrows on the Agent field to choose the default harness
   (`codex`, `claude`, or a configured custom harness).
6. Tab to `Create Project` and press Enter.

Tycho writes the project entry to `~/.tycho/config/hq.yml`, selects the new
project, and starts a metadata refresh.

### Create A Project Agent

1. Stay on the Projects screen and select the project with `j`/`k`.
2. Press `n` to open the Create Agent form for that project.
3. Use left/right arrows to choose the prompt template and harness.
4. Fill in the agent name and prompt. Use Shift+Enter, Alt+Enter, or `ctrl+j`
   for new lines inside the prompt.
5. Choose `Create Agent` to save the agent without starting it, or choose
   `Create and Run Agent` to start it immediately.

After creation, Tycho switches to the Agents screen, selects the new agent, and
opens its chat panel.

### Converse With An Agent

1. Press `1` to switch to the Agents screen.
2. Select an agent with `j`/`k`.
3. Press `c` or Enter to open the agent chat panel.
4. Type your message. Use Shift+Enter, Alt+Enter, or `ctrl+j` for multiline
   prompts.
5. Press Enter or `ctrl+s` to send. If the agent is idle, Tycho starts it
   automatically.

While in chat, use Tab/Shift+Tab to move between the prompt, conversation, and
summary areas. `L` opens the selected agent's raw log from the Agents screen,
and `ctrl+t` opens an interactive terminal session for the selected agent.

## Remote UI Security

`tycho serve` is local-first. If `TYCHO_REMOTE_TOKEN` is unset, API requests are
accepted without authentication. This is intended only for localhost.

Set a token before binding to Tailscale or any non-loopback address:

```bash
TYCHO_REMOTE_TOKEN="$(ruby -rsecurerandom -e 'puts SecureRandom.hex(24)')" tycho serve
```

When Tailscale HTTPS Serve is available, Tycho can print an HTTPS MagicDNS
Remote UI URL and QR code. Public screenshots should redact MagicDNS URLs,
Tailscale IPs, and QR codes.

## Custom Claude Harnesses

Tycho has built-in `codex` and `claude` harnesses. To run Claude through a
wrapper, define a custom harness in `~/.tycho/config/hq.yml` and use its key as
a project or template agent:

```yaml
custom_harnesses:
  - key: claude-wrapper
    adapter: claude
    execution_command: /Users/you/bin/claude-wrapper

projects:
  - key: my-app
    name: My App
    group: Personal
    path: /Users/you/Code/my-app
    apps: true
    agent: claude-wrapper
```

`execution_command` may be a shell string or an argv list. The command must be
Claude-compatible because Tycho appends Claude CLI flags for stream-json output,
structured result schemas, and native session resume.

Use `TYCHO_CODEX_BIN`, `TYCHO_CLAUDE_BIN`, or another documented environment
override when a harness executable is not on `PATH`.

## Tests

Run the main test suite:

```bash
bin/test
```

Run an individual test:

```bash
bundle exec ruby test/rendering_test.rb
```

## Known Limitations

- Tycho is macOS-first for the initial Homebrew release.
- Linux is expected to work where Ruby, native build tools, and optional CLIs
  are available, but it is not the primary packaged target yet.
- Remote UI is local-first. Set `TYCHO_REMOTE_TOKEN` before binding to a
  non-loopback interface.
- Tycho does not install `mise`, `kamal`, `codex`, `claude`, `tailscale`, or
  custom harness dependencies.
- Managed agents can run powerful local tools. Review prompts, project paths,
  and sandbox settings before starting agents.

## Documentation

- `docs/PROJECT_STATUS.md`: current roadmap and architectural decisions.
- `docs/REMOTE_SERVER.md`: Remote Sessions API and Remote UI behavior.
- `docs/SCHEDULED_RUNS.md`: scheduled-agent design, policies, and runtime state.
- `docs/GOTCHAS.md`: operational pitfalls.
- `docs/OPEN_SOURCE_PLAN.md`: open-source readiness plan and launch criteria.

## Contributing

See `CONTRIBUTING.md` and `CODE_OF_CONDUCT.md`.

## Security

See `SECURITY.md`.

## License

Tycho is released under the MIT License. See `LICENSE`.
