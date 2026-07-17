# HQ Feature Inventory

> Purpose: Design-facing inventory of HQ's current capabilities. Use this as source material for a Remote UI design brief.
>
> Last updated: 2026-05-09

## Product Summary

HQ is a local-first operations cockpit for a developer's projects. It combines:

- A managed-agent workspace for Codex and Claude-compatible sessions.
- A lightweight remote web UI at `/` for inspecting and controlling agents from a browser or phone.
- A small JSON API and CLI command surface for automation.


## Core Objects

### Projects

Projects are configured in `~/.tycho/config/hq.yml` and represent local workspaces for managed agents.

Project data includes:

- Key, name, group, and local path.
- Default managed-agent backend.
- Agent prompt templates loaded from `~/.tycho/config/system_prompts.yml`.
- Optional pull request URL metadata.
- Git metadata: branch, commit hash, dirty-file count, and related GitHub links when a PR URL exists.
- Per-project logs under `~/.tycho/logs/projects/{project}/`.

### Managed Agents

Managed agents are persistent coding-agent sessions associated with a project.

Agent data includes:

- Key, display name, project, template, harness, workspace, prompt, and sandbox mode.
- Runtime state: idle, running, awaiting input, blocked, succeeded, stopped, or failed.
- Process state: PID, start/finish timestamps, exit code, and run count.
- Native Claude/Codex session id for resume.
- Unread state when a background run finishes outside the open chat.
- Summary and structured result from the latest run.
- Skills discovered from the workspace and agent type.
- Logs and transcript artifacts under `~/.tycho/logs/agents/`.

## Main TUI Features

### Navigation Shell

- Two primary screens: Agents and Projects.
- Keyboard navigation with tabs, arrow keys, `j/k`, and direct screen shortcuts.
- Responsive terminal layout with a left list/sidebar and a right detail panel.
- Sidebar can be hidden or shown.
- Full-screen detail overlay for the selected agent or project.
- Footer hints that change by screen and overlay state.
- Startup loading screen with HQ logotype, progress bar, and recent refresh activity.
- Configuration error screen when `~/.tycho/config/hq.yml` cannot be loaded.
- Global refresh and restart flows.
- Quit confirmation.

### Omnisearch

- Opens as a floating fuzzy finder from sidebar focus.
- Searches both agents and projects.
- Empty query prioritizes unread agents.
- Results show type icons, unread indicators, and agent project detail.
- Selecting a result navigates directly to the matching agent or project.

### Project List

- Shows all configured projects grouped by project group.
- Displays project status icons.
- Handles empty state when no projects are configured.
- Keeps selection visible while scrolling long lists.
- Shows a status legend when space allows.

### Project Detail

The selected project detail panel shows:

- Project name, status, group, and key.
- GitHub PR chip when configured.
- Git branch chip.
- Commit hash chip.
- Git clean/dirty indicator.
- Local filesystem links for project path and log directory.
- Available agent templates.
- Managed-agent count for the project.
- Most recent agent summary for the project.
- Contextual project shortcuts.

### Project Metadata Refresh

- Concurrent refresh of project metadata.
- Git metadata and managed-agent counts refresh automatically.
- The app refreshes automatically every 30 seconds.

### Project Creation

- In-app project creation form.
- Fields for path, key, name, group, and default agent backend.
- Path autocomplete for local directories.
- Group autocomplete from existing project groups.
- Key/name prefill from selected path.
- Validation for required fields and existing local path.
- Saves to `~/.tycho/config/hq.yml`.
- Starts asynchronous project metadata refresh after creation.

### Project Archiving

- Confirmation dialog before archiving.
- Blocks archive while related agents are running.
- Moves config from `~/.tycho/config/hq.yml` to `~/.tycho/config/hq.archived.yml`.
- Moves project logs to `~/.tycho/logs/projects/archived/YYYY-MM-DD_project-name/`.
- Archives related managed-agent logs.
- Removes related active agents from the dashboard.

### Agent List

- Shows all managed agents grouped by project.
- Displays status icon, agent name, and unread indicator.
- Handles empty state when no agents exist.
- Keeps selection visible while scrolling long lists.
- Shows a status legend when space allows.

### Agent Detail

The selected agent detail panel shows:

- Agent name and current status.
- Project, template, and harness.
- PR/branch/commit/git-clean chips from the associated project.
- Run metadata: started, finished, elapsed time.
- Result metadata: run count, exit code, and latest result label.
- Latest summary.
- Current prompt.
- Workspace path.
- Native session id.
- Raw log path.
- Sandbox mode.
- Created timestamp.
- Contextual action shortcuts.

