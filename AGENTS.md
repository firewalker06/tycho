# Repository Guidelines

## Project Structure & Module Organization

`bin/tycho` is the executable and boots through `HQ::CLI` in `lib/hq/cli.rb`. Keep the main Bubbletea model and screen-level update flow in `lib/hq/app.rb`, config loading in `lib/hq/registry.rb`, terminal input shims in `lib/hq/bubbletea_input.rb`, domain and process-management logic under `lib/hq/domain/`, form/composer components under `lib/hq/ui/components/`, and rendering split between the aggregator in `lib/hq/ui/rendering.rb` and focused modules under `lib/hq/ui/rendering/`.


Project definitions live in `HOME/.tycho/config/hq.yml`, system prompt templates live in `HOME/.tycho/config/system_prompts.yml`, and the global response style lives in `HOME/.tycho/config/response_style.md`. Managed agents use `HOME/.tycho/config/schemas/agent_result.json`. Project status, key decisions, and roadmap live in `docs/PROJECT_STATUS.md`; update it when durable priorities, milestones, or architectural decisions change. Research and workflow notes live under `docs/`, including `docs/GOTCHAS.md`, `docs/REMOTE_SERVER.md`, `docs/research/charm-ruby.md`, `docs/research/codex-json-schema-research.md`, and `docs/research/claude-json-schema-research.md`.

Runtime artifacts are written to `HOME/.tycho/logs/`, including app state files such as `managed_agents.json`, application logs in `hq.log`, project logs under `HOME/.tycho/logs/projects/{project}/`, archived project logs under `HOME/.tycho/logs/projects/archived/`, and per-agent logs/status/result files under `HOME/.tycho/logs/agents/`. Keep automated checks under `test/`; the existing rendering regression coverage lives in `test/rendering_test.rb`.

## Build, Test, and Development Commands

The **Interaction Profiler** is optional verification when adding or changing a UI interaction. Profiler runs and its Chrome smoke check are not required for every change or CI run and are not part of the local CI signoff. See [the process guide](docs/REMOTE_UI_INTERACTION_PROFILER.md). Lightweight profiler configuration/report-code checks remain in `bin/test`.

- Load `bin/remote-ui-interaction-probe.js` as a Chrome DevTools Snippet to measure click-to-label and request timings. See `docs/REMOTE_UI_INTERACTION_PROBE.md` for the runnable Console commands and timing limits.
- `bin/remote-ui-interaction-report --url URL --schedule KEY --output path/to/temp/tycho-schedule-report.html`: click one Resume control and save a standalone HTML timing report with embedded screenshots. Requires Chrome and Playwright; see `docs/REMOTE_UI_INTERACTION_PROBE.md` for setup, token handling, and exit codes.
- `bin/remote-ui-interaction-report --config config/interaction-tests/schedule-resume.json --output path/to/temp/tycho-schedule-report.html`: run configurable open/click/fill/expand/wait/measure steps and save an HTML report with screenshots. See `docs/REMOTE_UI_INTERACTION_PROBE.md` for the JSON format.
- `node test/browser/interaction_report_smoke.js`: run the optional configurable interaction runner checks against a temporary local page. Set `TYCHO_PLAYWRIGHT_PATH` if needed and `TYCHO_REMOTE_UI_CAPTURE_DIR` to keep the sample reports and preview outside the repository.

