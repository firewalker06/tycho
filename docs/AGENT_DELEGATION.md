# Managed-agent delegation

Tycho records managed-agent delegation explicitly. It never infers a parent from prompt text, names, or logs.

## CLI and API

Use `--parent-agent` when creating a child or attaching an existing idle agent before its next run:

```bash
tycho agent create PROJECT "Do the delegated work" --parent-agent PARENT_KEY --run
tycho agent send CHILD_KEY "Continue" --parent-agent PARENT_KEY
tycho agent run CHILD_KEY --parent-agent PARENT_KEY
```

Tycho never infers a parent from the environment. A managed agent must pass its own key explicitly:

```bash
# Inside a managed Tycho agent: explicitly linked to the current agent.
tycho agent create PROJECT "Do the delegated work" \
  --parent-agent "${TYCHO_AGENT_KEY:?Missing TYCHO_AGENT_KEY}" --run

# Omitting the parent creates an unrelated root; --root makes that intent explicit.
tycho agent create PROJECT "Independent work" --root --run
```

`--parent-agent` and `--root` are mutually exclusive. The same explicit rule applies locally and with `--server`.

The same options work with `--server SERVER_KEY`. Both agents must exist on that target server. Remote API callers may pass `parent_agent_key` to `POST /agents`, `POST /agents/:key/messages`, or `POST /agents/:key/start`. Tycho trusts that explicit key as a declaration that the operation came from the parent; it is not cryptographic authentication. A prompt without it enters Takeover, while the recorded parent key preserves or restores Delegation. Callers may also pass `parent_server_id`; when present it must equal the target server's stable instance ID. Repeating the same child/parent attachment is idempotent. Self-parenting, cycles, unknown parents, conflicting re-parenting, and another server ID are rejected without changing the child.

The Remote UI can soft-disconnect an active child from its parent callback using `PATCH /agents/:child/delegation` with `{"connected":false}`. The relationship stays visible and continues to participate in cycle and re-parenting validation, but queued reports are removed and future child reports are not added to the delivery ledger, so they cannot reach or resume the parent. Reconnect with `{"connected":true}`. Runs completed while disconnected are not replayed after reconnect; only later child runs report back. A callback already written to parent history cannot be retracted, though disconnecting cancels a queued automatic resume when possible.

Each relationship also records an owner and ownership generation. A direct prompt without `--parent-agent` changes the owner to `user` before the prompt is stored, advances the generation, removes undelivered reports, and cancels queued parent resumes. A later prompt declared with the recorded parent key restores `parent` ownership and advances the generation. Repeated prompts from the current owner keep the same generation. Parent prompts cancel any unresolved child inquiry before adding the new prompt; they are not treated as answers to that inquiry.

Every new delegated run stores the relationship owner and generation accepted at launch. A completed run reports only when that stamp is parent-owned and still matches the current relationship generation. User-owned runs never become reportable after reclaim, and superseded parent-owned runs never report after takeover. Ownership changes only the child-to-parent edge; delegations below that child remain unchanged.

Delegation is deliberately server-local. To delegate on a configured Remote server, address that server with `--server` and create both agents there. Remote UI preserves each server's routing key while it combines those independent graphs; it never joins agents across servers. A duplicate or changed instance UUID fails closed instead of guessing which server owns a reference.

CLI JSON, `GET /agents`, and `GET /agents/:key` include `delegation.parent` and `delegation.children`. References carry the relationship ID and connection state, a stable server instance ID, immutable display metadata, and the parent's originating managed run ID, run number, and native session ID when available.

## Trusted parent declaration

Tycho deliberately treats `--parent-agent` and `parent_agent_key` as trusted declarations. It does not issue delegation tokens, infer parenthood from `TYCHO_AGENT_KEY`, or bind a declaration to a managed run. This keeps local and Remote CLI behavior identical and avoids capability propagation through custom or resumed harnesses.

The declared parent must be the child's recorded parent. It cannot prompt its own parent or another ancestor, cannot reclaim a child owned by a different parent, and cannot reverse-delegate to an ancestor because cycle validation rejects the edge. Only the lifecycle coordinator writes upward reports. Because the declaration is trusted rather than authenticated, anyone with local CLI access or a valid Remote bearer credential can simulate the recorded parent by supplying its key.

## Callback decision

Every eligible terminal child run creates one report keyed by relationship ID and child run ID. Reports cover success, no-action success, partial, failure, stopped, blocked, and `input_required`. The report includes the ownership generation, concise summary, inquiry, and sanitized HTTP(S) artifact links; it removes URL credentials, query strings, and fragments and excludes raw logs, commands, environment data, credentials, and local file paths.

Tycho appends the report as a durable parent user message and automatically resumes a stopped active parent. It queues all reports first and starts the parent once. It delays resume while another agent in the same workspace is running, preventing concurrent worktree writes; the final child completion releases the queued batch. A running parent receives the durable message after its current run and is resumed once more when it stops. An archived parent receives the report in archived history but is never unarchived or resumed. Missing parents remain recorded in the delegation ledger.

The detached child runner invokes `tycho agent finalize CHILD_KEY` when the harness exits. This finalizes state and delivers callbacks even when Remote UI and the originating parent process are stopped. Remote Server polling is a redundant recovery path, not a delivery requirement.

## Persistence and archives

`~/.tycho/logs/agent_delegations.json` is the relationship/report ledger, including ownership generation and soft-disconnect state. Disconnected, unstamped, and ownership-ineligible runs are intentionally absent from its report queue. `~/.tycho/config/server_identity.json` stores the server instance UUID. A child also stores its immutable parent snapshot in `managed_agents.json` and its archived `agent_manifest.json`. Parent history contains a typed `agent_started` event; callback messages carry typed reference metadata, so Remote UI only links known records and never linkifies arbitrary text.

Archiving either side does not delete the ledger. Archived agent detail and conversation routes are read-only, so links keep working regardless of archive order.

Archived agents remain discoverable through `tycho agent list --archived`, `--include-archived`, and the paginated `GET /agents/archived` API. Remote UI deliberately omits archives from the Agents browser because the history can grow without bound. A typed delegation reference or direct agent route still resolves an archived agent and opens its read-only detail and conversation on the correct server. Archives never enter active polling, unread writes, or bulk actions. Hidden archive snapshots remain omitted.
