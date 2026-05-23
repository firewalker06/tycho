# Tycho Hooks

Tycho fires events at key points in its runtime. External code can subscribe to these events via shell commands or Ruby handler files, without patching Tycho.

## Architecture

- `HQ.hooks` is a singleton `HQ::Hooks::Dispatcher` that owns a background worker `Thread` and a `Queue`.
- `HQ.hooks.publish(event, payload)` enqueues an event for **async** dispatch. Returns `nil` immediately.
- `HQ.hooks.publish_blocking(event, payload)` runs **blocking** hooks synchronously on the caller thread and returns the first non-nil Hash response, or `nil` if no blocking hooks match. Used for events where a hook can inject a response (v1: only `agent.inquiry.available`).
- Hooks are loaded at boot by `HQ::Hooks::Registry` and reloaded when HQ receives SIGHUP.
- Shell hooks are spawned via `Open3.popen3` in their own process group. The payload is delivered as JSON on stdin plus `TYCHO_EVENT`, `TYCHO_PROJECT_KEY`, `TYCHO_AGENT_KEY`, `TYCHO_BIN`, and `TYCHO_PROJECT_PATH` environment variables. The command is **never** interpolated with payload data.
- Ruby handler files are loaded with `load` so reloads re-evaluate them.

## Configuration

### Global — `~/.tycho/config/hooks.yml`

```yaml
hooks:
  agent.run.started:
    - command: "~/bin/notify.sh"
    - command: "echo started >> /tmp/hq.log"
      env:
        FOO: bar
  agent.inquiry.available:
    - command: "~/bin/auto-answer.rb"
      blocking: true
      timeout: 30
  agent.*:
    - command: "~/bin/agent-all.sh"
```

### Per-project — `~/.tycho/config/hq.yml`

```yaml
projects:
  - key: web
    name: Web
    path: /Users/you/Code/web
    hooks:
      agent.run.started:
        - command: "~/bin/web-notify.sh"
```

Per-project hooks only fire when the event payload carries the matching `project_key`. Global handlers run first, then project handlers.

### Handler fields

| Field | Required | Default | Description |
|---|---|---|---|
| `command` | yes (shell) | — | Path or shell command. `~` is expanded. |
| `env` | no | `{}` | Extra environment variables merged on top of `TYCHO_EVENT`/`TYCHO_PROJECT_KEY`/`TYCHO_AGENT_KEY`. |
| `blocking` | no | `false` | If `true`, runs synchronously and stdout is parsed as JSON for a response. |
| `timeout` | no | `10` (async) / `30` (blocking) | Seconds before the process group receives `SIGTERM`. |

### Ruby handlers

Drop `.rb` files into `~/.claude/hq-hooks/` (global) or `<project_path>/.hq/hooks/` (per-project):

```ruby
# ~/.claude/hq-hooks/log_agent_runs.rb
HQ::Hooks.on("agent.run.finalized") do |payload|
  File.open("/tmp/hq-agent-runs.log", "a") do |f|
    f.puts("#{Time.now} #{payload["agent_key"]} => #{payload["status"]}")
  end
end
```

Handler blocks receive a frozen payload Hash with string keys. Blocking Ruby handlers should return a Hash to inject a response.

### Pattern wildcards

- `agent.run.started` — exact match.
- `agent.run.*` — matches one trailing segment.
- `agent.*` — matches one or more trailing segments (`agent.run.started`, `agent.memory.captured`, etc.).
- `*` — matches any event.

## v1 Event Inventory

### Agent lifecycle