- `bundle install`: install Ruby gems declared for Ruby 4.0.9+.
- `bin/tycho`: start the TUI locally.
- `bin/tycho agent-runner <agent-key> -- <harness command...>`: internal entry point. It is hidden from normal help and dispatches before Bundler, HQ, or gems load. Managed agents call it with `ruby --disable-gems`; do not use it as a user command.
- `bundle exec bin/tycho`: run through Bundler when debugging gem resolution issues.
- `bin/tycho harness list [--harness KEY] [--model MODEL] [--discover] [--json]`: list shared built-in and configured custom model/reasoning catalogs; offline by default, with optional Settings-style local tool discovery. See `docs/HARNESS_INVENTORY.md` for source and default limits.
- `bin/tycho --version`: print the Tycho version from the current checkout or installation.
- `bundle exec bin/tycho serve [--host 127.0.0.1] [--port 7373]`: start the local Remote Sessions JSON API and web UI for managed-agent control.
- `bundle exec bin/tycho project create <key> [options]` and `project list|show|update|archive`: manage project configuration from the CLI.
- `bin/tycho schedule archive SCHEDULE_KEY [--server KEY] [--json]`: archive a stopped schedule while retaining configuration and history. Use `bin/tycho schedule list --include-archived` to inspect archived schedules.
- `bundle exec bin/tycho schedule [list|daemon --once|daemon --dry-run]`: list schedules, run the scheduled-agent daemon, or run a single scheduler tick.
- `bundle exec bin/tycho metrics query [filters] [--json]`: query normalized run/native-session usage metrics. `metrics backfill` is deprecated and no longer mutates data.
- `bundle exec bin/tycho queue-work complete <agent-key> <batch-id> --dispositions-json JSON`: record durable source-appropriate outcomes for an open queue-work batch.
- `bin/tycho queue-work cleanup-migrations [--apply]`: report obsolete empty migration audit receipts as JSON; explicit local apply removes at most 1,000 receipts and retains 100 eligible receipts. See [retention policy](docs/QUEUE_MIGRATION_RETENTION.md).
- `bin/test`: run the public CI-equivalent Ruby syntax and regression suite. See [fixture and prerequisite rules](docs/TEST_FIXTURES.md) for isolation and optional integrations.
- `TYCHO_TEST_INSTALLED_PI=1 bundle exec ruby -r ./test/support/push_safety.rb test/pi_rpc_transport_test.rb`: opt in to the offline installed Pi check; normal tests use synthetic harnesses.
- `bundle exec ruby -r ./test/support/push_safety.rb test/agy_harness_test.rb`: check the experimental native agy adapter without contacting a provider. See `docs/AGY.md` for isolated live verification and safety limits.
- `bin/remote-ui-smoke`: start a throwaway Remote UI server with temp config/log roots, create fixture agents, and run Chrome/Playwright smoke checks; set `TYCHO_REMOTE_UI_WORKSPACE_ONLY=1` for the focused workspace flow, `TYCHO_REMOTE_UI_DELEGATION_ONLY=1` for delegated-report rendering, `TYCHO_REMOTE_UI_SUMMARY_ATTACHMENTS_ONLY=1` for Summary attachment behavior, `TYCHO_REMOTE_UI_ATTACHMENT_DOWNLOAD_ONLY=1` for original-filename download behavior, `TYCHO_REMOTE_UI_QUICK_AGENTS_PRIORITY_ONLY=1` for quick-agent response-needed ordering, or `TYCHO_REMOTE_UI_PR_DIFF_MANAGEMENT_ONLY=1` for the server-backed zero-PR add/remove flow, and optionally set `TYCHO_REMOTE_UI_CAPTURE_DIR=path/to/temp/tycho-remote-ui-captures` to save evidence outside the repository.
- Set `TYCHO_REMOTE_UI_CONVERSATION_SPACING_ONLY=1` with `bin/remote-ui-smoke` for actual DOM spacing, activity invariants, desktop/mobile overflow, and composer end clearance. Use `TYCHO_REMOTE_UI_CAPTURE_DIR` to retain evidence outside the repository.
- Set `TYCHO_REMOTE_UI_CONVERSATION_ANIMATION_ONLY=1` with `bin/remote-ui-smoke` for FRED state transitions, animation timing across polling, reduced motion, and desktop/mobile conversation clearance. Use `TYCHO_REMOTE_UI_CAPTURE_DIR` to save screenshots and animation frames outside the repository.
- Set `TYCHO_REMOTE_UI_OPTIMISTIC_CREATE_ONLY=1` with `bin/remote-ui-smoke` for immediate Conversation loading, create/run semantics, retry after failure or lost response, pre-receipt archive history and warnings, both Quick actions and exact receipt replay, polling, navigation, and desktop/mobile layout. Use `TYCHO_REMOTE_UI_CAPTURE_DIR` to retain evidence outside the repository.
- Set `TYCHO_REMOTE_UI_OPTIMISTIC_ARCHIVE_ONLY=1` with `bin/remote-ui-smoke` for immediate agent removal while a single archive request is pending, plus restore and error display when it fails.
- Set `TYCHO_REMOTE_UI_ATTACHMENT_PREVIEW_ONLY=1` with `bin/remote-ui-smoke` for third-column attachment previews, secure renderers, selection lifecycle, keyboard focus, and wide/normal/mobile layout checks. Use `TYCHO_REMOTE_UI_CAPTURE_DIR` to save evidence outside the repository.
- Set `TYCHO_REMOTE_UI_QUICK_OPTIONS_ONLY=1` with `bin/remote-ui-smoke` for local-first Quick opening, separate option readiness, peer selection, stale replies, retained drafts, permissions, and one local fake-harness run while peer reads wait. Set `TYCHO_REMOTE_UI_CAPTURE_DIR` to retain evidence outside the repository.
- Set `TYCHO_REMOTE_UI_AUTO_NAME_ONLY=1` with `bin/remote-ui-smoke` for Quick Agent visible current-project summary, collapsed selector/Name controls, persisted Settings defaults, alphabetical choices, explicit overrides, first-run auto-naming, blur-free overlay, polling, and desktop/mobile layout. Set `TYCHO_REMOTE_UI_CAPTURE_DIR` to retain screenshots outside the repository.
- Set `TYCHO_REMOTE_UI_DELEGATED_SUMMARY_ONLY=1` with `bin/remote-ui-smoke` for persisted per-run delegated actions in Conversation and full Summary, target links, replay, polling, historical summaries, and desktop/mobile layout. Use `TYCHO_REMOTE_UI_CAPTURE_DIR` for evidence outside the repository.
- Set `TYCHO_REMOTE_UI_CLAUDE_COST_ONLY=1` with `bin/remote-ui-smoke` for Claude resumed-run cost, saved Summary preservation, reload, polling, and desktop/mobile layout. Use `TYCHO_REMOTE_UI_CAPTURE_DIR` to retain evidence outside the repository.
- Set `TYCHO_REMOTE_UI_SUMMARY_IDLE_STOP_ONLY=1` with `bin/remote-ui-smoke` for persisted idle-stop Summary reasons, legacy marker recovery, secret exclusion, cold reload, polling, and desktop/mobile layout. Set `TYCHO_REMOTE_UI_CAPTURE_DIR` to save evidence outside the repository.
- Set `TYCHO_REMOTE_UI_MARKDOWN_FRONTMATTER_ONLY=1` with `bin/remote-ui-smoke` for the real Chrome check of safe Markdown frontmatter, rejected source visibility, Markdown body semantics, and HTML sanitization.
- Set `TYCHO_REMOTE_UI_SETTINGS_ONLY=1` with `bin/remote-ui-smoke` for Settings section navigation, mobile navigation clearance, readiness disclosures, warning states, polling preservation, tool counts, and synthetic legacy-token migration checks.
- Set `TYCHO_REMOTE_UI_QUEUE_CONTROLS_ONLY=1` with `bin/remote-ui-smoke` for blocked-queue selection, process/remove, concurrency, polling, keyboard, and responsive-layout regressions.
- Set `TYCHO_REMOTE_UI_NOTIFICATION_ONLY=1` with `bin/remote-ui-smoke` for durable queue-failure notification targets, read state, missing-target fallback, and desktop/mobile layout regressions.
- Set `TYCHO_REMOTE_UI_CLICK_TRACE_ONLY=1` with `bin/remote-ui-smoke` for isolated actual-worker/page click diagnostics, retained encoded-ID lookup, delayed/error Conversation loads, persisted redacted export, and desktop/mobile controls. This uses a synthetic callback without OS activation or push permission. Set `TYCHO_REMOTE_UI_CAPTURE_DIR` to keep evidence outside the repository.
- Set `TYCHO_REMOTE_UI_SCHEDULE_REPLACEMENT_MODE=fresh|handoff|unscheduled-fresh|unscheduled-handoff` with `bin/remote-ui-smoke` for real Chrome checks that context-pressure actions preserve scheduled replacement behavior and ordinary unscheduled cloning; use `TYCHO_REMOTE_UI_CAPTURE_DIR` to retain before/after evidence outside the repository.
- Set `TYCHO_REMOTE_UI_SMOKE_RENDERING_ONLY=1` with `bin/remote-ui-smoke` for focused real-Chrome rendering checks, including the self-hosted UI font, fallback rendering, desktop/mobile overflow, and synthetic Summary screenshots; use `TYCHO_REMOTE_UI_CAPTURE_DIR` to retain evidence outside the repository.
- Set `TYCHO_REMOTE_UI_ACTIVE_WINDOW_ONLY=1` with `bin/remote-ui-smoke` for visible and focused polling lifecycle checks, cold attachment/PR/project-diff routes, inactive startup, actual route-endpoint failure and automatic recovery, error backoff, in-flight completion, manual recovery, and desktop/mobile draft preservation. Set `TYCHO_REMOTE_UI_CAPTURE_DIR` to retain screenshots and request evidence outside the repository.
- Set `TYCHO_REMOTE_UI_BUTTON_BORDERS_ONLY=1` with `bin/remote-ui-smoke` for desktop/mobile Dark, Light (Nord), and System checks of Back, Summary action menus, Summary/PR Diffs shortcuts, keyboard focus, touch, polling, and the preserved Stop border. Use `TYCHO_REMOTE_UI_CAPTURE_DIR` for evidence outside the repository.
- `bin/generate-light-logos`: reproduce Light logo PNGs from the original assets with ImageMagick, without resampling; see `docs/REMOTE_UI_APPEARANCE.md`.
- Set `TYCHO_REMOTE_UI_LOGO_ONLY=1` with `bin/remote-ui-smoke` for logo pixel preservation, first paint, header/loading/onboarding, theme changes, and desktop/mobile checks. Use `TYCHO_REMOTE_UI_CAPTURE_DIR` for evidence outside the repository.
- `bin/remote-ui-profile [--output PATH] [--trace PATH] [--screenshots DIR] [--archive DIR]`: run the optional deterministic Chrome performance suite across every Remote UI route; see `docs/REMOTE_UI_PROFILING.md`. This is intentionally not part of normal CI.
- Set `TYCHO_REMOTE_UI_SCHEDULE_SAVE_ONLY=1` with `bin/remote-ui-smoke` to check the Schedules page, desktop/mobile navigation and Settings access, schedule controls, and one reconciliation after schedule create/edit/file-message saves, normalized values, failed writes/reads, record/body changes and deletions, message read/write response ordering, stale saves preserving current readers, drafts, polling, and desktop/mobile Dark/Nord Light. Use `TYCHO_REMOTE_UI_CAPTURE_DIR` for evidence outside the repository.
- Set `TYCHO_REMOTE_UI_MERMAID_ONLY=1` with `bin/remote-ui-smoke` for real Chrome checks of Mermaid themes, ELK state layout, source controls, security, accessibility, and desktop/mobile layout. Set `TYCHO_REMOTE_UI_CAPTURE_DIR` to save screenshots outside the repository.
- Set `TYCHO_REMOTE_UI_APPEARANCE_ONLY=1` with `bin/remote-ui-smoke` for Light/Dark/System selection, pre-paint persistence, cross-tab and OS changes, draft preservation, and desktop/mobile conversation and inquiry states. Set `TYCHO_REMOTE_UI_CAPTURE_DIR` to retain evidence outside the repository.
- `bin/remote-ui-queue-read-fixture`: start an isolated Remote UI acceptance fixture with one queued user prompt and one delegated reply; run the printed queue command to transition from visible pending state to the expandable **Read queue** Conversation block.
- `bin/remote-ui-inquiry-dismiss-fixture`: start an isolated 600-agent inquiry fixture on a free localhost port and print a generated Interaction Profiler config. See `docs/REMOTE_UI_INTERACTION_PROFILER.md` for sampling and reset steps.
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

