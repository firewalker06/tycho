---
name: SCHEDULED_RUNS
description: Current decisions for cron-like scheduled agent runs in Tycho/HQ
type: reference
---

# Scheduled Runs

## Summary

Tycho scheduled runs are driven by `tycho schedule daemon`. Definitions live in `~/.tycho/config/schedules.yml`, mutable runtime state lives in `~/.tycho/logs/schedules.json`, daemon heartbeat state lives in `~/.tycho/logs/scheduler_daemon.json`, and cron syntax is validated before any long-running scheduler loop starts. The TUI and Remote UI are management surfaces, but neither owns the clock.

The current scope is intentionally narrow: schedules own one persistent managed agent session each. There are no shell commands, agent-template selections, ad hoc existing-agent targets, or agent clones. The first due run creates the schedule-owned agent; later due runs append a scheduled user message to that same agent and start another `ManagedAgent` run so native Codex/Claude/OpenCode session resume can preserve context.

Each schedule has two editable prompt fields: a system message for the schedule-owned agent session, and a run message sent as the next user message each time the schedule runs. The Remote UI edits both in one schedule form and saves the run message inline in `~/.tycho/config/schedules.yml`; legacy `message_file` schedules still load, but saving them from the Remote UI converts them to inline run messages. On failure or required human input, stop the schedule and notify via web push. On success, notify only on the first successful run and the first successful run after a prior failure; both success notifications should include the next scheduled run time.

## Current Decisions

- Scheduler owner: dedicated `tycho schedule daemon`, not the TUI and not the Remote server.
- Management surfaces: both TUI and Remote UI show schedules and allow safe operations.
- Remote UI daemon control: Remote UI may start, stop, or restart the dedicated scheduler daemon through a supervisor, but `tycho serve` must not run scheduler ticks itself.
- Config source: `~/.tycho/config/schedules.yml`.
- Validation: fail fast on invalid cron syntax, invalid project references, and invalid prompt file paths.
- Runtime state: persist mutable schedule state separately from config under `~/.tycho/logs/schedules.json`.
- Daemon state: persist `tycho schedule daemon` heartbeat and last tick metadata under `~/.tycho/logs/scheduler_daemon.json`.
- Target scope: agent-only. Each schedule owns one managed agent and each run resumes that schedule session.
- Unsupported commands: `shell`, `agent_template`, `agent_existing`, and `agent_clone`.
- Prompt fields: system message plus run message in one schedule form.
- Run-message source: Remote UI saves inline text in `~/.tycho/config/schedules.yml`; legacy file-backed schedules are read-compatible and convert to inline when saved from the form.
- Scheduled execution prompts include the final-output attachment checklist so created or referenced durable artifacts are reported in `attachments`; the stored scheduled user message stays clean to avoid repeated checklist buildup in persistent memory.
- Scheduled agent display names do not include a text prefix; UI surfaces distinguish them with the schedule icon.
- Retention: keep the schedule-owned agent active across runs unless the operator explicitly archives it.
- Interactive protection: stop the schedule when the schedule-owned agent has a later non-scheduled user message; resuming records an acknowledgement boundary so earlier operator messages do not immediately stop the schedule again.
- Failure and input management: stop the schedule and notify via web push when a scheduled job fails, blocks, or requires human input.
- Schedule statuses: schedules expose `scheduled`, `paused`, or `stopped` as operator-facing state. Last run details stay in `last_status` and `last_error`.
- No-action outcomes: scheduled agents should return structured status `no_action_needed` when a recurring check completes and finds nothing to act on. Tycho records that as the schedule's last outcome but does not mark the agent unread or send success/push notifications.
- Resume behavior: resuming a stopped schedule keeps the schedule-owned session, records a resume boundary, and waits until the next scheduled run.
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

- Creates or reuses the schedule-owned managed agent for `project_key`.
- Uses the project's path and default agent harness from `~/.tycho/config/hq.yml`.
- Does not select a project agent template.
- Seeds the schedule system message once, then appends the run message as a user message for each due run.
- Names the managed agent from `target.name`, falling back to the schedule name or key, without adding a text prefix.
- Starts the agent through `ManagedAgent#start!`.
- Reuses the same native session when the harness exposes a persisted `session_id`.
- Keeps schedule context continuous across runs and avoids creating a fragmented agent list.

An agent can technically be prompted to run local commands, but schedules should not model shell commands as their own target type.

### Prompt Fields

`system_message`:

- Stable schedule-owned agent context.
- Used when Tycho creates the schedule session.
- Defaults to Tycho's generated recurring-session contract when omitted.

`message`:

- Store the message sent each run directly in `~/.tycho/config/schedules.yml` as `message`.
- Sent as the user message every time the schedule runs.
- Remote UI edits this inline in the main schedule form.

`message_file`:

- Legacy read-compatible source for existing schedules.
- Remote UI loads the file content into the main schedule form and saves it back as inline `message`.

### Fixed Runtime Semantics

- Pause and resume are the schedule on/off controls.
- If the schedule-owned agent is still running when a run is due, Tycho skips that due time and computes the next one.
- If Tycho was offline or late, Tycho runs once when it observes the due schedule, then computes the next future due time.
- If a human has interacted with the schedule-owned session, Tycho stops the schedule until the operator resumes it.

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
- Resuming a stopped schedule marks it scheduled, keeps the previous active scheduled session, records `resumed_at`, and waits until the next scheduled run.
- Archiving a session for a `stopped` or `paused` schedule returns it to `scheduled` for future job execution.

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
    cron: "0 9 * * 1-5"
    timezone: local
    target:
      type: agent
      project_key: tycho
      name: Tycho scheduled maintenance
      system_message: |
        You are the long-lived scheduled maintenance agent for Tycho.
        Keep context across runs and ask for human input when needed.
      message: |
        Run the weekday maintenance check and report the outcome.
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
  "previous_target_key": null,
  "next_due_at": "2026-05-19T09:00:00+07:00",
  "run_count": 12,
  "skip_count": 1,
  "first_success_notified_at": "2026-05-01T09:05:00+07:00",
  "failure_started_at": null,
  "recovery_notified_at": "2026-05-18T09:07:00+07:00",
  "resumed_at": null
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
- Link each schedule row to its schedule-owned agent session when one exists.
- Support pause/resume/manual run/reload through the JSON API and Remote UI controls.
- Support daemon start/stop/restart through a Remote UI supervisor that launches the existing `tycho schedule daemon` process separately from `tycho serve`.
- Preserve mobile ergonomics: schedule details should be readable without requiring terminal access.

Hooks:

- Emit `schedule.due`, `schedule.started`, `schedule.skipped`, `schedule.failed`, `schedule.stopped`, `schedule.completed`, `schedule.recovered`, `schedule.agent_archived`, and `schedule.resumed`.
- Include `schedule_key`, `target_kind`, `target_key`, `project_key`, and timestamps.
