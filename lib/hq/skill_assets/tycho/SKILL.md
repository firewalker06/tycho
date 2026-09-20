---
name: tycho
description: Manages Tycho projects, managed agents, delegation, and schedules. Use when the user asks to check status; create/list/run/stop/send/archive/clone agents; delegate work between agents; troubleshoot parent ownership or callbacks; or control schedules for any project.
---

# Tycho CLI Skill


## Quick Reference

| Group | Command | Description |
|-------|---------|-------------|
| **project** | `project create <project-key> [options]` | Intentionally create a project |
| | `project list` | List configured projects |
| | `project show <project-key>` | Show normalized configuration and Git metadata |
| | `project update <project-key> --pr-url <url>` | Set / clear open PR URL |
| **agent** | `agent create <project-key> <prompt>` | Create (and optionally run) a managed agent |
| | `agent list [<project-key>]` | List agents, optionally filtered by project |
| | `agent status <agent-key>` | Show full status and metadata |
| | `agent run <agent-key>` | Start or re-run an existing agent |
| | `agent stop <agent-key>` | Stop a running agent |
| | `agent logs <agent-key>` | Print agent log |
| | `agent send <agent-key> <message> [--delay SECONDS]` | Send now or schedule a durable continuation |
| | `agent archive <agent-key>` | Archive an agent and move its logs |
| | `agent clone <agent-key>` | Clone an existing agent |
| **queue** | `queue <agent-key>` | Open or inspect the agent's durable queue-work batch |
| **queue-work** | `queue-work complete <agent-key> <batch-id> --dispositions-json JSON` | Record one outcome per queue-work entry |
| **schedule** | `schedule list` | List all schedules and daemon status |
| | `schedule validate` | Validate schedule config |
| | `schedule run <schedule-key>` | Trigger a schedule immediately |
| | `schedule pause <schedule-key>` | Pause a schedule |
| | `schedule resume <schedule-key>` | Resume a paused schedule |
| | `schedule reload` | Deprecated alias for `schedule restart` |
| | `schedule restart [--server KEY] [--json]` | Restart the scheduler daemon |

---

## `tycho project create`

Create a project only with the explicit subcommand:

```bash
tycho project create <project-key> [options]
```

The bare `tycho project <project-key>` form is unsupported and does not create a project. Use `--path` to override the current directory and `--name` to override the directory name.

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

Pass this managed agent's key explicitly. Tycho treats `--parent-agent` as the trusted declaration that the prompt came from the parent, links the child, and returns terminal delegated runs to that parent:

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
- Once queued work reaches an agent, let that receiver process the complete pending queue as one native input. The newest entry supplies the batch owner and generation; earlier per-entry stamps do not split the batch.
- Expect every terminal delegated run to create one deduplicated report when callbacks are connected. Tycho stamps ownership at launch and rejects stale generations.
- Let Tycho accumulate eligible terminal reports for the same parent into one deterministic callback and resume. It waits while the parent or another agent in the same workspace is running.
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
tycho agent send my-project-agent-3 "Check the external job again" --delay 60
```

Without `--delay`, Tycho starts an idle agent or queues the message behind its current run. With `--delay`, Tycho persists the message immediately with an exact `not_before` time and starts it only after that time when the target and workspace are idle. Future entries remain visible and editable but do not block already-due work. Local and `--server` JSON responses expose the same stable queue ID, `accepted_at`, and `not_before` values.

Inside a managed agent, sending a delayed message to its own `TYCHO_AGENT_KEY` is an internal continuation. This narrow self-send rule preserves delegation ownership and does not enter Takeover; it does not infer a parent for any other command. Prefer delayed self-send over sleeping while external state changes.

Tycho stops a managed run after its third typed blocking wait invocation when the harness exposes a proven pre-execution signal. The Conversation summary reads **Stopped due to overusing sleep-like commands**. A delayed recovery is scheduled once; any explicit user, parent, or other-agent send/run cancels it before dispatch.

---

## `tycho queue`

Open every currently pending delegated reply and user prompt for one agent as a single FIFO-preserving durable batch, or inspect the same batch again idempotently:

```bash
tycho queue my-project-agent-3
tycho queue my-project-agent-3 --server peer --json
```

A successful first read records one Conversation block labeled **Read queue** and moves the entries into an open queue-work batch; it does not mark them complete. The response leads with required user instructions while retaining the canonical FIFO entries and structured delegated reports. Entries arriving after the locked read remain queued for the next batch. Relevant agent command responses include a non-destructive queue notice for the current managed agent when `TYCHO_AGENT_KEY` has pending or open work.

Before returning a successful agent result, record exactly one source-appropriate outcome for every stable entry ID:

```bash
tycho queue-work complete my-project-agent-3 BATCH_ID \
  --dispositions-json '[{"entry_id":"USER_ID","outcome":"completed"},{"entry_id":"REPORT_ID","outcome":"incorporated"}]'
```

User outcomes are `completed`, `needs_input`, or `declined_with_reason`; delegated callback outcomes are `incorporated` or `superseded_with_reason`. The two `*_with_reason` outcomes require a non-empty `reason`. Missing, duplicate, unknown, conflicting, or invalid outcomes leave the batch open. An identical completion is idempotent. Tycho gates a false success and resumes the same native session once with the unresolved checklist; a second incomplete attempt stays open without looping.

---

## `tycho agent archive`

Archive a stopped agent — moves all its log files to the archive directory and removes it from the active agents list. Ordinary queued prompts and mixed queues block archive. If every queued item is a protected delegation callback, Tycho archives without running the callbacks and preserves their complete messages in read-only history.

```bash
tycho agent archive my-project-agent-3
```

Errors if the agent is currently running or has any ordinary queued work. Successful callback-only archives report how many unrun delegation callbacks were preserved.

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
tycho schedule restart
```

---

## `tycho project update`

```bash
tycho project update my-project --pr-url https://github.com/org/repo/pull/123
tycho project update my-project --pr-url ""   # clear
```

## Server-aware commands and compatibility

Use `--server SERVER_KEY` to route supported project, schedule, update, doctor, and restart commands through Tycho's configured authenticated Remote API. Add `--json` for machine output; errors also stay JSON on stdout.

`tycho serve restart [--server SERVER_KEY] [--json]` restarts a local controlled server or asks the configured remote server to restart itself. `tycho restart` and `tycho schedule reload` remain compatibility aliases and print deprecation guidance. `tycho metrics backfill` is retired; use `tycho metrics query`. `tycho debug claude` remains temporarily compatible; use `tycho doctor --claude` for the same diagnostics.

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