Managed agents are configured from project settings in `HOME/.tycho/config/hq.yml`, with prompt templates loaded from `HOME/.tycho/config/system_prompts.yml`. Tycho appends the current `HOME/.tycho/config/response_style.md` policy to cold and resumed execution prompts; project/template `response_style` may override it or disable it with `false`. Codex agents use JSON output and `HOME/.tycho/config/schemas/agent_result.json`; Claude and custom Claude-compatible harnesses use `--output-format stream-json`; OpenCode and Pi use their native JSON event modes. Use `TYCHO_CODEX_BIN`, `TYCHO_CLAUDE_BIN`, `TYCHO_OPENCODE_BIN`, `TYCHO_PI_BIN`, and `TYCHO_AGY_BIN` to override built-in agent executables. Pi support assumes `@mariozechner/pi-coding-agent` 0.73.1's documented CLI/event contract. Claude stdin transport is supported from Claude Code 2.1.312, the installed version validated with real `claude --help`; later compatible versions must keep print-mode stdin, resume, JSON-schema output, and stream-json output. agy stdin transport is supported from agy 1.5.1, the release validated with real `agy --version` and `agy --help`; later compatible releases must keep print-mode `--input-format text`, stdin prompt input, conversation resume, JSON Schema output, and stream-json output. Custom Claude-compatible wrappers belong in `custom_harnesses` with `adapter: claude` and an `execution_command`; provider-specific details should live in that wrapper or command configuration, not in HQ. Native Claude/Codex/OpenCode/Pi/agy `session_id` values are persisted on managed agents and reused after the first run; HQ still treats `memory.jsonl` as the canonical transcript and replays its complete promptable history when no native session is known. Command builders declare an adapter-owned prompt transport (argv or stdin). Preserve exact prompt bytes, raw logs, and canonical transcript for each transport; redact saved command descriptions. Codex uses stdin with `exec -` or `exec resume ID -`; Claude uses print-mode text stdin for new runs and resume, with `stream-json` output; agy uses `--print --input-format text` and stdin for new runs and resume, with `stream-json` output. Pi and OpenCode retain argv until explicitly migrated. Never put prompt-bearing runner configuration in the environment. Preserve structured inquiry submission and focus-aware chat behavior when changing agent flows.

