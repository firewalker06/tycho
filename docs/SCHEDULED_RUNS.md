---
name: SCHEDULED_RUNS
description: Current decisions for cron-like scheduled agent runs in Tycho/HQ
type: reference
---

# Scheduled Runs

## Summary

Tycho scheduled runs are driven by `tycho schedule daemon`. Definitions live in `~/.tycho/config/schedules.yml`, mutable runtime state lives in `~/.tycho/logs/schedules.json`, daemon heartbeat state lives in `~/.tycho/logs/scheduler_daemon.json`, and cron syntax is validated before any long-running scheduler loop starts. The TUI and Remote UI are management surfaces, but neither owns the clock.

The current scope is intentionally narrow: schedules create fresh managed agents only. There are no first-class scheduled project actions, health checks, shell commands, agent-template selections, existing-agent resumes, or agent clones. Each due run creates a brand-new agent with fresh context, starts it through the existing `ManagedAgent` path, and archives the previous schedule-created agent for that schedule before the next repetitive run.

Prompt input is limited to inline text in `~/.tycho/config/schedules.yml` or a file under `~/.tycho/schedules/`. On failure, stop the schedule and notify via web push. On success, notify only on the first successful run and the first successful run after a prior failure; both success notifications should include the next scheduled run time.

## Current Decisions

- Scheduler owner: dedicated `tycho schedule daemon`, not the TUI and not the Remote server.
- Management surfaces: both TUI and Remote UI show schedules and allow safe operations.
- Remote UI daemon control: Remote UI may start, stop, or restart the dedicated scheduler daemon through a supervisor, but `tycho serve` must not run scheduler ticks itself.
- Config source: `~/.tycho/config/schedules.yml`.
- Validation: fail fast on invalid cron syntax, invalid project references, and invalid prompt file paths.
- Runtime state: persist mutable schedule state separately from config under `~/.tycho/logs/schedules.json`.
- Daemon state: persist `tycho schedule daemon` heartbeat and last tick metadata under `~/.tycho/logs/scheduler_daemon.json`.
- Target scope: agent-only. Each run creates a brand-new managed agent with fresh context.
- Unsupported commands: `project_action`, `health_check`, `shell`, `agent_template`, `agent_existing`, and `agent_clone`.
- Prompt sources: only inline text or files under `~/.tycho/schedules/`.
- Scheduled prompts always include the final-output attachment checklist so created or referenced durable artifacts are reported in `attachments`.
- Scheduled agent display names are prefixed with `[Scheduled]` and do not include the internal agent-key number.
- Retention: archive the previous schedule-created agent for a repeating schedule before creating the next one.
- Interactive protection: stop the schedule instead of archiving when the previous scheduled agent has a later user message.
- Failure management: stop the schedule and notify via web push when a scheduled job fails.
- Schedule statuses: schedules expose `scheduled`, `paused`, or `stopped` as operator-facing state. Last run details stay in `last_status` and `last_error`.
- Resume behavior: resuming a stopped schedule archives any previous active scheduled session and waits until the next scheduled run.
- Success notifications: notify only on first success and first success after failure, including the next scheduled run time.

## Current Design

### Architecture To Reuse

- `ManagedAgent#start!` spawns Codex/Claude-compatible runs as detached child processes, writes raw logs, tracks `pid`, preserves native `session_id`, clears derived logs, and emits lifecycle hooks.
- `AgentStore#load_with_poll_events` restores persisted agents from `~/.tycho/logs/managed_agents.json`, polls running processes, marks completed runs unread, and produces transition events for push notifications.
- `RemoteService` already exposes start/stop/chat/archive operations for agents, setup readiness, push notifications, and project refresh.
- The TUI has 30-second full refresh and 10-second action/agent polling, but it is an interactive client rather than a reliable background daemon.
- Hooks can react to schedule and agent events, but they should not become the clock source.

The scheduler should orchestrate existing domain objects, not become a parallel process-execution engine.

### Target Model

Schedules support exactly one target type:

`agent`:

