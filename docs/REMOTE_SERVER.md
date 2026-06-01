# Remote Sessions Server

The Remote Sessions server is HQ's local JSON API for inspecting and controlling managed agents without opening the Bubbletea TUI. It is intentionally small and local-first: the API reuses the same `AgentStore` and `ManagedAgent` domain objects as the TUI, so agent state continues to live in `~/.tycho/logs/managed_agents.json` and per-agent artifacts under `~/.tycho/logs/agents/`.

## Tech Stack

- Runtime: Ruby stdlib only for the server loop.
- Transport: HTTP/1.1 over `TCPServer` from `socket`.
- Body format: JSON request and response bodies.
- Routing: manual method/path dispatch in `HQ::RemoteServer`.
- Domain layer: `HQ::RemoteService`, backed by `Registry`, `AppProject`, `AgentStore`, `ManagedAgent`, and `AgentChatLog`.
- QR rendering: `rqrcode` generates the QR matrix; HQ renders a compact terminal half-block QR for the remote UI URL.
- Logging: request/lifecycle lines are printed to stdout and also sent to `HQ.logger`, which writes to `~/.tycho/logs/hq.log`.

No Rack, Rails, Puma, WEBrick, or external webserver gem is used.

## Running

Start the server:

```bash
tycho serve
```

When Tailscale is not available, the default bind is:

```text
http://127.0.0.1:7373
```

If the `tailscale` CLI is available and Tailscale is running, `tycho serve`
automatically binds to this machine's Tailscale IPv4 address and prints
the MagicDNS UI URL:

```text
[Remote] 21:20:37 Tailscale detected; using MagicDNS hq-device.tailnet-name.ts.net
[Remote] 21:20:37 Remote server listening on http://100.64.0.10:7373
[Remote] 21:20:37 Remote UI available at http://hq-device.tailnet-name.ts.net:7373/
[Remote] 21:20:37 Scan this QR code to open HQ Remote
```

The QR code is separated from the logs by one blank line. It encodes the
MagicDNS UI URL, uses QR error correction level `:l`, renders with
terminal half-block characters, and uses a 2-module quiet zone to keep
the startup output compact while remaining scanner-friendly.

When Tailscale HTTPS is enabled for the machine, HQ also checks
`tailscale serve status --json`. If that status shows an HTTPS Serve
proxy forwarding to the current `tycho serve` port, HQ binds locally for
the Serve proxy and uses the `https://{magicdns}/` URL for the Remote
UI line and QR code. If HTTPS is available but Serve is not configured
for the current port, HQ keeps the working HTTP MagicDNS URL and prints
a startup hint:

```text
[Remote] 21:20:37 Tailscale HTTPS is enabled for hq-device.tailnet-name.ts.net
[Remote] 21:20:37 Run `tailscale serve --bg 7373` and restart to use an HTTPS QR
```

Port `80` is not required for HTTPS. Keep HQ on its normal local port,
for example `7373`, and let Tailscale Serve terminate HTTPS on the
tailnet-facing port:

```bash
tailscale serve --bg 7373
tycho serve --port 7373
```

That setup exposes the Remote UI as:

```text
https://hq-device.tailnet-name.ts.net/
```

An address such as `https://hq-device.tailnet-name.ts.net:7373/` only
works when Tailscale Serve itself is configured to listen for HTTPS on
port `7373`:

```bash
tailscale serve --bg --https=7373 7373
tycho serve --port 7373
```

Running HQ directly on port `80` is discouraged. On macOS and Linux it
usually requires elevated privileges, and plain `http://...:80` still
does not satisfy browser secure-context requirements for service workers
and push notifications.

Custom bind:

```bash
tycho serve --host 127.0.0.1 --port 7374
```

Passing `--host` disables Tailscale auto-binding, so use it when you
explicitly want localhost or another interface.

The server handles `INT` and `TERM` by closing the listener and unwinding cleanly. Pressing `ctrl-c` should return to the shell without a crash report.

## Restart Lifecycle

The Remote UI can restart the Remote server process through `POST /server/restart`. This restarts the `tycho serve` process; it does not restart a separate TUI process.

The restart flow is intentionally ordered so the browser gets a clean acknowledgement before the process image is replaced:

1. `tycho serve` captures its original command-line arguments before option parsing.
2. `tycho serve` constructs `HQ::RemoteServer` with a restart command using the current executable and the original arguments.
3. An authenticated `POST /server/restart` request marks restart requested, asks the accept loop to shut down, and closes the listening socket.
4. The current HTTP response is written as `202 Accepted` with `{ "restarting": true }`.
5. After the response is flushed and the client socket is closed, the server loop exits.
6. The server closes the listener if needed and calls `exec(*restart_command)`.
7. The browser polls `/health` until the replacement process is reachable again, then refreshes `/agents`, `/projects`, and `/setup`.

If a `RemoteServer` is constructed without a restart command, `POST /server/restart` returns `409 Conflict`. That keeps test and embedded server instances from accidentally attempting to replace their process.

## Web UI

The remote server also serves a lightweight mobile web UI:

```text
http://127.0.0.1:7373/
```

The UI is plain server-served HTML/CSS/JavaScript, with no frontend build step or JavaScript package dependencies. It uses the existing JSON endpoints, stores the optional bearer token in browser local storage, and sends it as `Authorization: Bearer ...` for API requests.

Home-screen launches are treated as normal browser sessions, but mobile browsers can be more aggressive about reusing an old app shell. The root UI references `/ui.css` and `/ui.js` with a content digest query string, and `POST /server/restart` is the explicit cache-reset path: the restart response sends cache-reset headers, the browser clears Cache Storage when available, and the UI reloads itself with a restart query string after the replacement server is healthy.

The top-level mobile tabs are `Now`, `Agents`, and `Settings`. Agents is the canonical project-and-agent workspace: it filters agents and project metadata, keeps zero-agent projects reachable for first-agent creation, and links to project detail routes. Legacy `#search`, `#projects`, and `#setup` hashes are redirected to the closest surviving tab. Detail routes use hash navigation such as `#agent/{key}`, `#project/{key}`, and `#project/{key}/action/{action}`. The footer nav is fixed on top-level routes, hides while scrolling down, shows again while scrolling up, and is hidden on detail subpages.

Browser push notification work is tracked in [WEB_PUSH_PLAN.md](./WEB_PUSH_PLAN.md), and the current grouping, silent-notification, and PWA badge behavior is summarized in [WEB_PUSH_BEHAVIOR.md](./WEB_PUSH_BEHAVIOR.md). Push can use a Tailscale MagicDNS domain when it is served over HTTPS, preferably with Tailscale Serve or Tailscale Funnel. Plain HTTP MagicDNS URLs show a soft warning, but the UI still lets the user try enabling notifications when the browser exposes the required push APIs.

The Remote server polls managed-agent state while it is running and sends one push notification when an agent requires response or finishes. Agent notifications share the `hq:agents` browser notification tag so repeated agent updates replace the previous Tycho agent notification instead of piling up; input-required notifications renotify audibly, while routine finish notifications are marked silent. Agent payloads also carry the current unread-agent count so browsers with the Badging API can show the count on the installed PWA app icon. Agent notification clicks open `/#agent/{key}`.

Use `.env.sample` as the template for local runtime environment values such as `TYCHO_WEB_PUSH_VAPID_SUBJECT`. Real `.env` files are gitignored, and `tycho serve` loads `.env` automatically on startup. Values already set in the process environment take precedence over `.env`; public runtime overrides use the `TYCHO_*` prefix.

Auto-refresh uses polling with backoff:

- `/agents`, `/projects`, and `/setup` are polled while the page is visible.
- The selected agent's `/conversation` is fetched only when that agent's `revision` changes.
- Polling uses the server-advertised refresh intervals from `/setup`, slows down when agents are idle, pauses while the browser tab is hidden, and backs off after network errors.
- Start, stop, send, and project action operations trigger an immediate refresh.

## Screenshot Safety

MagicDNS names and Tailscale IPs are private to the tailnet unless the
device is shared, exposed with Funnel, or otherwise made reachable, so
showing the URL does not by itself publish the service to the internet.
Still, public screenshots should redact the MagicDNS URL, Tailscale IP,
and QR code because they reveal tailnet metadata such as the device name,
tailnet name, port, and UI path. The QR code is just the URL encoded
visually.

For public docs or blog posts, use examples like:

```text
http://hq.tailnet-name.ts.net:7373/
http://100.x.y.z:7373/
```

## Authentication

Authentication is optional for localhost. If `TYCHO_REMOTE_TOKEN` is unset or blank, requests are accepted without auth.