Delegation uses an explicit trusted parent declaration. CLI callers pass `--parent-agent KEY`; Remote API callers pass `parent_agent_key`. A message without a parent key enters Takeover, while a message with the recorded parent key preserves or restores Delegation. `TYCHO_AGENT_KEY` is an informational helper only and never causes implicit parent inference. Preserve server-local topology validation, ownership generations, run stamps, callback deduplication, and ancestor-prompt rejection when changing lifecycle paths.

Managed harnesses inherit the Tycho process environment except for Ruby/Bundler loader state and server-only credentials. Keep `TYCHO_GITHUB_TOKEN` and `TYCHO_REMOTE_TOKEN` removed at the harness spawn boundary. Remote CLI operations use the configured Remote credential store; never expose the server bearer token in prompts, logs, results, or attachments.

Remote Sessions run through `bin/tycho serve` and expose a local JSON API plus lightweight web UI for managed-agent operations. When Tailscale is available, `bin/tycho serve` auto-binds to the machine's Tailscale IPv4 address, prints the MagicDNS URL, and emits a compact terminal QR code for the UI. Keep it local-first, reuse `AgentStore`/`ManagedAgent` behavior instead of duplicating agent state transitions, and keep active-agent state persisted through `HOME/.tycho/logs/managed_agents.json`.

