# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview


Use Bubbletea for the TUI structure, Lipgloss for styling, and Bubbles for components like the spinner. Keep the Elm Architecture in mind: `init` sets up initial state and commands, `update(message)` handles events and returns state plus commands, and `view` renders the current state.

## Project Structure

Keep the main Bubbletea model and screen-level update flow in `lib/hq/app.rb`. Keep config loading in `lib/hq/registry.rb`.

Terminal input handling lives in `lib/hq/bubbletea_input.rb`. It patches `Bubbletea::Program#poll_event` with a Ruby-side input queue so multi-byte terminal reads, especially pasted text, are not truncated after the first parsed key.

Domain and process-management code lives under `lib/hq/domain/`:

- `constants.rb` defines log paths and schema paths.
- `project.rb` represents a configured project and handles workspace and git metadata.
- `managed_agent.rb` manages Codex and Claude-compatible agent execution, logs, messages, structured results, and inquiry state.
- `agent_store.rb` persists managed agents.
- `agent_log_parser.rb` parses raw Codex JSON streams and `chat.log` blocks into conversation, system, and chat entries.
- `agent_chat_log.rb` builds chat viewport content from two sources: `memory.jsonl` for historical conversation and `raw.log` for live streaming during active runs. It also generates `conversation.log` and `system.log` as human-readable artifacts.
- `agent_memory.rb` maintains a canonical `*.memory.jsonl` event log per agent, bootstrapping from existing messages and bounding how much history is replayed back into prompts.
- `skill_discovery.rb` enumerates SKILL.md entries from `~/.claude/skills` and workspace `.claude/skills` (Claude-compatible harnesses) or `~/.codex/skills` and workspace `.agents/skills` (Codex), and exposes the correct trigger character (`/` vs `$`).