When `tycho serve` binds to a non-loopback host without a token, startup logs print a warning. The Settings screen also marks public Remote UI URLs as `token recommended`.

Set `TYCHO_REMOTE_TOKEN` before using a Tailscale MagicDNS URL or another non-local interface:

When `TYCHO_REMOTE_TOKEN` is set, clients must send a bearer token:

```bash
TYCHO_REMOTE_TOKEN="$(ruby -rsecurerandom -e 'puts SecureRandom.hex(24)')" tycho serve
```

```bash
curl http://127.0.0.1:7373/health \
  -H "Authorization: Bearer $TYCHO_REMOTE_TOKEN"
```

Unauthorized requests return `401`:

```json
{
  "error": "Unauthorized"
}
```

## Console Logs

While running, the server prints request logs to stdout:

```text
[Remote] 00:14:22 Remote server listening on http://127.0.0.1:7373
[Remote] 00:14:26 GET /health 200 4.2ms
[Remote] 00:14:31 POST /agents/web-charlie-agent-8/messages 200 18.7ms
```

The same lines are written to `~/.tycho/logs/hq.log` through `HQ.logger`.

## Response Shapes

Agent responses use this shape:

```json
{
  "key": "web-charlie-agent-8",
  "name": "Web Charlie",
  "project_key": "web",
  "template_key": "implementer",
  "workspace": "/Users/example/Code/web",
  "prompt": "Work on the next task.",
  "sandbox_mode": "danger-full-access",
  "agent": "codex",
  "status": "idle",
  "running": false,
  "unread": false,
  "run_count": 2,
  "started_at": "2026-05-08T00:14:31+07:00",
  "finished_at": "2026-05-08T00:17:03+07:00",
  "pid": null,
  "last_exit_code": 0,
  "last_result": "success",
  "summary": "Completed successfully",
  "session_id": "019db38a-99ca-7109-9f26-be991d1a4708",
  "log_path": "/Users/example/Code/hq/~/.tycho/logs/agents/web-charlie-agent-8.raw.log",
  "memory_path": "/Users/example/Code/hq/~/.tycho/logs/agents/web-charlie-agent-8.memory.jsonl",
  "revision": "1778247891.123456"
}
```

Conversation entries are projected from `AgentChatLog#chat_blocks` when available. If no blocks are available, the server falls back to `ManagedAgent#conversation_messages`.

```json
[
  {
    "kind": "message",
    "role": "user",
    "content": "Read the code first."
  },
  {
    "kind": "tool_call",
    "content": "Bash: bundle exec ruby test/rendering_test.rb",
    "tool_name": "Bash"
  }
]
```

## Endpoints

| Method | Path | Description |
|--------|------|-------------|
| `GET` | `/` | Health check alias. |
| `GET` | `/health` | Health check. |
| `GET` | `/agents` | List active managed agents. |
| `POST` | `/agents` | Create a managed agent. |
| `GET` | `/agents/{key}` | Read one managed agent. |
| `PATCH` / `PUT` | `/agents/{key}` | Edit one idle managed agent. |
| `DELETE` | `/agents/{key}` | Archive one idle managed agent. |
| `POST` | `/agents/archive` | Archive multiple idle managed agents from a `keys` array, returning archived, skipped, and failed keys. |
| `GET` | `/agents/{key}/conversation` | Read the rendered conversation blocks for one agent. |
| `PUT` | `/agents/{key}/reading` | Mark one agent as read after the user opens its conversation. |
| `POST` | `/agents/{key}/messages` | Append a user prompt to one agent. |
| `POST` | `/agents/{key}/prompt` | Alias for appending a user prompt. |
| `POST` | `/agents/{key}/start` | Start one agent run. |
| `POST` | `/agents/{key}/stop` | Send `TERM` to one running agent. |
| `POST` | `/agents/{key}/clone` | Clone one managed agent, optionally archiving the source. |
| `POST` | `/agents/{key}/archive` | Archive one idle managed agent. |
| `GET` | `/push/config` | Read browser push readiness and VAPID public key. |
| `POST` | `/push/subscriptions` | Save or refresh one browser push subscription. |
| `DELETE` | `/push/subscriptions` | Disable one browser push subscription. |
| `POST` | `/push/test` | Send a test notification to an enabled subscription. |
| `POST` | `/server/restart` | Restart the `tycho serve` Remote server process when restart is available. |
| `GET` | `/projects` | List active projects with health, latency, agent counts, and action state. |
| `GET` | `/projects/{key}` | Read one project detail payload. |
| `GET` | `/projects/{key}/actions` | List guarded action preflights for deploy, maintenance, and live. |
| `POST` | `/projects/{key}/actions` | Start a guarded project action from a request body `action`. |
| `GET` | `/projects/{key}/actions/{action}` | Read one guarded project action preflight. |
| `POST` | `/projects/{key}/actions/{action}` | Start one guarded project action with `confirm: true`. |
| `GET` | `/projects/{key}/skills/{agent}` | Discover skills for a project workspace and agent harness. |
| `GET` | `/attachments/{id}` | Read normalized attachment metadata and inline preview content when available. |
| `GET` | `/attachments/{id}/blob` | Stream the attachment file bytes for image and binary previews. |
| `GET` | `/setup` | Read Remote UI readiness, auth, Tailscale, config, log, and refresh metadata. |
| `POST` | `/setup/welcome` | Create the first-run welcome sandbox project under `~/.tycho/workspaces/welcome`. |
| `GET` | `/search` | Return agent and project payloads for compatibility with older client-side search flows. |
| `GET` | `/`, `/ui`, `/ui.css`, `/ui.js` | Serve the Remote UI. `/ui` remains a compatibility alias. |
| `GET` | `/favicon.svg`, `/favicon.ico` | Serve the Remote UI favicon. |

