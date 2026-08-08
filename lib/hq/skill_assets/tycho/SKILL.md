---
name: tycho
description: Manages Tycho-monitored projects and managed agents. Use when the user asks to check status, create/list/run/stop/send/archive/clone agents, or control schedules for any project.
---

# Tycho CLI Skill


## Quick Reference

| Group | Command | Description |
|-------|---------|-------------|
| **project** | `project update <project-key> --pr-url <url>` | Set / clear open PR URL |
| **agent** | `agent create <project-key> <prompt>` | Create (and optionally run) a managed agent |
| | `agent list [<project-key>]` | List agents, optionally filtered by project |
| | `agent status <agent-key>` | Show full status and metadata |
| | `agent run <agent-key>` | Start or re-run an existing agent |
| | `agent stop <agent-key>` | Stop a running agent |
| | `agent logs <agent-key>` | Print agent log |
| | `agent send <agent-key> <message>` | Append a message and re-run the agent |
| | `agent archive <agent-key>` | Archive an agent and move its logs |
| | `agent clone <agent-key>` | Clone an existing agent |
| **schedule** | `schedule list` | List all schedules and daemon status |
| | `schedule validate` | Validate schedule config |
| | `schedule run <schedule-key>` | Trigger a schedule immediately |
| | `schedule pause <schedule-key>` | Pause a schedule |
| | `schedule resume <schedule-key>` | Resume a paused schedule |
| | `schedule reload` | Validate config for the next daemon tick |

---

## `tycho agent create`

Create a new managed agent for a project.

```
tycho agent create <project-key> <prompt> [options]
```

### Options

| Flag | Description |
|------|-------------|
| `--model MODEL` | Model override, e.g. `claude-opus-4-5`, `o4-mini` |
| `--harness HARNESS` | Agent harness, e.g. `claude`, `codex` (defaults to project default) |
| `--name NAME` | Override auto-generated agent name |
| `--template KEY` | Template key (defaults to project's first template) |
| `--run` | Start the agent immediately after creation |

```bash
# Create only
tycho agent create my-project "Refactor the auth module to use JWT"

# Create and start immediately
tycho agent create my-project "Fix failing tests in spec/models" --run

# Specify harness and model
tycho agent create global-web "Review open PRs" --harness claude --model claude-opus-4-5 --run
```

---

## `tycho agent list`

List all managed agents, or filter to one project.

```bash
tycho agent list                  # all agents
tycho agent list my-project       # only agents for my-project
```

Output columns: Key, Project, Name, Harness, Status, Runs.

---

## `tycho agent status`

Full status table for a single agent — pid, model, harness, run count, start/finish times, exit code, workspace, log path.

```bash
tycho agent status my-project-agent-3
```

---

## `tycho agent run`

Start or re-run an existing agent (same as `create --run` but for agents that already exist).

```bash
tycho agent run my-project-agent-3
```

Prints the pid and log path on success.

---

## `tycho agent stop`

Send SIGTERM to a running agent's process group.

```bash
tycho agent stop my-project-agent-3
```

Errors if the agent is not currently running.

---

## `tycho agent logs`

Print the agent's log file. Three log types are available.

```bash
tycho agent logs my-project-agent-3                        # raw stream (default)
tycho agent logs my-project-agent-3 --type conversation    # user/assistant turns
tycho agent logs my-project-agent-3 --type system         # tool calls and events
tycho agent logs my-project-agent-3 --follow              # tail -f the raw log
```

---

## `tycho agent send`

Append a user message to the agent's conversation and start it. This is the primary command for multi-turn agent interactions from the CLI.

```bash
tycho agent send my-project-agent-3 "The tests still fail on line 42 — try a different approach"
```

Errors if the agent is already running. Prints pid and log path on success.

---

## `tycho agent archive`

Archive a stopped agent — moves all its log files to the archive directory and removes it from the active agents list.

```bash
tycho agent archive my-project-agent-3
```

Errors if the agent is currently running.

---

## `tycho agent clone`

Clone an existing agent (copies prompt, harness, model, template). The clone gets a new key and a fresh run history.

```bash
tycho agent clone my-project-agent-3          # clone only
tycho agent clone my-project-agent-3 --run    # clone and start immediately
```

---

## `tycho schedule` — Schedule Management

```bash
tycho schedule list
tycho schedule validate
tycho schedule run weekly-review
tycho schedule pause weekly-review
tycho schedule resume weekly-review
tycho schedule reload
```

---

## `tycho project update`

```bash
tycho project update my-project --pr-url https://github.com/org/repo/pull/123
tycho project update my-project --pr-url ""   # clear
```

---

## Project Keys

```bash
grep "^- key:" ~/.tycho/config/hq.yml      # all projects (including agent-only)
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

1. **Find the project key** — `tycho project show <key>` or `grep "^- key:" ~/.tycho/config/hq.yml`
2. **Create the agent** — `tycho agent create <key> "<task>" [--harness claude] [--run]`
3. **Check status** — `tycho agent status <agent-key>` or `tycho agent list <project-key>`
4. **Read output** — `tycho agent logs <agent-key> --type conversation`
5. **Continue the conversation** — `tycho agent send <agent-key> "<follow-up>"`
6. **Stop if needed** — `tycho agent stop <agent-key>`
7. **Clean up** — `tycho agent archive <agent-key>`