UI components live under `lib/hq/ui/components/`, including chat composer, inquiry form, agent chat form, agent create/edit form, `option_picker`, `text_paste`, and `skill_picker` (the chat composer opens it inline when the user types the agent's skill trigger). `text_paste` normalizes multi-rune paste events for Bubbles `TextInput` and `TextArea`. Rendering is split between the aggregator in `lib/hq/ui/rendering.rb` and focused modules under `lib/hq/ui/rendering/` for styles, text helpers, layout, status helpers, chat rendering, and views.

Project definitions live in `~/.tycho/config/hq.yml`, system prompt templates live in `~/.tycho/config/system_prompts.yml`, and the global response style lives in `~/.tycho/config/response_style.md`. Structured managed-agent output is described by `~/.tycho/config/schemas/agent_result.json`. Project status, key decisions, and roadmap live in `docs/PROJECT_STATUS.md`; update it when durable priorities, milestones, or architectural decisions change. Operational pitfalls live in `docs/GOTCHAS.md`, and research notes live under `docs/research/`, including Charm Ruby guidance and Codex/Claude JSON schema notes.

Runtime artifacts are written to `~/.tycho/logs/`, including `hq.log` (application log), app state files such as `managed_agents.json`, project logs under `~/.tycho/logs/projects/{project}/`, archived project logs under `~/.tycho/logs/projects/archived/`, and per-agent files under `~/.tycho/logs/agents/`. Each agent run produces: `<key>.raw.log` (raw stdout/JSON stream), `<key>.conversation.log` (user/assistant turns), `<key>.system.log` (tool calls, system events), and `<key>.memory.jsonl` (canonical event log). The TUI chat viewport reads directly from `memory.jsonl` (history) and `raw.log` (live streaming) - there is no intermediate `chat.log` file. Automated rendering checks live in `test/rendering_test.rb`.

`HQ.logger` is a centralized application logger backed by Ruby's stdlib `Logger`, writing to `~/.tycho/logs/hq.log` with daily rotation. It captures app lifecycle events, config loading, process start/stop, and silently-rescued errors. The log level defaults to `INFO` and can be overridden via `TYCHO_LOG_LEVEL` (e.g., `DEBUG`, `WARN`). Rotated log files older than 7 days are cleaned up at startup. Use `HQ.logger.info("Component") { "message" }` with the component name as `progname`.

## Running and Checks

```bash
bundle install
bin/tycho
bundle exec bin/tycho
bin/test
bundle exec ruby -c bin/tycho
bundle exec ruby test/registry_test.rb
bundle exec ruby test/rendering_test.rb
```

Use `bin/tycho` for a local manual run. Use the Bundler form when debugging gem resolution. Every change should at minimum pass `bin/test`, and visible TUI changes should still get a manual run of the TUI.

Use `docs/PROJECT_STATUS.md` as the living project status document for current focus, roadmap, and durable decisions; keep transient implementation notes out of it.

If you introduce new tooling, document the command here and keep it runnable from the repo root.

## Runtime Behavior



The app auto-refreshes every 30 seconds. Agent status is polled every 10 seconds.

Managed agents are configured from project settings in `~/.tycho/config/hq.yml`, with prompt templates loaded from `~/.tycho/config/system_prompts.yml`. Codex agents use JSON output and `~/.tycho/config/schemas/agent_result.json`; Claude and custom Claude-compatible harnesses use `--output-format stream-json` so logs stream incrementally. Use `TYCHO_CODEX_BIN` and `TYCHO_CLAUDE_BIN` to override built-in executables. Custom Claude-compatible wrappers belong in `custom_harnesses` with `adapter: claude` and an `execution_command`; provider-specific details should live in that wrapper or command configuration, not in HQ. Both paths funnel through `AgentLogParser` so the raw stream is demultiplexed into conversation and system entries. `ManagedAgent` persists a native `session_id` for Codex and Claude-compatible harnesses in `~/.tycho/logs/managed_agents.json`: Claude-like agents get a generated `--session-id` on first run and use `--resume` afterward, while Codex captures the first `thread_id` from the JSON stream and then runs `codex exec resume`. Once a native session is known, follow-up runs send only the latest user message instead of replaying the full HQ memory window; without a native session, Tycho replays the complete promptable `memory.jsonl` history. Command builders append prompt text as a harness argument rather than writing it to stdin. This keeps prompt budgets smaller and recovers native prompt-cache reuse, with the tradeoff that Codex resumed runs cannot currently pass `--output-schema` through the resume subcommand. The TUI chat viewport uses a hybrid rendering approach via `AgentChatLog`: historical conversation comes from `memory.jsonl` (user messages, assistant messages, tool summaries from past runs), while live streaming content comes from parsing `raw.log` for the current active run. User messages appear immediately because they are written to `memory.jsonl` on send. When a run finishes, `capture_run_memory!` commits the full assistant messages and tool summaries into `memory.jsonl`, so the conversation history is preserved across the live-to-history transition. `AgentMemory` preserves the canonical `memory.jsonl` across runs; cold prompt composition currently does not cap conversation, tool, or run history. Structured inquiry submission is gated behind a review step - the inquiry form renders inside a rounded box with the question heading and requires confirmation before sending. Keep that review gate and focus-aware chat behavior intact when changing agent flows.

Tycho appends the current `~/.tycho/config/response_style.md` policy to cold and resumed execution prompts. Project/template `response_style` may override it or disable it with `false`.

Log viewing now stays in-app via sidebar panes. Preserve the in-app log/detail/chat/form behavior, and keep the `g` shortcut opening the selected project in a terminal.

HQ exposes a hook system so external scripts can react to agent and config events. Hooks are loaded at boot from `~/.tycho/config/hooks.yml` (global) and per-project `hooks:` keys in `~/.tycho/config/hq.yml`. Ruby handler files in `~/.claude/hq-hooks/*.rb` and `<project_path>/.hq/hooks/*.rb` can register handlers via `HQ::Hooks.on("agent.run.*") { |payload| ... }`. Shell hooks receive the payload as JSON on stdin plus `TYCHO_EVENT`, `TYCHO_PROJECT_KEY`, and `TYCHO_AGENT_KEY` environment variables; the command is never interpolated with payload data. `HQ.hooks.publish(event, payload)` dispatches asynchronously via a background worker thread; `HQ.hooks.publish_blocking(event, payload)` runs blocking hooks synchronously and returns a parsed Hash response (used only for `agent.inquiry.available` in v1). Pattern wildcards: `agent.run.*` matches one segment, `agent.*` matches one-or-more trailing segments, `*` matches any event. SIGHUP reloads hook config without restarting HQ. See `docs/HOOKS.md` for the full event inventory, YAML schema, and payload keys.

`HQ::CLI` runs Bubbletea in alt-screen mode with bracketed paste enabled. Bracketed paste and raw paste both flow through `BubbleteaInput` before reaching app update handlers. Preserve this behavior when changing Bubbletea startup, chat composer, inquiry forms, or agent editor input handling; pasted paths such as `lib/hq/ui/components/chat_composer.rb` should arrive intact rather than only inserting the first character.

## Coding Style

Follow the existing Ruby style across `bin/tycho` and `lib/hq/**/*.rb`: two-space indentation, snake_case for methods and variables, SCREAMING_SNAKE_CASE for constants, and short guard clauses where they simplify flow. Keep classes and modules focused, and prefer small helper methods over deeply nested conditionals.

Preserve the current file-level conventions: `# frozen_string_literal: true`, double-quoted strings, and concise comments only where the code is not obvious. The repo ships a `.rubocop.yml` that pins `Style/StringLiterals` and `Style/StringLiteralsInInterpolation` to `double_quotes` and sets `TargetRubyVersion: 3.4`; do not let autoformatters flip strings to single quotes.


## UI Guidance

Reuse shared color/style helpers in `lib/hq/ui/rendering/styles.rb`, keep table columns aligned across Agents and Projects screens, and preserve compact path rendering plus focus-aware chat/inquiry flows that the rendering tests cover.

When changing visible UI, validate the affected key paths: grouped project rows, table alignment, detail view, sidebar log inspection, agent create/edit flows, agent chat streaming from `memory.jsonl`/`raw.log`, the skill picker invoked from the chat composer, the gated inquiry review step, refresh, and the terminal-opening shortcut.

When changing input components, keep paste behavior compatible with Bubbles `TextInput` and `TextArea`. Multi-character paste should insert as text, not trigger global shortcuts one character at a time.

## Testing Guidelines

Keep automated checks under `test/` with `*_test.rb` names unless the repo adopts a broader framework later. The current lightweight regression coverage lives in `test/registry_test.rb` and `test/rendering_test.rb`.

When touching terminal input or text components, include paste regression coverage in `test/rendering_test.rb`; the existing tests cover both raw and bracketed paste for `lib/hq/ui/components/chat_composer.rb`.

Manual verification should include the affected UI paths and any external dependencies touched by the change, especially Codex execution, Claude-compatible execution, and config or schema changes.

## Commit and Pull Request Guidelines

Recent commits use short, imperative subjects such as `Fix table column alignment across screens` and `Add custom Claude harness support`. Keep commit messages in that style and scope each commit to one logical change.

Pull requests should include a brief summary, manual verification steps, and screenshots or terminal captures for visible TUI changes. Link related issues when applicable and note any changes to `~/.tycho/config/hq.yml`, `~/.tycho/config/system_prompts.yml`, structured agent schemas, hardcoded project paths, logs, or external dependencies such as Codex, Claude, or Bedrock-backed Claude execution.

Also call out changes to Bubbletea input handling, bracketed paste behavior, or Bubbles text components because they affect chat, inquiry, and agent editor typing flows.