- Creates a brand-new managed agent for `project_key`.
- Uses the project's path and default agent harness from `~/.tycho/config/hq.yml`.
- Does not select a project agent template.
- Seeds the scheduled text as the agent's instruction.
- Names the managed agent from `target.name`, falling back to the schedule name or key, with a `[Scheduled]` prefix.
- Starts the agent through `ManagedAgent#start!`.
- Archives the previous schedule-created agent for the same schedule before creating the next repetitive run.
- Keeps session context fresh and avoids stale native agent sessions.

An agent can technically be prompted to run a Tycho project command, but schedules should not model project actions as their own target type.

### Prompt Sources

`inline`:

- Store `message` directly in `~/.tycho/config/schedules.yml`.
- Pros: simplest to read and edit, no extra files, good for short recurring instructions.
- Cons: YAML gets noisy for long prompts, quoting multiline text is easy to mangle, and reuse across schedules is weak.

`file`:

- Store `message_file: schedules/weekday-maintenance.md` and load the file at dispatch time or daemon reload.
- Pros: best for long prompts, easy to review as Markdown, keeps schedule config compact.
- Cons: another path to validate, missing file behavior must be clear, and UI editing becomes more complex.
- Constraint: the path must stay inside `~/.tycho/schedules/`; reject absolute paths, `..`, and anything that resolves outside that directory.

Do not support prompt references yet. They are convenient, but they reintroduce template coupling and make schedule behavior less local to `~/.tycho/config/schedules.yml` plus `schedules/`.

### Schedule Policies

Overlap:

- `skip`: if the previous target is still running, record skipped and compute the next due time.
- `queue`: run once after the current run finishes.
- `parallel`: allow another run. This should be rare and probably disabled in v1 because fresh agents can still compete for the same workspace.

Missed runs:

- `skip_missed`: if Tycho was offline, schedule only the next future run.
- `run_once_on_start`: if one or more due times were missed, run one catch-up.
- `run_all_missed`: likely not needed for Tycho because agent runs can be expensive.

Time zones:

- Default to local machine time.
- Allow `timezone` per schedule.
- Persist due times with offsets.

Cron validation:

- Start with standard five-field cron syntax: minute, hour, day-of-month, month, day-of-week.
- Reject unsupported Quartz-style fields such as seconds, year, `?`, `L`, and `#` unless Tycho intentionally adopts them.
- Validate all definitions in `~/.tycho/config/schedules.yml` before `tycho schedule daemon` starts the long-running loop.
- Include the schedule key and cron field in error messages so TUI/Remote UI can render useful validation failures.

Failure:

- Record scheduler failure separately from target agent failure.
- If a scheduled job fails, stop the schedule immediately.
- Send a web push notification for the failure with the schedule key, agent key when available, failure summary, and the schedule's stopped state.
- A start failure should create a visible schedule status even if no agent run exists.
- Reuse agent logs for target output when an agent was created.

Schedule status:

- `scheduled`: the schedule is eligible for daemon ticks. Current-run and last-run details are shown separately.
- `paused`: the schedule is intentionally held by user action or config and will not run until resumed.
- `stopped`: Tycho stopped the schedule because continuing is unsafe or impossible, such as a failed run, blocked/input-required result, start error, or interactive protection.
- Paused and stopped schedules prevent subsequent scheduled jobs.
- Resuming a paused schedule marks it scheduled and recomputes the next due time.
- Resuming a stopped schedule marks it scheduled, archives any previous active scheduled session for that schedule, and waits until the next scheduled run.

Success notifications:

- Notify when a schedule succeeds for the first time.
- Notify when a schedule succeeds for the first time after a prior failure.
- Do not notify for every successful run.
- Include the next scheduled run time in both success notification types.
- Use clear copy for recovery, for example "Succeeded after failure: weekday-maintenance. Next run: 2026-05-19 09:00."

Locks:

- Store per-schedule `running_lock` or `last_due_at`.
- Use atomic file writes for `~/.tycho/logs/schedules.json`.
- Treat `AgentStore` and `~/.tycho/logs/schedules.json` as shared state because TUI, Remote UI, and scheduler may all touch them.