### Agent Creation And Editing

- Create an agent from a selected project.
- Edit an idle agent.
- Choose prompt template.
- Choose harness: `codex`, `claude`, or a custom Claude-compatible harness.
- Edit name and prompt.
- Edit workspace on existing agents.
- Create only, or create and immediately run.
- Validation for required name, prompt, and workspace.
- Applies project-context prompt on creation.
- Discovers workspace skills after creation.
- Publishes lifecycle hooks for create/update events.

### Agent Execution

- Start an idle agent.
- Rerun an agent.
- Stop a running agent with `TERM`.
- Poll active agents every 10 seconds.
- Preserve process state and reconcile finished runs after restart.
- Capture exit code and effective status.
- Support native session continuity for Claude/Codex.
- Persist run history with start/finish time, status, command, and log path.
- Mark agents unread when a run completes away from the visible chat.

### Agent Chat

- Open an in-app chat sidebar for a managed agent.
- Show conversation history from canonical `memory.jsonl`.
- Stream live output from raw logs while an agent is running.
- Render user messages, assistant messages, and tool-call blocks.
- Select conversation blocks with keyboard controls.
- Open a selected block in a floating detail view.
- Move previous/next while inside block detail.
- Show compact block count and visible-line diagnostics.
- Show collapsible summary section with full summary detail view.
- Compose multi-line prompts.
- Send a prompt and automatically start the agent if idle.
- Preserve focus-aware chat navigation across conversation, summary, and compose sections.
- Mark an agent read when its chat opens.
- Rebuild memory and summary from raw logs when memory is missing.

### Structured Inquiry Flow

- Detect pending structured inquiries from agent results.
- Replace the normal composer with an inquiry form.
- Support generated fields from requested JSON schema.
- Support picker-style and multi-select answers.
- Use a gated review step before submission.
- Validate required inquiry input.
- Submit the final answer as a user message and start/resume the agent.
- Allow blocking hooks to auto-answer inquiries before requiring human input.

### Skill Picker

- Discovers skills from agent-appropriate locations:
  - Claude-compatible harnesses: `~/.claude/skills` and workspace `.claude/skills`.
  - Codex: `~/.codex/skills`, `~/.agents/skills`, and workspace `.agents/skills`.
- Uses the correct trigger for each harness.
- Opens from an empty composer when the trigger character is typed.
- Filters and autocompletes available skills.

### Logs And Inspection

- In-app sidebar log viewers for:
  - Agent conversation log.
  - Agent raw log.
- Log viewers support scrolling, horizontal panning, reload, and close.
- Log content is UTF-8 normalized and can be tailed/truncated for large files.
- Detail views expose clickable terminal OSC 8 links for local paths where supported.
- Central app logger writes lifecycle and error events to `~/.tycho/logs/hq.log`.

### Terminal Integration

- Open a terminal for the selected project path.
- Open a terminal for the selected agent workspace.
- Open an interactive resumed agent terminal for the selected agent.
- Supports Ghostty split panes.
- Supports WezTerm split panes for explicit commands.
- Supports iTerm and Apple Terminal via AppleScript.
- Falls back to opening the project/workspace path in the configured terminal app.

### Input Reliability

- Bubbletea input is patched with a Ruby-side queue to avoid truncating multi-byte terminal reads.
- Bracketed paste is enabled in the CLI.
- Text inputs and text areas normalize multi-rune paste.
- Chat composer preserves pasted paths and multi-character input.
- Rendering tests cover raw and bracketed paste behavior.

## Remote UI Features

The remote web UI is a lightweight browser surface served by `bin/tycho serve` at `/`.

Current Remote UI capabilities:

- Shows remote connection status.
- Stores optional bearer token in browser local storage.
- Sends bearer token on API requests when configured.
- Lists active managed agents.
- Shows agent count.
- Shows each agent's name, status, project, harness, and latest result.
- Selects an agent to inspect.
- Shows selected agent name, project, template, status, and PID when running.
- Reads and renders the selected agent conversation.
- Renders message, role, kind, and tool-call labels.
- Starts the selected agent.
- Stops the selected agent.
- Sends a prompt to the selected agent.
- Offers a "Start after send" toggle.
- Manual refresh button.
- Auto-refreshes agents and conversation with polling.
- Polls more frequently while selected or any agents are running.
- Slows polling when idle.
- Pauses normal polling while the browser tab is hidden.
- Backs off after network errors.
- Refreshes immediately after start, stop, and send actions.
- Detects `401` and reveals token input.

Current Remote UI constraints:

- It does not create, edit, clone, or archive agents from the current JavaScript UI, although the JSON API supports create/edit/archive.
- It does not expose project creation, project archiving, terminal integration, omnisearch, or structured inquiry forms.
- It uses plain server-served HTML/CSS/JavaScript with no frontend build step.

## Remote Server And JSON API

The remote server is local-first and reuses the same domain objects as the TUI.

Runtime features:

- Starts with `bin/tycho serve`.
- Default URL is `http://127.0.0.1:7373`.
- Optional `--host` and `--port`.
- Optional bearer-token auth via `TYCHO_REMOTE_TOKEN`.
- Tailscale auto-bind when available.
- MagicDNS URL display.
- Compact terminal QR code for the Remote UI URL.
- Graceful shutdown on `INT` and `TERM`.
- Request logs to stdout and `~/.tycho/logs/hq.log`.

API endpoints:

- `GET /agents`.
- `POST /agents`.
- `GET /agents/{key}`.
- `PATCH /agents/{key}` and `PUT /agents/{key}`.
- `DELETE /agents/{key}`.
- `GET /agents/{key}/conversation`.
- `POST /agents/{key}/messages`.
- `POST /agents/{key}/prompt`.
- `POST /agents/{key}/start`.
- `POST /agents/{key}/stop`.
- `POST /agents/{key}/archive`.

## CLI Features

Running `bin/tycho` without a subcommand opens the TUI.

Command surface:

- `bin/tycho --help`.
- `bin/tycho project <project-key> [options]`: create a project using the current directory by default.
- `bin/tycho project create <project-key> [options]`: explicit project creation form.
- `bin/tycho project show <project-key> [--json]`: inspect normalized project configuration and Git metadata.
- `bin/tycho project update <project-key> [options]`: update project defaults, metadata, response style, and visibility.
- `bin/tycho project archive <project-key> [--json]`: archive the project, its managed agents, and their logs after rejecting active runs.
- All project lifecycle commands accept `--json` for automation.


## Hooks And Automation

HQ publishes events to configured shell or Ruby hooks.

Hook features:

- Global hooks in `~/.tycho/config/hooks.yml`.
- Per-project hooks in `~/.tycho/config/hq.yml`.
- Global Ruby handlers under `~/.claude/hq-hooks/`.
- Per-project Ruby handlers under `<project>/.hq/hooks/`.
- Async event dispatch through a background worker.
- Blocking hook support for `agent.inquiry.available`.
- Wildcard event patterns.
- SIGHUP reload for hook config and Ruby handlers.
- Hook stdout/stderr tee to `~/.tycho/logs/hooks.log`.

Important event groups:

- Agent run started, finished, and finalized.
- Agent inquiry available and answered.
- User and assistant messages added.
- Memory captured and native session captured.
- Agent created, updated, cloned, and deleted.
- Config loaded and reloaded.
- Project loaded, added, updated, and archived.

## Persistence And Files

Configuration:

- Active projects: `~/.tycho/config/hq.yml`.
- Archived projects: `~/.tycho/config/hq.archived.yml`.
- Agent prompt templates: `~/.tycho/config/system_prompts.yml`.
- Agent structured result schema: `~/.tycho/config/schemas/agent_result.json`.
- Optional hooks: `~/.tycho/config/hooks.yml`.

Runtime state:

- Managed agents: `~/.tycho/logs/managed_agents.json`.
- App log: `~/.tycho/logs/hq.log`.
- Hook log: `~/.tycho/logs/hooks.log`.
- Project logs: `~/.tycho/logs/projects/{project}/`.
- Archived project logs: `~/.tycho/logs/projects/archived/`.
- Agent raw logs, conversation logs, system logs, memory logs, status files, and result files: `~/.tycho/logs/agents/`.

## Design Brief Notes For Remote UI

The current Remote UI covers only a focused subset of HQ: remote managed-agent control. A fuller web design brief can choose one of these directions:

- Preserve the Remote UI as a mobile companion for agents only.
- Expand the Remote UI into a web equivalent of the TUI's Agents screen.
- Expand the Remote UI into a complete HQ cockpit with Projects, Agents, actions, logs, and health.

High-value design surfaces to consider:

- Agent list with running/blocked/unread state.
- Agent conversation with tool-call grouping and block detail.
- Prompt composer with start-after-send, multi-line input, and pending inquiry state.
- Agent create/edit/archive flows using the existing API.
- Project list and detail states for workspace metadata and agent ownership.
- Mobile-friendly remote access flow for token entry and QR-opened sessions.
- Clear distinction between local-only operations, remote-safe operations, and destructive operations.