## Endpoint Details

### `GET /health`

Returns basic process-visible counts:

```json
{
  "status": "ok",
  "agents": 4,
  "projects": 12
}
```

### `POST /server/restart`

Requests a Remote server self-restart. The endpoint is authenticated like other JSON API endpoints. When restart is available, the response is sent before the server exits:

```json
{
  "restarting": true,
  "command": "/Users/example/.local/share/mise/installs/ruby/3.4.7/bin/ruby"
}
```

When restart is unavailable, the endpoint returns `409`.

### `GET /agents`

Returns active agents:

```json
{
  "agents": [
    {
      "key": "web-charlie-agent-8",
      "name": "Web Charlie",
      "status": "idle",
      "running": false
    }
  ]
}
```

### `POST /agents`

Creates a new agent from a project template and persists it to `~/.tycho/logs/managed_agents.json`.

Request:

```json
{
  "project_key": "web",
  "template_key": "implementer",
  "name": "Web Charlie",
  "prompt": "Work on the checkout bug.",
  "workspace": "/Users/example/Code/web",
  "sandbox_mode": "danger-full-access",
  "agent": "codex",
  "start": false
}
```

Required fields:

- `project_key`

Optional fields:

- `template_key`: defaults to the project's first template.
- `name`: defaults to the template-created name unless overridden.
- `prompt`: defaults to the selected template prompt unless overridden.
- `workspace`: defaults to the project path on create.
- `sandbox_mode`: defaults to the selected template sandbox mode.
- `agent`: one of `codex`, `claude`, or a configured `custom_harnesses` key.
- `start`: when truthy, starts the agent immediately after creation.

Response:

```json
{
  "agent": {
    "key": "web-agent-9",
    "name": "Web Charlie",
    "status": "idle",
    "running": false
  }
}
```

### `GET /agents/{key}`

Returns the agent payload:

```bash
curl http://127.0.0.1:7373/agents/web-charlie-agent-8
```

### `PATCH /agents/{key}`

Updates an idle agent. Running agents return `409`.

Request:

```json
{
  "name": "Web Charlie Follow-up",
  "prompt": "Continue from the checkout bug.",
  "agent": "codex"
}
```

Response:

```json
{
  "agent": {
    "key": "web-charlie-agent-8",
    "name": "Web Charlie Follow-up",
    "prompt": "Continue from the checkout bug."
  }
}
```

### `GET /agents/{key}/conversation`

Returns conversation blocks for the agent:

```bash
curl http://127.0.0.1:7373/agents/web-charlie-agent-8/conversation
```

Response:

```json
{
  "conversation": [
    {
      "kind": "message",
      "role": "user",
      "content": "Read the code first."
    }
  ]
}
```

### `GET /attachments/{id}`

Returns one normalized attachment payload. File attachments include `agent_key`, `format`, and `blob_path`; text and Markdown files inline `content` up to the preview limit.