### Data Model

Definition fields:

```yaml
schedules:
  - key: weekday-maintenance
    name: Weekday maintenance
    enabled: true
    cron: "0 9 * * 1-5"
    timezone: local
    target:
      type: agent
      project_key: tycho
      name: Tycho scheduled maintenance
      message_source: file
      message_file: schedules/weekday-maintenance.md
    policy:
      overlap: skip
      missed: run_once_on_start
      retain_runs: 20
      archive_previous_agent: true
```

Runtime fields:

```json
{
  "key": "weekday-maintenance",
  "status": "scheduled",
  "enabled": true,
  "paused_at": null,
  "last_due_at": "2026-05-18T09:00:00+07:00",
  "last_started_at": "2026-05-18T09:00:03+07:00",
  "last_finished_at": null,
  "last_status": "started",
  "last_error": null,
  "last_target_kind": "agent",
  "last_target_key": "tycho-agent-8",
  "previous_target_key": "tycho-agent-7",
  "next_due_at": "2026-05-19T09:00:00+07:00",
  "run_count": 12,
  "skip_count": 1,
  "first_success_notified_at": "2026-05-01T09:05:00+07:00",
  "failure_started_at": null,
  "recovery_notified_at": "2026-05-18T09:07:00+07:00"
}
```

Definitions are user-authored config. Runtime state is managed by Tycho.

Daemon state:

```json
{
  "pid": 12345,
  "mode": "daemon",
  "dry_run": false,
  "interval": 30,
  "started_at": "2026-05-18T09:00:00+07:00",
  "last_tick_started_at": "2026-05-18T09:05:00+07:00",
  "last_tick_finished_at": "2026-05-18T09:05:01+07:00",
  "last_result": {
    "started": 1,
    "skipped": 0,
    "queued": 0,
    "failed": 0,
    "dry_run": false
  }
}
```

The UI derives daemon status as `running`, `stale`, or `stopped` from this heartbeat and process liveness. If a scheduler process is running but no heartbeat has been written, the UI reports `untracked` and prompts for a daemon restart so tick freshness can resume.

### API And UI Surface

CLI:

```bash
tycho schedule validate
tycho schedule list
tycho schedule run weekday-maintenance
tycho schedule pause weekday-maintenance
tycho schedule resume weekday-maintenance
tycho schedule reload
```

Daemon:

```bash
tycho schedule daemon
tycho schedule list
tycho schedule daemon --once
tycho schedule daemon --dry-run
```

Remote API:

```text
GET  /schedules
GET  /schedules/:key
POST /schedules/:key/run
POST /schedules/:key/pause
POST /schedules/:key/resume
POST /schedules/reload
POST /schedules/daemon/start
POST /schedules/daemon/stop
POST /schedules/daemon/restart
```

TUI:

- Add schedule management as a first-class TUI surface, either as a dedicated screen or a Schedules panel with list/detail behavior.
- Show schedule status, next due, last outcome, last target, skip count, validation status, and daemon freshness.
- Support manual run, pause, resume, and reload actions.
- Link project and agent detail views back to related schedules.

Remote UI:

- Show a compact Schedules card in the Now view, not only a Setup diagnostic.
- Show daemon status, PID, and last tick in the card header.
- Show configured schedules with next run, linked project, status, and a dependency-free humanized cron cadence.
- Support pause/resume/manual run/reload through the JSON API and Remote UI controls.
- Support daemon start/stop/restart through a Remote UI supervisor that launches the existing `tycho schedule daemon` process separately from `tycho serve`.
- Preserve mobile ergonomics: schedule details should be readable without requiring terminal access.

Hooks:

- Emit `schedule.due`, `schedule.started`, `schedule.skipped`, `schedule.failed`, `schedule.stopped`, `schedule.completed`, `schedule.recovered`, `schedule.agent_archived`, and `schedule.resumed`.
- Include `schedule_key`, `target_kind`, `target_key`, `project_key`, and timestamps.