| Event | Payload keys | Notes |
|---|---|---|
| `agent.run.started` | `agent_key`, `project_key`, `workspace`, `session_id`, `pid` | Fires after the agent process is spawned. |
| `agent.run.finished` | `agent_key`, `project_key`, `exit_code`, `status` | Fires when `poll!` detects the process exit. |
| `agent.run.finalized` | `agent_key`, `project_key`, `status`, `exit_code`, `summary`, `structured_result` | After memory capture and run summary. |
| `agent.inquiry.available` | `agent_key`, `project_key`, `inquiry_message`, `inquiry_fields`, `inquiry_requested_schema` | **Blocking-capable.** Return `{"answer": "..."}` to auto-respond. |
| `agent.inquiry.answered` | `agent_key`, `project_key`, `answer` | Emitted async after an inquiry is responded to. |
| `agent.message.user_added` | `agent_key`, `project_key`, `content` | User-authored message appended. |
| `agent.message.assistant_added` | `agent_key`, `project_key`, `content` | Assistant summary/message appended. |
| `agent.memory.captured` | `agent_key`, `project_key`, `status` | After `memory.jsonl` write completes for a run. |
| `agent.session.captured` | `agent_key`, `project_key`, `session_id` | First time a native session id is discovered. |
| `agent.updated` | `agent_key`, `project_key`, `name`, `template_key`, `workspace`, `agent` | After the agent editor saves an edit. |
| `agent.created` | `agent_key`, `project_key`, `template_key`, `name`, `workspace` | After the agent editor creates a new agent. |
| `agent.cloned` | `agent_key`, `source_agent_key`, `project_key`, `name` | After cloning an agent. |
| `agent.deleted` | `agent_key`, `project_key`, `name` | After an agent is deleted and its logs archived. |

### Registry / config

| Event | Payload keys |
|---|---|
| `config.loaded` | `path`, `project_count` | Fired once on boot and after explicit registry reloads (e.g. `add_project!`, `archive_project!`). |
| `config.reloaded` | `path`, `project_count` | Fired when Tycho detects `~/.tycho/config/hq.yml` was modified on disk and re-reads it. Follows `config.loaded`. |
| `project.loaded` | `project_key`, `project_path` | Fired once per project after `config.loaded`. Convenient for per-project bootstrap hooks. |
| `project.added` | `project_key`, `project_path` |
| `project.updated` | `project_key`, `fields` | Fired from `Registry#update_project!` (e.g. `bin/tycho project update ... --pr-url ...`). |
| `project.archived` | `project_key` |

## Blocking `agent.inquiry.available` flow

1. The agent emits an inquiry in its structured result.
2. `ManagedAgent#poll!` detects the pending inquiry and calls `HQ.hooks.publish_blocking("agent.inquiry.available", ...)`.
3. The dispatcher runs matching blocking shell/Ruby hooks within `Timeout.timeout(handler[:timeout])`.
4. If any hook returns `{"answer": "..."}`, HQ appends that as a user message and fires `agent.inquiry.answered`.
5. If no blocking hooks are registered, `publish_blocking` returns `nil` immediately and HQ waits for a human response in the TUI.

Blocking shell hooks must print valid JSON to stdout. A non-JSON or empty response is treated as "no auto-answer."

## Logging

- Hook lifecycle messages are written to `~/.tycho/logs/hq.log` with the `Hooks` progname.
- Shell hook stdout and stderr are tee'd to `~/.tycho/logs/hooks.log` (daily-rotating).

## Risks and limitations

- **Blocking timeouts** rely on `Timeout.timeout` (for Ruby) and a monitor thread + process-group `TERM` (for shell). Ruby's `Timeout` cannot interrupt blocking C extensions; prefer shell hooks for potentially long work.
- **High-frequency events** like `agent.message.assistant_added` can fire often. Registering shell hooks on these in production is discouraged.
- **Worker thread** runs handlers sequentially. A slow async hook will delay subsequent events. Move heavy work into the hook process itself (detach, background).
- **Shell injection** is prevented by never interpolating payload into the command string. All payload data is delivered via stdin or the three fixed env vars. User-defined `env:` values are string-cast.
- **No retry, no backpressure** in v1. A failing hook is logged and skipped.

## Reloading

Send `SIGHUP` to the running Tycho process to reload `~/.tycho/config/hooks.yml`, per-project `hooks:` entries, and Ruby handler files without restarting Tycho.