```bash
curl http://127.0.0.1:7373/attachments/att_abc123
```

Response:

```json
{
  "attachment": {
    "id": "att_abc123",
    "agent_key": "web-charlie-agent-8",
    "type": "file",
    "format": "markdown",
    "title": "Notes",
    "path": "/Users/example/project/docs/notes.md",
    "blob_path": "/attachments/att_abc123/blob",
    "content": "# Notes\n\n- Check deployment"
  }
}
```

### `GET /attachments/{id}/blob`

Streams the file bytes for a file attachment. The response uses the detected or declared content type and sets `X-Content-Type-Options: nosniff`.

```bash
curl http://127.0.0.1:7373/attachments/att_abc123/blob --output attachment.bin
```

### `PUT /agents/{key}/reading`

Marks an agent as read after the user has visibly visited its rendered conversation. This is the explicit Remote UI mutation for clearing `unread` in `~/.tycho/logs/managed_agents.json`; `GET /agents/{key}/conversation` remains read-only, and polling data is not treated as reading.

```sh
curl -X PUT http://127.0.0.1:7373/agents/web-charlie-agent-8/reading
```

### `POST /agents/{key}/messages`

Appends a user prompt. The agent is not started unless `start` is truthy.

Request:

```json
{
  "prompt": "Please continue with the next failing test.",
  "start": true
}
```

`content` is accepted as an alias for `prompt`.

Response:

```json
{
  "agent": {
    "key": "web-charlie-agent-8",
    "status": "running",
    "running": true
  },
  "conversation": [
    {
      "kind": "message",
      "role": "user",
      "content": "Please continue with the next failing test."
    }
  ]
}
```

Simple curl:

```bash
curl -X POST http://127.0.0.1:7373/agents/web-charlie-agent-8/messages \
  -H "Content-Type: application/json" \
  -d '{"prompt":"Please continue with the next failing test.","start":true}'
```

### `POST /agents/{key}/start`

Starts one agent run unless it is already running:

```bash
curl -X POST http://127.0.0.1:7373/agents/web-charlie-agent-8/start
```

### `POST /agents/{key}/stop`

Sends `TERM` to one running agent:

```bash
curl -X POST http://127.0.0.1:7373/agents/web-charlie-agent-8/stop
```

### `DELETE /agents/{key}`

Archives an idle agent by moving its log artifacts to `~/.tycho/logs/agents/archive/` and removing it from `~/.tycho/logs/managed_agents.json`. Running agents return `409`.

```bash
curl -X DELETE http://127.0.0.1:7373/agents/web-charlie-agent-8
```

Response:

```json
{
  "archived": true,
  "agent_key": "web-charlie-agent-8",
  "archive_path": "/Users/example/Code/hq/~/.tycho/logs/agents/archive/20260508-001431-web-charlie-agent-8"
}
```

### `POST /agents/archive`

Archives multiple idle agents from a `keys` array. Running agents are skipped and missing keys are reported without blocking idle agents in the same request.

```bash
curl -X POST http://127.0.0.1:7373/agents/archive \
  -H "Content-Type: application/json" \
  -d '{"keys":["web-charlie-agent-8","web-delta-agent-3"]}'
```

Response:

```json
{
  "archived": [
    {
      "agent_key": "web-charlie-agent-8",
      "archive_path": "/Users/example/.tycho/logs/agents/archive/20260508-001431-web-charlie-agent-8"
    }
  ],
  "skipped": [
    {
      "agent_key": "web-delta-agent-3",
      "reason": "running"
    }
  ],
  "failed": [],
  "archive_count": 1
}
```

### `POST /agents/{key}/clone`

Creates a fresh managed agent from an existing one with a new key, empty logs, no runs, and no native session id. Form fields such as `name`, `template_key`, `agent`, `workspace`, `prompt`, and `sandbox_mode` may be supplied to edit the clone before it is saved. Set `archive_source: true` to archive the source agent after the clone is created.

```bash
curl -X POST http://127.0.0.1:7373/agents/web-charlie-agent-8/clone \
  -H 'Content-Type: application/json' \
  -d '{"name":"Web agent","archive_source":true}'
```

Response:

```json
{
  "agent": {
    "key": "web-agent-9",
    "name": "Web agent"
  },
  "source_agent_key": "web-charlie-agent-8",
  "archived": true,
  "archive_path": "/Users/example/Code/hq/~/.tycho/logs/agents/archive/20260508-001431-web-charlie-agent-8"
}
```