When working on `/ui` Remote UI behavior, verify browser-visible behavior in an actual browser engine, especially polling, sticky/fixed panels, form preservation, toggles, and mobile viewport layout. Prefer the Browser plugin when it is available. If the Browser plugin's control tool is unavailable, use a local Playwright + Google Chrome fallback against a throwaway `bin/tycho serve` instance with temp `TYCHO_CONFIG_PATH`, `TYCHO_SYSTEM_PROMPTS_PATH`, and `TYCHO_LOGS_ROOT` so verification does not touch real HQ agents, logs, or project config.

`HQ::CLI` enables Bubbletea bracketed paste, and `lib/hq/bubbletea_input.rb` patches `Bubbletea::Program#poll_event` with a Ruby-side input queue so multi-byte terminal reads are not truncated. Text inputs and text areas normalize multi-rune paste through `lib/hq/ui/components/text_paste.rb`. Preserve this path when changing Bubbletea startup, chat composer, inquiry forms, or agent editor input handling; pasted paths such as `lib/hq/ui/components/chat_composer.rb` should arrive intact.

## Working with Charm Ruby

Follows guidance in `docs/research/charm-ruby.md`. Use Bubbletea for TUI structure, Lipgloss for styling, and Bubbles for components like the Spinner. Keep the Elm Architecture in mind: `init` sets up initial state and commands, `update(message)` handles events and returns new state + commands, and `view` renders the current state.

When adding new UI elements, consider how they fit into the existing layout and style. Reuse the shared color/style helpers in `lib/hq/ui/rendering/styles.rb`, keep table columns aligned across Agents and Projects screens, and preserve the compact path rendering and focus-aware chat/inquiry flows that the rendering tests cover.

For input components, keep paste handling compatible with Bubbles `TextInput` and `TextArea`. Multi-character paste should insert as text, not trigger global shortcuts one character at a time.

## Testing Guidelines

This repository now has lightweight automated coverage under `test/`. Every change should at minimum pass `bin/test` and a manual run of `bin/tycho` when TUI behavior is affected.

### Required local CI signoff

Read and follow [docs/LOCAL_CI.md](docs/LOCAL_CI.md); it is the canonical runbook. For every final pushed PR head, run `bin/test`, publish `signoff/tycho-bin-test` with pinned `gh-signoff` **v0.4.1** against that exact published SHA, and verify the status. If tests fail, publish the documented failure status for that SHA. After any new commit, push it and repeat the full sequence. Implementation or review is not complete while this required status is missing or stale.

Validate the affected key paths in the UI, especially grouped project rows, table alignment, detail views, sidebar log inspection, agent create/edit flows, agent chat and structured inquiry submission, refresh, and the `g` shortcut that opens the selected project in a terminal.

