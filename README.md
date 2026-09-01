# Tycho

Tycho is a local-first control center for supervising coding-agent sessions
across projects. It gives a solo developer or technical lead one place to
start agents, answer follow-up questions, inspect logs and results, and run
recurring work. Use it in the terminal or through its optional Remote UI.

![Tycho terminal dashboard and remote agent control interface](docs/assets/tycho-hero.jpg)

Tycho currently supports Codex, Claude, OpenCode, Pi, and custom
Claude-compatible harnesses. It keeps each agent's conversation, status, and
artifacts under your local `~/.tycho` directory.

Tycho is early, single-operator software. Homebrew installs target macOS;
source installs also work in Linux-style environments and Windows 11 through
WSL when Ruby and the selected agent CLIs are available.

## Install

Homebrew is the primary install path:

```bash
brew tap firewalker06/tycho
brew install tycho
tycho
```

To run from source, install Ruby 3.2+, Bundler, Go, and native build tools,
then run:

```bash
git clone https://github.com/firewalker06/tycho.git tycho
cd tycho
bin/setup
bin/tycho
```

`bin/setup --check` reports missing requirements without changing files. See
[setup requirements](docs/SETUP_REQUIREMENTS.md) for dependency profiles,
optional integrations, and environment overrides.

## Configure

Tycho stores project definitions in `~/.tycho/config/hq.yml`. A minimal project
looks like this:

```yaml
projects:
  - key: my-workspace
    name: My Workspace
    group: Personal
    path: /Users/you/Code/my-workspace
    agent: codex
```

You can also create projects from the TUI or the command line:

```bash
tycho project my-workspace --path ~/Code/my-workspace --harness codex
```

The complete annotated configuration is in
[`config/hq.yml.example`](config/hq.yml.example). Schedules, prompt templates,
hooks, and response style use separate files under `~/.tycho/config`.

Tycho launches agent CLIs with access to the selected project. Review project
paths, prompts, and sandbox settings before starting an agent. Pi has
[no native sandbox equivalent](docs/PI_CODING_AGENT.md#sandbox-behavior).
Do not commit your Tycho config, `.env`, logs, transcripts, or generated agent
artifacts; they may contain local paths, source context, or credentials. See
the [security policy](SECURITY.md).

## Run

Open the TUI:

```bash
tycho
```

Restart the terminal UI with `tycho restart`.

For a Homebrew installation, `tycho update` upgrades Tycho and restarts any
running local Remote server and scheduler daemon with the stable launcher. It
reports a no-op when either service is absent; source checkouts update through
Git instead.

To run your first agent:

1. Press `2` and select the project with `j`/`k`.
2. Press `n`, enter a name and prompt, then choose **Create and Run Agent**.
3. Continue in the open chat. Type a follow-up and press Enter; reopen the chat
   later with `c` or Enter on the selected agent.

Start the browser-based Remote UI:

```bash
tycho serve
```

Without `TYCHO_REMOTE_TOKEN`, the Remote UI and API are safe only on localhost.
Set a token before binding to Tailscale or any other non-loopback address:

```bash
TYCHO_REMOTE_TOKEN="$(ruby -rsecurerandom -e 'puts SecureRandom.hex(24)')" \
  tycho serve
```

See [Remote Sessions](docs/REMOTE_SERVER.md) for binding, Tailscale, daemon,
multiserver, authentication, and API details.

Run scheduled agents:

```bash
tycho schedule list
tycho schedule daemon
```

See [Scheduled Runs](docs/SCHEDULED_RUNS.md) for schedule configuration and
runtime policies. Run `tycho --help` for the full command list.

Source-checkout users can replace `tycho` with `bin/tycho` in these examples.

## Documentation

- [Setup requirements](docs/SETUP_REQUIREMENTS.md) — dependencies, setup
  profiles, paths, and environment overrides.
- [Remote Sessions](docs/REMOTE_SERVER.md) — Remote UI, API, authentication,
  Tailscale, and multiserver operation.
- [Scheduled Runs](docs/SCHEDULED_RUNS.md) — recurring agent configuration and
  policies.
- [Agent memory](docs/AGENT_MEMORY.md) and
  [delegation](docs/AGENT_DELEGATION.md) — session persistence and managed-agent
  ownership.
- [Hooks](docs/HOOKS.md), [skills](docs/TYCHO_SKILLS.md), and
  [usage metrics](docs/USAGE_METRICS.md) — optional operator workflows.
- [Pull request diffs](docs/PULL_REQUEST_DIFFS.md) — review workflow and GitHub
  integration boundaries.
- [Gotchas](docs/GOTCHAS.md) — known operational pitfalls.
- [Project status](docs/PROJECT_STATUS.md) — roadmap and architectural
  decisions.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). Run `bin/test` before opening a pull
request.

Tycho is released under the [MIT License](LICENSE).