### `GET /push/config`

Returns browser push readiness for the Remote UI Settings screen. The public VAPID key is safe for the browser; the private key remains server-side.

```json
{
  "configured": true,
  "public_key": "BD...",
  "subject": "mailto:tycho@example.com",
  "subscription_count": 1,
  "secure_context_required": true,
  "localhost_allowed": true,
  "magic_dns_https_required": true
}
```

### `POST /push/subscriptions`

Saves or refreshes one browser push subscription. Send the browser's `PushSubscription.toJSON()` payload:

```json
{
  "endpoint": "https://push.example/subscription/1",
  "keys": {
    "p256dh": "base64url-key",
    "auth": "base64url-auth"
  }
}
```

### `DELETE /push/subscriptions`

Disables one browser push subscription by endpoint:

```json
{
  "endpoint": "https://push.example/subscription/1"
}
```

### `POST /push/test`

Sends a test notification to an enabled subscription. Automatic agent-transition notifications are sent by the Remote server poll loop, de-duplicated in `~/.tycho/logs/push_notifications.json`, grouped through a shared notification tag, and mirrored to the installed-app badge when the browser exposes the Badging API.

```json
{
  "endpoint": "https://push.example/subscription/1"
}
```

### `GET /projects`

Returns active projects after refreshing metadata and health:

```json
{
  "projects": [
    {
      "key": "web",
      "name": "Web",
      "group": "Core",
      "status": "healthy",
      "apps_enabled": true,
      "app_status": "running",
      "health_status": "healthy",
      "latency_ms": 42,
      "maintenance": false,
      "agent_count": 2,
      "unread_agent_count": 1,
      "running_agent_count": 0
    }
  ]
}
```

### `GET /projects/{key}`

Returns project detail data for the mobile detail view, including branch/commit metadata, Kamal deploy details, versions, agent template summaries, action log path, managed-agent count, and recent agent summary.

### `GET /projects/{key}/actions/{action}`

Returns a guarded action preflight for `deploy`, `maintenance`, or `live`:

```json
{
  "action": "deploy",
  "label": "deploying",
  "can_start": true,
  "checks": [
    {
      "key": "kamal",
      "label": "Kamal deployment configured",
      "passed": true
    }
  ],
  "consequences": [
    "Starts a detached Kamal deploy for the selected project."
  ]
}
```

### `POST /projects/{key}/actions/{action}`

Starts a detached Kamal action through `KamalAction`. The request must include confirmation:

```json
{
  "confirm": true
}
```

Without confirmation the server returns `400`. If a preflight check blocks the action, the server returns `409`.

### `GET /projects/{key}/skills/{agent}`

Discovers skills for the project workspace and agent harness, reusing `HQ::SkillDiscovery`.

### `GET /setup`

Returns Remote UI readiness metadata: local URL, public Tailscale/MagicDNS URL, auth state, counts, harness readiness, schema/config readiness, log/storage summary, refresh intervals, and safety defaults.

When no projects are configured, the payload includes onboarding metadata so the
Remote UI can render a first-run screen without the normal header or footer.

### `POST /setup/welcome`

Creates the first-run welcome sandbox at `~/.tycho/workspaces/welcome`, appends a
`welcome` project to `hq.yml`, and returns the project detail payload. This route
is only available before any project is configured.

### `GET /search`

Returns the same agent and project payloads used by the client-side search screen.

## Error Responses

Errors use a simple JSON shape:

```json
{
  "error": "Unknown agent: web-charlie-agent-8"
}
```

Common statuses:

- `400`: bad JSON body, missing required value, or unsupported agent harness.
- `401`: missing or invalid bearer token when `TYCHO_REMOTE_TOKEN` is set.
- `404`: route, project, or agent was not found.
- `409`: attempted to edit, archive, or clone-and-archive a running agent.
- `500`: unexpected server error.

## Operational Notes

- The server is single-process and handles one request at a time.
- It should be treated as a local development/control API, not a public internet service.
- Each request creates a fresh `RemoteService`, reloads config, and reads current agent state from disk.
- Agent start/stop behavior is still owned by `ManagedAgent`; the server does not implement separate process supervision.
- Request bodies that are absent or empty are treated as `{}`.
- Query strings are ignored by the router.