For Remote UI `/ui` changes, run `bundle exec ruby test/remote_server_test.rb` and do browser verification for user-visible behavior. A safe fallback pattern is to start `bin/tycho serve` on a spare localhost port with temp env vars (`TYCHO_CONFIG_PATH`, `TYCHO_SYSTEM_PROMPTS_PATH`, `TYCHO_LOGS_ROOT`), create fixture data through the JSON API, then drive `http://127.0.0.1:{port}/ui` with Playwright + local Google Chrome. Check concrete browser facts such as focused form values surviving `refresh({ force: true })`, details toggles preserving state across polling, mutually exclusive panels closing as expected, and sticky/fixed docks staying pinned inside the viewport.

When touching terminal input or text components, include paste regression coverage in `test/rendering_test.rb`; the existing tests cover both raw and bracketed paste for `lib/hq/ui/components/chat_composer.rb`.

When adding tests, keep using simple Ruby test files under `test/` with `*_test.rb` names unless the repo adopts a broader framework later.

## Commit & Pull Request Guidelines

Recent commits use short, imperative subjects such as `Fix table column alignment across screens` and `Add custom Claude harness support`. Keep commit messages in that style and scope each commit to one logical change.

Pull requests should include a brief summary, manual verification steps, and screenshots or terminal captures for visible TUI changes. Link related issues when applicable and note any changes to `HOME/.tycho/config/hq.yml`, `HOME/.tycho/config/system_prompts.yml`, structured agent schemas, hardcoded project paths, logs, or external dependencies such as Codex, Claude, or Bedrock-backed Claude execution.

Also call out changes to Bubbletea input handling, bracketed paste behavior, or Bubbles text components because they affect chat, inquiry, and agent editor typing flows.

- Set `TYCHO_REMOTE_UI_SESSION_ID_COPY_ONLY=1` with `bin/remote-ui-smoke` to check canonical Tycho Session ID copying, duplicate titles, clipboard errors, and desktop/mobile appearance modes. Set `TYCHO_REMOTE_UI_CAPTURE_DIR` to retain evidence outside the repository.

- Set `TYCHO_REMOTE_UI_ATTACHMENT_FILTER_ONLY=1` with `bin/remote-ui-smoke` to check attachment flyout and navigation type filters, counts, reset, updates, duplicate targets, unknown types, empty results, focus, polling, and desktop/mobile Dark, Light, and System views. Use `TYCHO_REMOTE_UI_CAPTURE_DIR` for evidence outside the repository. Optional `TYCHO_REMOTE_UI_FILTER_BEFORE_DIR` points to an external directory with baseline `app.js` and `app.css` for before screenshots.

- Set `TYCHO_REMOTE_UI_LINKED_AGENTS_ONLY=1` with `bin/remote-ui-smoke` to check the composer Linked agents flyout, current and archived/disconnected groups, native keyboard/touch disclosure, refresh preservation, action labels, and desktop/mobile Dark/Light/System layout. Use `TYCHO_REMOTE_UI_CAPTURE_DIR` for evidence outside the repository. Set `TYCHO_REMOTE_UI_LINKED_AGENTS_BASELINE` to an outside-repository baseline `app.js` for optional before screenshots.

- Set `TYCHO_REMOTE_UI_DELEGATED_COLLAPSE_ONLY=1` with `bin/remote-ui-smoke` to check logo-menu delegation collapse, nested and peer search, clear-search restoration, keyboard controls, focus across refresh, and desktop/mobile Dark/Light/System layout. Use `TYCHO_REMOTE_UI_CAPTURE_DIR` for evidence outside the repository.

- Set `TYCHO_REMOTE_UI_UTILITY_BORDERS_ONLY=1` with `bin/remote-ui-smoke` to check Agents Sort/Select agents, Settings Copy URL/Host copy, Summary arrows, and PR Full view/external-link borders in desktop/mobile Dark/Nord Light/System. Includes keyboard traversal, disabled arrows, clipboard, polling, and protected action borders. Use `TYCHO_REMOTE_UI_CAPTURE_DIR` for evidence outside the repository.

