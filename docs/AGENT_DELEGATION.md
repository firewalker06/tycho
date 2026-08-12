# Managed-agent delegation

Tycho records managed-agent delegation explicitly. It never infers a parent from prompt text, names, or logs.

## CLI and API

Use `--parent-agent` when creating a child or attaching an existing idle agent before its next run:

```bash
tycho agent create PROJECT "Do the delegated work" --parent-agent PARENT_KEY --run
tycho agent send CHILD_KEY "Continue" --parent-agent PARENT_KEY
tycho agent run CHILD_KEY --parent-agent PARENT_KEY
```

The same options work with `--server SERVER_KEY`. Both agents must exist on that target server. Remote API callers pass `parent_agent_key` to `POST /agents`, `POST /agents/:key/messages`, or `POST /agents/:key/start`. They may also pass `parent_server_id`; when present it must equal the target server's stable instance ID. Repeating the same child/parent attachment is idempotent. Self-parenting, cycles, unknown parents, conflicting re-parenting, and another server ID are rejected without changing the child.

Delegation is deliberately server-local. To delegate on a configured Remote server, address that server with `--server` and create both agents there. Remote UI preserves each server's routing key while it combines those independent graphs; it never joins agents across servers. A duplicate or changed instance UUID fails closed instead of guessing which server owns a reference.

CLI JSON, `GET /agents`, and `GET /agents/:key` include `delegation.parent` and `delegation.children`. References carry a stable server instance ID, immutable display metadata, and the parent's originating managed run ID, run number, and native session ID when available.

## Callback decision

Every terminal child run creates one report keyed by relationship ID and child run ID. Reports cover success, no-action success, partial, failure, stopped, blocked, and `input_required`. The report includes the concise summary, inquiry, and sanitized HTTP(S) artifact links; it removes URL credentials, query strings, and fragments and excludes raw logs, commands, environment data, credentials, and local file paths.

Tycho appends the report as a durable parent user message and automatically resumes a stopped active parent. It queues all reports first and starts the parent once. It delays resume while another agent in the same workspace is running, preventing concurrent worktree writes; the final child completion releases the queued batch. A running parent receives the durable message after its current run and is resumed once more when it stops. An archived parent receives the report in archived history but is never unarchived or resumed. Missing parents remain recorded in the delegation ledger.

The detached child runner invokes `tycho agent finalize CHILD_KEY` when the harness exits. This finalizes state and delivers callbacks even when Remote UI and the originating parent process are stopped. Remote Server polling is a redundant recovery path, not a delivery requirement.

## Persistence and archives

`~/.tycho/logs/agent_delegations.json` is the relationship/report ledger. `~/.tycho/config/server_identity.json` stores the server instance UUID. A child also stores its immutable parent snapshot in `managed_agents.json` and its archived `agent_manifest.json`. Parent history contains a typed `agent_started` event; callback messages carry typed reference metadata, so Remote UI only links known records and never linkifies arbitrary text.

Archiving either side does not delete the ledger. Archived agent detail and conversation routes are read-only, so links keep working regardless of archive order.

Archived agents are also discoverable without a known key. `tycho agent list --archived` lists only archives and `--include-archived` combines them with the active list; both support the existing project and `--server` filters. Remote UI exposes **Active**, **Archived**, and **Active and archived** filters and loads the archive index from each configured server without adding archived agents to active polling, unread counts, or bulk actions. `GET /agents/archived` provides the underlying server-local index with `page`, `per_page` (maximum 100), `project_key`, and `q` filters. Hidden archive snapshots remain omitted. Every archive entry includes its immutable key, project, terminal state, archive time, server route, and delegation references, and opens the same read-only detail route.
