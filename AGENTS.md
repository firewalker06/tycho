# Repository Guidelines

## Project Structure & Module Organization

`bin/tycho` is the executable and boots through `HQ::CLI` in `lib/hq/cli.rb`. Keep the main Bubbletea model and screen-level update flow in `lib/hq/app.rb`, config loading in `lib/hq/registry.rb`, terminal input shims in `lib/hq/bubbletea_input.rb`, domain and process-management logic under `lib/hq/domain/`, form/composer components under `lib/hq/ui/components/`, and rendering split between the aggregator in `lib/hq/ui/rendering.rb` and focused modules under `lib/hq/ui/rendering/`.


Project definitions live in `~/.tycho/config/hq.yml`, system prompt templates live in `~/.tycho/config/system_prompts.yml`, the global response style lives in `~/.tycho/config/response_style.md`, and structured managed-agent output is described by `~/.tycho/config/schemas/agent_result.json`. Project status, key decisions, and roadmap live in `docs/PROJECT_STATUS.md`; update it when durable priorities, milestones, or architectural decisions change. Research and workflow notes live under `docs/`, including `docs/GOTCHAS.md`, `docs/REMOTE_SERVER.md`, `docs/research/charm-ruby.md`, `docs/research/codex-json-schema-research.md`, and `docs/research/claude-json-schema-research.md`.

Runtime artifacts are written to `~/.tycho/logs/`, including app state files such as `managed_agents.json`, application logs in `hq.log`, project logs under `~/.tycho/logs/projects/{project}/`, archived project logs under `~/.tycho/logs/projects/archived/`, and per-agent logs/status/result files under `~/.tycho/logs/agents/`. Keep automated checks under `test/`; the existing rendering regression coverage lives in `test/rendering_test.rb`.

## Build, Test, and Development Commands

- `bundle install`: install Ruby gems declared for Ruby 3.2+.
- `bin/tycho`: start the TUI locally.
- `bundle exec bin/tycho`: run through Bundler when debugging gem resolution issues.
- `bundle exec bin/tycho serve [--host 127.0.0.1] [--port 7373]`: start the local Remote Sessions JSON API and web UI for managed-agent control.
- `bundle exec bin/tycho project <key> [options]` and `project create|show|update|archive`: manage project configuration from the CLI.
- `bundle exec bin/tycho schedule [list|daemon --once|daemon --dry-run]`: list schedules, run the scheduled-agent daemon, or run a single scheduler tick.
- `bundle exec bin/tycho metrics query [filters] [--json]` and `metrics backfill [--timezone ZONE]`: query or idempotently rebuild normalized run/native-session usage metrics.
- `bin/test`: run the public CI-equivalent Ruby syntax and regression suite.
- `bin/remote-ui-smoke`: start a throwaway Remote UI server with temp config/log roots, create a fixture agent, and run a Chrome/Playwright smoke check for composer refresh preservation and mobile dock layout.
- `bin/capture-site-quickstart`: regenerate the v0.10.0 website launch and watch screenshots from deterministic synthetic Remote UI fixtures at 1440x900.
- `bin/capture-site-tui-conversation`: regenerate the v0.10.0 website TUI conversation screenshot from a deterministic synthetic fixture at 1440x900.
- `bundle exec ruby -c bin/tycho`: syntax-check the main executable before opening a PR.
- `bundle exec ruby test/registry_test.rb`: verify registry loading for split config and system prompt interpolation.
- `bundle exec ruby test/parser_test.rb`: verify synthetic Claude parser fixture shapes.
- `bundle exec ruby test/managed_agent_test.rb`: verify managed-agent execution, memory, and structured result behavior.
- `bundle exec ruby test/remote_server_test.rb`: verify Remote Sessions agent create/edit/chat/archive service behavior.
- `bundle exec ruby test/tailscale_test.rb`: verify Tailscale self-status parsing and MagicDNS URL derivation.
- `bundle exec ruby test/terminal_qr_test.rb`: verify compact terminal QR rendering for the Remote UI URL.
- `bundle exec ruby test/rendering_test.rb`: run the rendering and interaction regression checks for the TUI.
- Project status, key decisions, and roadmap are documented in `docs/PROJECT_STATUS.md`.
- Codex and Claude structured output research notes are documented in `docs/research/codex-json-schema-research.md` and `docs/research/claude-json-schema-research.md`.
- Logs, detail views, chat, and agent forms now render in-app, including sidebar views for log inspection.

If you introduce new tooling, document the command here and keep it runnable from the repo root.

## Coding Style & Naming Conventions

Follow the existing Ruby style across `bin/tycho` and `lib/hq/**/*.rb`: two-space indentation, snake_case for methods and variables, SCREAMING_SNAKE_CASE for constants, and short guard clauses where they simplify flow. Keep classes and modules focused, and prefer small helper methods over deeply nested conditionals.


Preserve the current file-level conventions: `# frozen_string_literal: true`, double-quoted strings, and concise comments only where the code is not obvious.

The repo ships a `.rubocop.yml` that pins double-quoted string style and Ruby 3.4. `bundle exec rubocop` is not part of the bundle; if you run RuboCop locally, use the available executable and keep changes scoped to the requested files.

## Runtime Behavior & External Integrations



The app auto-refreshes every 30 seconds. Agent status is polled every 10 seconds.