- Set `TYCHO_REMOTE_UI_COLD_AGENT_LOAD_ONLY=1` with `bin/remote-ui-smoke` to check visible conversation content before held shell responses, auth/setup/error recovery, late summary arrival after detailed Settings, navigation, focus, drafts, scroll, and desktop/mobile layout. Use `TYCHO_REMOTE_UI_CAPTURE_DIR` for evidence outside the repository.
- Add `TYCHO_REMOTE_UI_COLD_LOAD_BENCHMARK=1` to that focused smoke command for five fresh-browser and forced-warm request-chain samples with a controlled 250 ms shell delay. `TYCHO_REMOTE_UI_COLD_LOAD_BASELINE=path/to/path/app.js` selects pinned baseline assets for isolated comparison; the test asserts that the asset was served. Saved output contains endpoint metadata, bytes, and timings only.

- Set `TYCHO_REMOTE_UI_PROMPT_RECEIPT_ONLY=1` with `bin/remote-ui-smoke` to check message acceptance, exact retry after lost/malformed replies, consumed-message replay, ordered sends during held reads, stale read/auth/navigation guards, and desktop/mobile Dark/Light layout. Set `TYCHO_REMOTE_UI_CAPTURE_DIR` to retain synthetic evidence outside the repository.
- Set `TYCHO_REMOTE_UI_USAGE_SCOPE_ONLY=1` with `bin/remote-ui-smoke` to check saved cumulative Summary cost, historical selection, partial/missing values, and desktop/mobile Dark/Nord Light layout. Use `TYCHO_REMOTE_UI_CAPTURE_DIR` for evidence outside the repository.

- Set `TYCHO_REMOTE_UI_INQUIRY_RECEIPT_ONLY=1` with `bin/remote-ui-smoke` to check exact inquiry-answer retry after lost, invalid, empty, mismatched, auth, and unbound conflict responses; correction drafts across reload/navigation, stale-answer cleanup and newer inquiry/file preservation, files/feedback, and desktop/mobile Dark/Nord Light layout. Use `TYCHO_REMOTE_UI_CAPTURE_DIR` for evidence outside the repository.

- Set `TYCHO_REMOTE_UI_INQUIRY_RECEIPT_ONLY=1 TYCHO_REMOTE_UI_INQUIRY_DISPLAY_ONLY=1` with `bin/remote-ui-smoke` to check accepted answer projection, held detail/catalog/shell reads, stale responses, one reconciliation, local and synthetic routed peer targets, navigation, and desktop/mobile Dark/Nord Light. Use `TYCHO_REMOTE_UI_CAPTURE_DIR` for evidence outside the repository. Optional `TYCHO_REMOTE_UI_INQUIRY_DISPLAY_BASELINE=path/to/path/ui.js` serves a pinned full UI bundle (prompt submissions, inquiry submissions, then app) for comparison.

- Set `TYCHO_REMOTE_UI_INQUIRY_RECEIPT_ONLY=1 TYCHO_REMOTE_UI_INQUIRY_DELAYED_ONLY=1` with `bin/remote-ui-smoke` to hold the accepted POST response through later detail, activity, mutation, completion, navigation, and archive updates. Covers desktop/mobile Dark/Nord Light and local/synthetic peer routes. Use `TYCHO_REMOTE_UI_CAPTURE_DIR` outside the repository. Optional `TYCHO_REMOTE_UI_INQUIRY_DELAYED_CASE=detail|activity|mutation|retire` runs one focused local desktop case.

- Add `TYCHO_REMOTE_UI_INQUIRY_DELAYED_ONLY=1 TYCHO_REMOTE_UI_INQUIRY_DELAYED_CASE=detail TYCHO_REMOTE_UI_INQUIRY_DELAYED_VIEWPORT=desktop|mobile TYCHO_REMOTE_UI_INQUIRY_CONTACT_SHEET=1` with the inquiry receipt smoke flag to capture timed answer-send screenshots at 0, 100, 300, 600, 1000, 2000, and 2500 ms, plus after the response. Set `TYCHO_REMOTE_UI_CAPTURE_DIR` outside the repository to retain the screenshots.

- Set `TYCHO_REMOTE_UI_INQUIRY_CARD_PADDING_ONLY=1` with `bin/remote-ui-smoke` to check inquiry button clearance and failed-answer Retry/Remove controls on desktop split, desktop non-split, and mobile. Set `TYCHO_REMOTE_UI_CAPTURE_DIR` outside the repository to save screenshots.

- Set `TYCHO_REMOTE_UI_QUEUE_RESULT_ONLY=1` with `bin/remote-ui-smoke` to check manual queue process/remove result validation, partial IDs, uncertain recovery, delayed responses, and desktop/mobile Dark/Light controls. Use `TYCHO_REMOTE_UI_CAPTURE_DIR` for evidence outside the repository.

