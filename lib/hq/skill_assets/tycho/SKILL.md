---
name: tycho
description: Manages Tycho projects, managed agents, delegation, and schedules. Use when the user asks to check status; create/list/run/stop/send/archive/clone agents; delegate work between agents; troubleshoot parent ownership or callbacks; or control schedules for any project.
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
| `--parent-agent KEY` | Attach the originating agent/session on the same Tycho server |
| `--root` | Explicitly create an unrelated root agent |

```bash
# Create only
tycho agent create my-project "Refactor the auth module to use JWT"

# Create and start immediately
tycho agent create my-project "Fix failing tests in spec/models" --run

# Specify harness and model
tycho agent create global-web "Review open PRs" --harness claude --model claude-opus-4-5 --run

# Delegate and report the child outcome back automatically
tycho agent create global-web "Review the auth boundary" --parent-agent global-web-agent-123 --run
```

### Delegating from a managed Tycho agent

Pass this managed agent's key explicitly. Tycho treats `--parent-agent` as the trusted declaration that the prompt came from the parent, links the child, and returns each terminal delegated run to that parent:

```bash
"${TYCHO_EXECUTABLE:-tycho}" agent create global-web "Review the auth boundary" \
  --parent-agent "${TYCHO_AGENT_KEY:?Missing TYCHO_AGENT_KEY}" --run
```

Omitting `--parent-agent` creates an unrelated root agent. `--root` makes that choice explicit. The same rule applies with `--server`.

### Parent declaration

Tycho does not issue or require a delegation token. `--parent-agent KEY` and the Remote API's `parent_agent_key` are trusted parent declarations:

- With a parent key, a create, send, or run operation is delegated and its terminal run reports back.
- Without a parent key, a message to an existing delegated child is a direct user prompt and enters Takeover.
- A later operation with the recorded parent key restores Delegation.
- `TYCHO_AGENT_KEY` identifies the current managed agent so it can supply its own key explicitly; Tycho never infers ownership from that environment variable.

The declaration is not cryptographic authentication. Use it only with the actual recorded parent. Tycho still rejects unknown parents, self-parenting, cycles, conflicting re-parenting, and ancestor prompts.

### Ownership and callback rules

- Keep delegation server-local. Self-parenting, cycles, unknown parents, conflicting re-parenting, and ancestor prompting are invalid.
- Treat a direct user prompt to a delegated child as Takeover. It changes the edge owner to `user`, advances its ownership generation, suppresses pending reports, and cancels queued parent resumes.
- Let only a prompt declared with the recorded parent key restore Delegation. Parent reclaim advances the generation and cancels any unresolved child inquiry before storing the prompt.
- Expect every terminal delegated run to create one deduplicated report when callbacks are connected. Tycho stamps ownership at launch and rejects stale generations.
- Let Tycho deliver eligible terminal reports and resume the parent. It waits while the parent or another agent in the same workspace is running.
- Treat callback disconnect as suppression, not deletion. Disconnected runs are not replayed after reconnect, and archived parents receive history without being resumed.
- Read the UI conservatively: Tycho shows `Takeover` only while a delegated edge is user-owned. It does not show a normal `Delegation` badge.

---

## `tycho agent list`

List active managed agents, archived read-only history, or both. All modes can be filtered to one project or addressed through `--server`.

```bash
tycho agent list                  # all agents
tycho agent list my-project       # only agents for my-project
tycho agent list --archived       # archived agents only
tycho agent list --include-archived # active and archived agents
```

Output columns: Key, Project, Name, Parent, Harness, State, Status, Runs.

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
tycho agent run my-project-agent-3 --parent-agent orchestrator-agent-key
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
tycho agent send my-project-agent-3 "Continue the delegated task" --parent-agent orchestrator-agent-key
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