Managed agents are configured from project settings in `~/.tycho/config/hq.yml`, with prompt templates loaded from `~/.tycho/config/system_prompts.yml`. Tycho appends the current `~/.tycho/config/response_style.md` policy to cold and resumed execution prompts; project/template `response_style` may override it or disable it with `false`. Codex agents use JSON output and `~/.tycho/config/schemas/agent_result.json`; Claude and custom Claude-compatible harnesses use `--output-format stream-json` so logs stream incrementally. Use `TYCHO_CODEX_BIN` and `TYCHO_CLAUDE_BIN` to override built-in agent executables. Custom Claude-compatible wrappers belong in `custom_harnesses` with `adapter: claude` and an `execution_command`; provider-specific details should live in that wrapper or command configuration, not in HQ. Native Claude/Codex `session_id` values are persisted on managed agents and reused with `--resume` after the first run; HQ still treats `memory.jsonl` as the canonical transcript and replays its complete promptable history when no native session is known. Command builders append prompt text as a harness argument rather than writing it to stdin. Preserve structured inquiry submission and focus-aware chat behavior when changing agent flows.

Each managed run receives a signed `TYCHO_AGENT_CAPABILITY` bound to its agent key and run ID. Agent-originated prompt and delegation operations must validate that capability through `AgentStore`/`DelegationCoordinator`; never trust `TYCHO_AGENT_KEY`, `parent_agent_key`, or another caller-supplied actor label as authority. Direct user prompts enter Takeover before delivery, verified parent prompts restore Delegation, and children cannot prompt or delegate to ancestors. Preserve ownership generations and run stamps when changing lifecycle paths.

Remote Sessions run through `bin/tycho serve` and expose a local JSON API plus lightweight web UI for managed-agent operations. When Tailscale is available, `bin/tycho serve` auto-binds to the machine's Tailscale IPv4 address, prints the MagicDNS URL, and emits a compact terminal QR code for the UI. Keep it local-first, reuse `AgentStore`/`ManagedAgent` behavior instead of duplicating agent state transitions, and keep active-agent state persisted through `~/.tycho/logs/managed_agents.json`.

When working on `/ui` Remote UI behavior, verify browser-visible behavior in an actual browser engine, especially polling, sticky/fixed panels, form preservation, toggles, and mobile viewport layout. Prefer the Browser plugin when it is available. If the Browser plugin's control tool is unavailable, use a local Playwright + Google Chrome fallback against a throwaway `bin/tycho serve` instance with temp `TYCHO_CONFIG_PATH`, `TYCHO_SYSTEM_PROMPTS_PATH`, and `TYCHO_LOGS_ROOT` so verification does not touch real HQ agents, logs, or project config.

`HQ::CLI` enables Bubbletea bracketed paste, and `lib/hq/bubbletea_input.rb` patches `Bubbletea::Program#poll_event` with a Ruby-side input queue so multi-byte terminal reads are not truncated. Text inputs and text areas normalize multi-rune paste through `lib/hq/ui/components/text_paste.rb`. Preserve this path when changing Bubbletea startup, chat composer, inquiry forms, or agent editor input handling; pasted paths such as `lib/hq/ui/components/chat_composer.rb` should arrive intact.

## Working with Charm Ruby

Follows guidance in `docs/research/charm-ruby.md`. Use Bubbletea for TUI structure, Lipgloss for styling, and Bubbles for components like the Spinner. Keep the Elm Architecture in mind: `init` sets up initial state and commands, `update(message)` handles events and returns new state + commands, and `view` renders the current state.

When adding new UI elements, consider how they fit into the existing layout and style. Reuse the shared color/style helpers in `lib/hq/ui/rendering/styles.rb`, keep table columns aligned across Agents and Projects screens, and preserve the compact path rendering and focus-aware chat/inquiry flows that the rendering tests cover.

For input components, keep paste handling compatible with Bubbles `TextInput` and `TextArea`. Multi-character paste should insert as text, not trigger global shortcuts one character at a time.

## Testing Guidelines

This repository now has lightweight automated coverage under `test/`. Every change should at minimum pass `bin/test` and a manual run of `bin/tycho` when TUI behavior is affected.

Validate the affected key paths in the UI, especially grouped project rows, table alignment, detail views, sidebar log inspection, agent create/edit flows, agent chat and structured inquiry submission, refresh, and the `g` shortcut that opens the selected project in a terminal.

For Remote UI `/ui` changes, run `bundle exec ruby test/remote_server_test.rb` and do browser verification for user-visible behavior. A safe fallback pattern is to start `bin/tycho serve` on a spare localhost port with temp env vars (`TYCHO_CONFIG_PATH`, `TYCHO_SYSTEM_PROMPTS_PATH`, `TYCHO_LOGS_ROOT`), create fixture data through the JSON API, then drive `http://127.0.0.1:{port}/ui` with Playwright + local Google Chrome. Check concrete browser facts such as focused form values surviving `refresh({ force: true })`, details toggles preserving state across polling, mutually exclusive panels closing as expected, and sticky/fixed docks staying pinned inside the viewport.

When touching terminal input or text components, include paste regression coverage in `test/rendering_test.rb`; the existing tests cover both raw and bracketed paste for `lib/hq/ui/components/chat_composer.rb`.

When adding tests, keep using simple Ruby test files under `test/` with `*_test.rb` names unless the repo adopts a broader framework later.

## Commit & Pull Request Guidelines

Recent commits use short, imperative subjects such as `Fix table column alignment across screens` and `Add custom Claude harness support`. Keep commit messages in that style and scope each commit to one logical change.

Pull requests should include a brief summary, manual verification steps, and screenshots or terminal captures for visible TUI changes. Link related issues when applicable and note any changes to `~/.tycho/config/hq.yml`, `~/.tycho/config/system_prompts.yml`, structured agent schemas, hardcoded project paths, logs, or external dependencies such as Codex, Claude, or Bedrock-backed Claude execution.

Also call out changes to Bubbletea input handling, bracketed paste behavior, or Bubbles text components because they affect chat, inquiry, and agent editor typing flows.