- Set `TYCHO_REMOTE_UI_PROMPT_RECEIPT_ONLY=1 TYCHO_REMOTE_UI_PROMPT_RETRY_ONLY=1` with `bin/remote-ui-smoke` to check message delivery proof, local retry cancellation, late replies, distinct IDs, reload/navigation, and local/synthetic peer routes in desktop/mobile Dark/Nord Light. Set `TYCHO_REMOTE_UI_CAPTURE_DIR` outside the repository for evidence. Optional `TYCHO_REMOTE_UI_PROMPT_RETRY_BASELINE=path/to/path/ui.js` serves a pinned full UI bundle for a before comparison.

- Set `TYCHO_REMOTE_UI_PROMPT_RECEIPT_ONLY=1 TYCHO_REMOTE_UI_PROMPT_CONCURRENCY_ONLY=1` with `bin/remote-ui-smoke` for owned-lane release after proof, late-response ordering, shared two-tab IndexedDB stops, stale writes, dispatch/cancel races, and newer composer draft/file preservation. Set `TYCHO_REMOTE_UI_CAPTURE_DIR` outside the repository. Optional `TYCHO_REMOTE_UI_PROMPT_CONCURRENCY_CASE=lane|tabs` and `TYCHO_REMOTE_UI_PROMPT_OUTBOX_BASELINE=path/to/path/prompt_submissions.js` run focused before comparisons.

- For a focused retry timing check, add `TYCHO_REMOTE_UI_PROMPT_RETRY_CASE=1440:dark:peer:immediate` and optional `TYCHO_REMOTE_UI_PROMPT_RETRY_REPEATS=10` (1–20) to the prompt-retry smoke command. Failure traces retain synthetic IDs, proof timing, and UI state without prompt/file bodies.

- Set `TYCHO_REMOTE_UI_ATTACHMENT_LOAD_ONLY=1` with `bin/remote-ui-smoke` to check attachment reads during a held lifecycle lock, stalled Markdown dependencies, fresh file content, concurrent downloads, synthetic peer routing, and auth retry in desktop/mobile Dark/Nord Light. Set `TYCHO_REMOTE_UI_CAPTURE_DIR` outside the repository for screenshots and browser timing samples. Optional `TYCHO_REMOTE_UI_ATTACHMENT_LOAD_BASELINE=path/to/path/baseline.rb` preloads a test-only lookup baseline into the throwaway server.

- Set `TYCHO_REMOTE_UI_METADATA_LIFECYCLE_ONLY=1` with `bin/remote-ui-smoke` to hold real project detail responses beyond cache freshness, then release them after navigation, blur, hide, or page close. The check counts real Git commands and asserts zero new metadata work and zero follow-up detail requests. It covers desktop and mobile. Set `TYCHO_REMOTE_UI_CAPTURE_DIR` to retain evidence outside the repository.

- Set `TYCHO_REMOTE_UI_SCHEDULE_EMPTY_ONLY=1` with `bin/remote-ui-smoke` to check the first-schedule action, create/delete transitions, loading, connection errors, filtered rows, keyboard use, and desktop/mobile Dark/Light layout. Set `TYCHO_REMOTE_UI_CAPTURE_DIR` outside the repository to retain screenshots.

- Set `TYCHO_REMOTE_UI_MARKDOWN_IMAGES_ONLY=1` with `bin/remote-ui-smoke` to check local Markdown images in plain/rich Summary and attachment detail, workspace-relative and absolute paths, registered images outside the workspace, literal reserved metadata names, literal percent-plus-hex directory/image names distinct from actual hash names, decoded-once references, private-target and safe internal symlinks, authentication and synthetic peer routing, rejected resources, refresh recovery, blob cleanup, and delayed reads on desktop/mobile Dark/Nord Light. Set `TYCHO_REMOTE_UI_CAPTURE_DIR` outside the repository to retain screenshots.

- `bundle exec ruby test/remote_workspace_image_security_test.rb`: verify authenticated image reads for reserved filenames and safe, private-target, and external symlinks with isolated fixture roots.

- Set `TYCHO_REMOTE_UI_MANUAL_SCHEDULE_QUEUE_ONLY=1` with `bin/remote-ui-smoke` to check one-time selected queue delivery for paused and stopped schedules, unchanged schedule state, later automatic suppression, polling, pending-click protection, and desktop/mobile Dark/Light layout. Use `TYCHO_REMOTE_UI_CAPTURE_DIR` outside the repository for screenshots.
