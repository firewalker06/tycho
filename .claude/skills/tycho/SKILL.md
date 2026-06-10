---
name: tycho
description: Manages Tycho-monitored projects and managed agents. Use when the user asks to deploy, check status, manage maintenance mode, create agents, or control schedules for any project.
---

# Tycho CLI Skill

Manage Kamal-deployed projects, managed agents, and scheduled runs via the `tycho` CLI.

## Quick Reference

| Group | Command | Description |
|-------|---------|-------------|
| **app** | `app list` | List projects with Kamal deployment |
| | `app status <project-key>` | Check a project's health and last action |
| | `app deploy <project-key>` | Start a deploy |
| | `app maintenance <project-key>` | Enable maintenance mode |
| | `app live <project-key>` | Resume live traffic |
| **project** | `project update <project-key> --pr-url <url>` | Set / clear open PR URL |
| **agent** | `agent create <project-key> <prompt>` | Create (and optionally run) a managed agent |
| **schedule** | `schedule list` | List all schedules and daemon status |
| | `schedule validate` | Validate schedule config |
| | `schedule run <schedule-key>` | Trigger a schedule immediately |
| | `schedule pause <schedule-key>` | Pause a schedule |
| | `schedule resume <schedule-key>` | Resume a paused schedule |
| | `schedule reload` | Validate config for the next daemon tick |

---

## `tycho agent create`

Create a new managed agent for a project. This is the primary command for programmatically launching coding agents.

```
tycho agent create <project-key> <prompt> [options]
```

### Arguments

| Argument | Required | Description |
|----------|----------|-------------|
| `project-key` | Yes | Key of the target project (see `app list` or `hq.yml`) |
| `prompt` | Yes | Initial system prompt / task description for the agent |

### Options

| Flag | Description |
|------|-------------|
| `--model MODEL` | Model override, e.g. `claude-opus-4-5`, `o4-mini` |
| `--harness HARNESS` | Agent harness, e.g. `claude`, `codex` (defaults to project default) |
| `--name NAME` | Override auto-generated agent name |
| `--template KEY` | Template key to use (defaults to project's first template) |
| `--run` | Start the agent immediately after creation |

### Examples

```bash
# Create an agent (does not start it)
tycho agent create my-project "Refactor the auth module to use JWT"

# Create and start immediately
tycho agent create my-project "Fix failing tests in spec/models" --run

# Use a specific model and harness
tycho agent create global-web "Review open PRs and summarise findings" \
  --harness claude --model claude-opus-4-5 --run

# Use a specific template
tycho agent create fizzy "Write release notes for this sprint" \
  --template release --run
```

### Output

```
Created agent my-project-agent-7
  Name:    My Project custom 7
  Project: my-project
  Harness: claude
  Model:   claude-opus-4-5
  Prompt:  Refactor the auth module to use JWT
  Status:  running (pid 12345)          # only shown with --run
  Log:     ~/.tycho/logs/agents/...     # only shown with --run
```

The agent key (`my-project-agent-7`) can be used to locate logs under `~/.tycho/logs/agents/`.

---

## `tycho app` — Deployment Commands

```bash
# List all Kamal-enabled projects
tycho app list

# Check health, last action, and metadata
tycho app status my-project

# Trigger a deploy (detached, logs to ~/.tycho/logs/projects/my-project/action.log)
tycho app deploy my-project

# Enable maintenance mode
tycho app maintenance my-project

# Resume live traffic
tycho app live my-project
```

Actions run as detached background processes. Check progress via `app status` or the TUI.

---

## `tycho schedule` — Schedule Management

```bash
# Show all schedules and daemon status
tycho schedule list

# Validate config without running
tycho schedule validate

# Fire a schedule right now (ignores cron timing)
tycho schedule run weekly-review

# Pause / resume
tycho schedule pause weekly-review
tycho schedule resume weekly-review

# Signal the daemon to reload config on next tick
tycho schedule reload
```

---

## `tycho project update`

```bash
# Set the open PR URL shown in the TUI
tycho project update my-project --pr-url https://github.com/org/repo/pull/123

# Clear the PR URL
tycho project update my-project --pr-url ""
```

---

## Project Keys

Project keys are defined in `~/.tycho/config/hq.yml`. Use `tycho app list` to see keys for Kamal-enabled projects. Agent-only projects (no Kamal) do not appear in `app list` — read the config directly if needed:

```bash
grep "^- key:" ~/.tycho/config/hq.yml
```

---

## Logs and Artifacts

| Artifact | Path |
|----------|------|
| App log | `~/.tycho/logs/hq.log` |
| Action log | `~/.tycho/logs/projects/<project>/action.log` |
| Agent raw stream | `~/.tycho/logs/agents/<key>.raw.log` |
| Agent conversation | `~/.tycho/logs/agents/<key>.conversation.log` |
| Agent system events | `~/.tycho/logs/agents/<key>.system.log` |
| Managed agents store | `~/.tycho/logs/managed_agents.json` |

---

## Workflow Summary

1. **Find the project key** — `tycho app list` or `grep "^- key:" ~/.tycho/config/hq.yml`
2. **Create the agent** — `tycho agent create <key> "<task>" [--harness claude] [--run]`
3. **Monitor** — tail `~/.tycho/logs/agents/<key>.raw.log`, or open the TUI (`tycho`)
4. **Deploy / maintenance** — `tycho app deploy <key>` / `tycho app maintenance <key>`
