# Remote Sessions Server

The Remote Sessions server is HQ's local JSON API for inspecting and controlling managed agents without opening the Bubbletea TUI. It is intentionally small and local-first: the API reuses the same `AgentStore` and `ManagedAgent` domain objects as the TUI, so agent state continues to live in `~/.tycho/logs/managed_agents.json` and per-agent artifacts under `~/.tycho/logs/agents/`.

## Tech Stack

- Runtime: Ruby stdlib only for the server loop.
- Transport: HTTP/1.1 over `TCPServer` from `socket`.
- Body format: JSON request and response bodies.
- Routing: manual method/path dispatch in `HQ::RemoteServer`.
- Domain layer: `HQ::RemoteService`, backed by `Registry`, `Project`, `AgentStore`, `ManagedAgent`, and `AgentChatLog`.
- QR rendering: `rqrcode` generates the QR matrix; HQ renders a compact terminal half-block QR for the remote UI URL.
- Logging: request/lifecycle lines are printed to stdout and also sent to `HQ.logger`, which writes to `~/.tycho/logs/hq.log`.

No Rack, Puma, WEBrick, or external webserver gem is used.

## Running

Start the server:

```bash
tycho serve
```

Start it as a background daemon after startup details and the QR code
are printed:

```bash
tycho serve daemon
```

Daemon mode binds the server first, prints the same Remote UI URL and QR
code, then returns control to the shell. After detaching, request and
lifecycle lines continue in `~/.tycho/logs/remote_server_daemon.log` and
`~/.tycho/logs/hq.log`.

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
7. The browser polls `/setup` until the replacement process is reachable again, then refreshes `/agents`, `/projects`, and `/setup`.

If a `RemoteServer` is constructed without a restart command, `POST /server/restart` returns `409 Conflict`. That keeps test and embedded server instances from accidentally attempting to replace their process.

## Web UI

The remote server also serves a lightweight mobile web UI:

```text
http://127.0.0.1:7373/
```

The UI is plain server-served HTML/CSS/JavaScript, with no frontend build step or JavaScript package dependencies. It uses the existing JSON endpoints and stores only the UI-serving host's optional bearer token in browser local storage for `Authorization: Bearer ...` API requests. Peer credentials are external or host-managed as described below.

New managed agents use timestamp-based keys such as `web-agent-20260712-120501-123456`. Existing numeric keys remain valid and load unchanged.

Home-screen launches are treated as normal browser sessions, but mobile browsers can be more aggressive about reusing an old app shell. The root UI references `/ui.css` and `/ui.js` with a content digest query string, and `POST /server/restart` is the explicit cache-reset path: the restart response sends cache-reset headers, the browser clears Cache Storage when available, and the UI reloads itself with a restart query string after the replacement server responds to setup requests.

The top-level mobile tabs are `Now`, `Agents`, and `Settings`. Agents is the canonical project-and-agent workspace: it filters agents and project metadata, keeps zero-agent projects reachable for first-agent creation, and links to project detail routes. Project detail can open a read-only workspace browser at `#project/{key}/files`; directory and selected-file query state stays in browser history, and project ownership continues through the multiserver broker. Legacy `#search`, `#projects`, and `#setup` hashes are redirected to the closest surviving tab. Detail routes use hash navigation such as `#agent/{key}`, `#project/{key}`, and `#project/{key}/action/{action}`. The footer nav is fixed on top-level routes, hides while scrolling down, shows again while scrolling up, and is hidden on detail subpages.

Settings → Configuration explains that response style is shared writing guidance for tone, clarity, and prose rather than task instructions. A missing policy stays collapsed behind **Add response style**. Once saved, the compact summary shows an excerpt, **Edit response style**, and a trash action that removes the global policy after confirmation. Opening the editor prefills existing content, while saving or canceling returns to the compact summary. Conversation Settings records whether the displayed agent run used the **Global**, **Custom**, or **Disabled** response-style source and combines model and reasoning effort into one row. It reads and writes `~/.tycho/config/response_style.md` by default, or `TYCHO_RESPONSE_STYLE_PATH` when configured. Saves use Tycho's atomic file store and retain the previous file as `response_style.md.bak`; focused edits survive polling refreshes.

Settings → Skills reports the bundled Tycho skill as missing, installed, outdated, blocked, or errored for Codex, Claude Code, and OpenCode. Install and update are separate confirmed actions, target each harness's official personal skill directory, and report the exact skills changed. See [TYCHO_SKILLS.md](./TYCHO_SKILLS.md) for source, ownership, checksum, path, and verification details.

The Conversation composer has a full-screen editor for longer prompts. It opens as an accessible modal with a constrained writing canvas, focus containment, visual-viewport sizing for mobile keyboards, and only an X close control—no editor header or explanatory copy. Inline and full-screen Conversation and inquiry forms are stable islands during polling: surrounding conversation state refreshes without detaching, blurring, or reconstructing the live form control. Draft text, focus, selection, attachments, and editor mode therefore survive same-route polling refreshes. Drafts save locally while typing and survive reloads; route navigation, sending, the X control, or one Escape press exits full screen without discarding the draft.

Structured inquiry forms use the same full-screen interaction and always end with an optional **Leave feedback** textarea. The submitted JSON answer preserves every declared inquiry field and appends `user_feedback` as a reserved final field, using `null` when left blank. Historical inquiry responses without that key receive the same null row at render time, so the conversation consistently reflects the form.

Scheduled agent conversations show a calendar-check control beside the header context menu. Its menu exposes **Run now**, **Pause** or **Resume** according to current schedule state, and **Edit schedule** without requiring a trip back to Now. Run actions use the Lucide sport-shoe icon consistently in the header and schedule list. Associated-agent icons normally follow the agent result color, while stopped schedules override them to red and paused schedules to warning yellow.

An idle, unscheduled conversation can become a temporary loop from **More → Loop session**. The prefilled form defaults to the configured interval and end-of-day cutoff, keeps its run prompt empty until the user chooses or writes one, and lets a configured prompt template fill the editable preview. Saving adopts the existing conversation as a normal schedule, adds the standard schedule system prompt, runs it immediately, and starts the scheduler daemon when needed. The loop then appears in Now with the other schedules and stops after its cutoff.

Attachment detail views group utility actions under an ellipsis menu. File attachments expose separate **Copy content** (when supported), **Copy absolute path**, **Download file**, and **Refresh cache** actions alongside delete; link attachments expose **Copy link**. Refresh cache always re-reads file content and image previews from the source path. The page header places a view menu beside the page context menu; it selects exactly one layout—**Balanced**, **Widen detail**, or **Full view**—and its trigger icon reflects the active layout.

Agent create, edit, and clone forms select **Response style** independently beside **Prompt Template**. **Global** uses the active Settings policy even when the prompt template is named Custom, **Prompt template** uses a configured template override, and **Disabled** omits response-style guidance.

## Multiserver Broker

One Remote UI combines agents and projects from the local `tycho serve` instance and configured peer Remote servers. The browser still talks only to the server that served the UI; that local server returns the cached combined catalog and brokers each resource request to its owner. This avoids browser CORS and lets the local broker apply either server-side configured peer credentials or browser-local peer credentials.

Configure peers in `~/.tycho/config/hq.yml`:

```yaml
remote_servers:
  - key: office-mac
    name: Office Mac
    icon: computer
    url: http://office-mac.tailnet-name.ts.net:7373
    token_env: TYCHO_OFFICE_MAC_REMOTE_TOKEN
  - key: laptop
    name: Laptop
    icon: server
    url: http://laptop.tailnet-name.ts.net:7373
    token_env: TYCHO_LAPTOP_REMOTE_TOKEN
```

Configure the Loop session defaults and reusable prompts in Settings → Automation, or directly in `~/.tycho/config/hq.yml`:

```yaml
session_loops:
  interval_minutes: 10
  end_time: "23:59"
  prompt_templates:
    - key: pull-request-review
      name: Wait for PR review
      prompt: Check the pull request for approvals, reviews, and comments. Address actionable feedback, run the relevant checks, and update the pull request. If nobody has acted, return no_action_needed.
```

`key` must be stable and URL-safe. It is also the local credential identity. `url` must be an `http` or `https` base URL without embedded credentials. `icon` accepts `server` or `computer` and defaults to `server`. Use `token_env` for an explicit external credential override or enroll a Tycho-managed credential with `tycho server login`. The synthetic `local` server is always present and cannot be redefined in config.

The Settings screen manages the configured server list; the default local server is always present. Each peer row can edit its display name, choose the Lucide **Server** or **Computer** icon, and explicitly **Forget cached data** without changing the remote server itself. The Agents screen combines agents and projects from all servers and offers an **All servers** filter. Local ownership uses a home icon without a visible label; peers show their configured icon and name. Resource health remains explicit as **Online**, **Offline**, **Stale**, or **Token required**. There is no global active-server switch.

For ad hoc peers, open Settings, use the **Add server** toggle in the **Servers** header, and enter a display name plus a loopback or Tailscale MagicDNS URL such as `tycho-peer` and `http://127.0.0.1:7374/` or `http://vps-cd946cb7.tail952bf7.ts.net:7373`. If the peer requires a bearer token, enter it in **Remote token**. The UI verifies the peer through the agent API, writes the peer metadata to `remote_servers` in `~/.tycho/config/hq.yml`, reloads the registry, and refreshes that peer's resource catalog. Removing a non-local server from the list also removes it from `hq.yml`. Ad hoc UI-added peers are intentionally limited to loopback and Tailscale MagicDNS hosts; edit `remote_servers` directly for broader LAN, public, or credentialed peers.

UI-entered remote tokens are not written to `hq.yml`. Saving one verifies it against the selected peer, atomically writes it to the UI-serving Tycho host's private credential file, and removes the browser-local copy only after persistence succeeds. Existing browser tokens under `hq.remote.serverTokens` remain usable for promotion and are sent only to their owning peer as `X-Tycho-Remote-Server-Token`; a failed promotion leaves that browser copy intact. The UI's own bearer token remains separate under `hq.remote.token` and authenticates the browser to the server that served the UI.

## Remote CLI Control

Project inspection and managed-agent lifecycle commands can target one
configured peer directly. The CLI connects to that peer's `url`; it does not
depend on a running local broker or any browser state.

```bash
tycho project list --server office-mac [--json]
tycho project show <project-key> --server office-mac [--json]
tycho agent list [<project-key>] --server office-mac [--json]
tycho agent status <agent-key> --server office-mac [--json]
tycho agent create <project-key> <prompt> --server office-mac [--run] [--json]
tycho agent run <agent-key> --server office-mac [--json]
tycho agent send <agent-key> <message> --server office-mac [--json]
tycho agent stop <agent-key> --server office-mac [--json]
tycho agent archive <agent-key> --server office-mac [--json]
```

The selected key must exist under `remote_servers`. Requests use the credential
selected for that exact entry:

1. If `token_env` is configured, its environment value wins. A missing value is
   an error; Tycho does not fall through to its store.
2. Otherwise, Tycho uses the server key's entry from
   `~/.tycho/config/remote_credentials.json`.
3. Otherwise, an inline `token` is accepted temporarily with a migration
   warning. This fallback will be removed in v0.11.0.

The credential file is local to each Tycho installation, written atomically,
and mode `0600`. It stores one bearer token per server key plus verification
metadata. Status output includes the source, state, bound origin, and timestamps
but no token or fingerprint. A verified origin is the lowercased scheme and
host plus effective port; URL paths do not affect the binding.

```bash
tycho server login office-mac
tycho server login office-mac --no-verify
tycho server status [office-mac] [--json]
tycho server verify office-mac
tycho server logout office-mac
tycho server migrate office-mac
tycho server migrate --all
```

`login` reads the token from a hidden prompt and normally verifies it before
saving. `--no-verify` supports offline enrollment and records the credential as
unverified until its first successful authenticated request. `verify` can
recover an unverified or rejected credential. `logout` deletes only the
Tycho-stored token and reports an external source without changing it. Migration
moves inline values out of `hq.yml` and stores them as unverified. Without
`--server`, project and agent commands retain their local behavior.

Remote failures use explicit messages for unknown keys, connection failures,
timeouts, authentication rejection, unsupported endpoints, and non-success API
responses, missing external variables, origin mismatches, and credentials that
remain rejected until explicit verification. The CLI exits nonzero for each failure. Agent `run`, `send`, and
`stop` also enforce the same running/idle preconditions as their local forms.

Browser push notification work is tracked in [WEB_PUSH_PLAN.md](./WEB_PUSH_PLAN.md), and the current grouping, silent-notification, and PWA badge behavior is summarized in [WEB_PUSH_BEHAVIOR.md](./WEB_PUSH_BEHAVIOR.md). Push can use a Tailscale MagicDNS domain when it is served over HTTPS, preferably with Tailscale Serve or Tailscale Funnel. Plain HTTP MagicDNS URLs show a soft warning, but the UI still lets the user try enabling notifications when the browser exposes the required push APIs.

The Remote server polls managed-agent state while it is running and sends one push notification when an agent requires response or finishes. Structured `no_action_needed` outcomes stay quiet and do not mark the agent unread. Agent notifications share the `hq:agents` browser notification tag so repeated agent updates replace the previous Tycho agent notification instead of piling up; input-required notifications renotify audibly, while routine finish notifications are marked silent. Agent payloads also carry the current unread-agent count so browsers with the Badging API can show the count on the installed PWA app icon. Agent notification clicks open `/#agent/{key}`.

Use `.env.sample` as the template for local runtime environment values such as `TYCHO_WEB_PUSH_VAPID_SUBJECT`. Real `.env` files are gitignored. `tycho serve` loads both the install/repo `.env` and `~/.tycho/.env` automatically on startup, with `~/.tycho/.env` taking precedence over the install/repo file. Values already set in the process environment take precedence over both files; public runtime overrides use the `TYCHO_*` prefix.

Auto-refresh reads the in-memory `/servers/resources` catalog first, so slow or offline peers do not block list rendering. The broker atomically persists each peer's last successful compact snapshot in `~/.tycho/logs/remote_resources.json` with private file permissions. On startup it restores configured peers as stale before attempting network refreshes, so an offline peer's agents and projects survive a broker restart. Persisted snapshots have no age-based expiry while the peer remains configured.

A bounded background worker pool refreshes local and peer snapshots with short timeouts. Failed, unauthorized, incompatible, and incomplete responses retain the last successful snapshot and use exponential retry backoff. A valid response must contain both complete `agents` and `projects` arrays; it replaces the prior snapshot atomically, so resources missing from that successful response are treated as deleted or archived. Removing a peer or choosing **Forget cached data** removes its persisted snapshot.

- `/servers/resources` is polled while the page is visible.
- `/setup` and `/schedules` refresh separately as local server state.
- The selected agent's `/conversation` is fetched only when that agent's `revision` changes.
- Polling uses three server-advertised refresh intervals from `/setup`: active views every 5 seconds, idle views every 10 seconds, and hidden tabs every 30 seconds.
- Agent conversations, running agents, and pending server refreshes are active. The scheduler uses one interval at a time and backs off to 10 or 30 seconds after network errors.
- Start, stop, and send operations trigger an immediate refresh.

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
curl http://127.0.0.1:7373/agents \
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
[Remote] 00:14:26 GET /agents 200 4.2ms
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
| `GET` | `/agents` | List active managed agents. |
| `POST` | `/agents` | Create a managed agent. |
| `GET` | `/agents/{key}` | Read one managed agent. |
| `PATCH` / `PUT` | `/agents/{key}` | Edit one idle managed agent. |
| `DELETE` | `/agents/{key}` | Archive one idle managed agent. |
| `POST` | `/agents/archive` | Archive multiple idle managed agents from a `keys` array, returning archived, skipped, and failed keys. |
| `GET` | `/agents/{key}/conversation` | Read the rendered conversation blocks for one agent. |
| `GET` | `/agents/{key}/pull-requests` | List GitHub pull request links detected from one agent's attachments with snapshot freshness metadata. |
| `GET` | `/agents/{key}/pull-requests/{id}/diff` | Read one saved pull request diff snapshot. |
| `POST` | `/agents/{key}/pull-requests/{id}/refresh` | Fetch current PR metadata and patch content, then save a fresh diff snapshot. |
| `POST` | `/agents/{key}/pull-requests/refresh` | Refresh every detected pull request diff for one agent. |
| `POST` | `/github/auth/device` | Start Tycho GitHub App device authorization and return the public user code. |
| `POST` | `/github/auth/device/{id}/poll` | Poll one server-side device authorization without exposing its device code. |
| `DELETE` | `/github/auth` | Delete the local Tycho GitHub App session; authenticated `gh` compatibility remains available. |
| `PUT` | `/agents/{key}/reading` | Mark one agent as read after the user opens its conversation. |
| `POST` | `/agents/{key}/messages` | Append a user prompt to one agent. |
| `POST` | `/agents/{key}/prompt` | Alias for appending a user prompt. |
| `POST` | `/agents/{key}/start` | Start one agent run. |
| `POST` | `/agents/{key}/stop` | Send `TERM` to one running agent. |
| `POST` | `/agents/{key}/clone` | Clone one managed agent, optionally archiving the source. |
| `POST` | `/agents/{key}/archive` | Archive one idle managed agent. |
| `POST` | `/agents/{key}/loop-schedule` | Adopt one idle agent as a temporary recurring schedule and run it immediately. |
| `GET` | `/metrics` | Query normalized run and native-session metrics with inclusive `from`, exclusive `to`, timezone, and attribution filters. |
| `POST` | `/metrics/backfill` | Idempotently backfill metrics from durable manifests and optional legacy raw telemetry. |
| `GET` | `/settings/session-loops` | Read Loop session interval, cutoff, and prompt-template defaults. |
| `PATCH` | `/settings/session-loops` | Save Loop session defaults in `hq.yml`. |
| `GET` | `/push/config` | Read browser push readiness and VAPID public key. |
| `POST` | `/push/status` | Check whether one browser endpoint is currently enabled. |
| `POST` | `/push/subscriptions` | Save or refresh one browser push subscription. |
| `DELETE` | `/push/subscriptions` | Disable one browser push subscription. |
| `POST` | `/push/test` | Send a test notification to an enabled subscription. |
| `POST` | `/server/restart` | Restart the `tycho serve` Remote server process when restart is available. |
| `GET` | `/servers` | List the local server and configured broker targets. |
| `GET` | `/servers/resources` | Read the cached combined agent/project catalog and per-server health. |
| `DELETE` | `/servers/:server_key/resources` | Forget one peer's persisted agents and projects without changing the peer configuration or remote data. |
| `POST` | `/servers/resources/refresh` | Queue bounded background refreshes for all configured servers. |
| `POST` | `/servers/{key}/resources/refresh` | Queue one background catalog refresh. |
| `POST` | `/servers` | Add or update one loopback or Tailscale MagicDNS Remote server in `remote_servers` inside `hq.yml`. |
| `PATCH` | `/servers/{key}` | Update one peer server's display name and `server` or `computer` icon. |
| `DELETE` | `/servers/{key}` | Remove one non-local Remote server from `remote_servers` inside `hq.yml`. |
| `POST` | `/servers/{key}/credentials` | Verify a peer bearer token, save it in the UI-serving host's private credential store, and return metadata without the token. |
| `GET` / `POST` / `PUT` / `PATCH` / `DELETE` | `/servers/{key}/agents/{path}` | Forward an agent-owned request to one peer. |
| `GET` / `POST` / `PUT` / `PATCH` / `DELETE` | `/servers/{key}/projects/{path}` | Forward a project-owned request to one peer. |
| `GET` / `POST` / `PUT` / `PATCH` / `DELETE` | `/servers/{key}/attachments/{path}` | Forward an attachment-owned request to one peer. |
| `GET` | `/projects` | List active projects with metadata and agent counts. |
| `GET` | `/projects/{key}` | Read one project detail payload. |
| `GET` | `/projects/{key}/skills/{agent}` | Discover skills for a project workspace and agent harness. |
| `GET` | `/skills` | Read Tycho-owned skill installation status for supported harnesses. |
| `POST` | `/skills/{harness}/install` | Install missing Tycho skills after explicit confirmation. |
| `POST` | `/skills/{harness}/update` | Update outdated, provably Tycho-owned skills after explicit confirmation. |
| `GET` | `/attachments/{id}` | Read normalized attachment metadata and inline preview content when available. |
| `GET` | `/attachments/{id}/blob` | Stream the attachment file bytes for image and binary previews. |
| `GET` | `/setup` | Read Remote UI readiness, auth, Tailscale, config, log, and refresh metadata. |
| `POST` | `/setup/welcome` | Create the first-run welcome sandbox project under `~/.tycho/workspaces/welcome`. |
| `GET` | `/search` | Return agent and project payloads for compatibility with older client-side search flows. |
| `GET` | `/`, `/ui`, `/ui.css`, `/ui.js` | Serve the Remote UI. `/ui` remains a compatibility alias. |
| `GET` | `/favicon.svg`, `/favicon.ico` | Serve the Remote UI favicon. |

For peer resource routes, the browser may send `X-Tycho-Remote-Server-Token` when that peer's token lives in browser local storage. The broker converts it to the peer request's `Authorization: Bearer ...` header and does not persist it. The compatibility `/servers/{key}/proxy/{path}` route accepts only the same agent, project, and attachment roots; server-level paths are rejected.

## Endpoint Details

### `POST /server/restart`

Requests a Remote server self-restart. The endpoint is authenticated like other JSON API endpoints. When restart is available, the response is sent before the server exits:

```json
{
  "restarting": true,
  "command": "/usr/local/bin/ruby"
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
  "model": "gpt-5.1-codex-max",
  "reasoning_effort": "high",
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
- `model`: optional free-form per-agent model. Omit to inherit the template/project default; send an empty string when editing to clear the agent-level value.
- `reasoning_effort`: optional free-form per-agent effort. Omit to inherit the template/project default; send an empty string when editing to clear the agent-level value.
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
    "content": "# Notes\n\n- Check follow-up work"
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

Creates a fresh managed agent from an existing one with a new key, empty logs, no runs, and no native session id. Form fields such as `name`, `template_key`, `agent`, `model`, `reasoning_effort`, `workspace`, `prompt`, and `sandbox_mode` may be supplied to edit the clone before it is saved. Set `archive_source: true` to archive the source agent after the clone is created.

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

### `POST /push/status`

Checks the current browser's subscription without exposing its capability URL in a query string:

```json
{
  "endpoint": "https://push.example/subscription/1"
}
```

The response includes `subscribed`, the global `subscription_count`, and redacted delivery diagnostics for that endpoint: subscription ID, provider host, browser user agent, lifecycle timestamps, last provider response code, last error class, failure count, and disabled time. The full endpoint and encryption keys are never returned. The Remote UI uses the endpoint-specific result to show the correct controls when other devices are also subscribed.

### `DELETE /push/subscriptions`

Disables one browser push subscription by endpoint:

```json
{
  "endpoint": "https://push.example/subscription/1"
}
```

### `POST /push/test`

Sends a test notification to an enabled subscription. Automatic agent-transition notifications are sent by the Remote server poll loop, de-duplicated in `~/.tycho/logs/push_notifications.json`, grouped through a shared notification tag, and mirrored to the installed-app badge when the browser exposes the Badging API.

`sent: 1` means the push provider returned HTTP 2xx. It does not prove that the service worker received the payload or that Windows displayed it. Provider response codes and acceptance/failure times are persisted with the subscription and logged with a hashed endpoint label.

```json
{
  "endpoint": "https://push.example/subscription/1"
}
```

### `GET /projects`

Returns active projects after refreshing metadata:

```json
{
  "projects": [
    {
      "key": "web",
      "name": "Web",
      "group": "Core",
      "status": "configured",
      "agent_count": 2,
      "unread_agent_count": 1,
      "running_agent_count": 0
    }
  ]
}
```

### `GET /projects/{key}`

### `GET /projects/{key}/workspace?path={relative}&offset={n}&limit={n}`

Returns one bounded, deterministically sorted page of safe directory entries. Paths in requests and responses are relative to the project's canonical workspace root. The server rejects absolute, traversing, encoded, NUL-containing, unavailable, and escaping-symlink paths; hides VCS internals, dependency/build/cache directories, and sensitive names; and never returns the host workspace path. The default page size is 100, the maximum is 200, and directories above the deterministic 5,000-entry scan cap return a sanitized size error.

### `GET /projects/{key}/workspace/preview?path={relative}`

Returns a UTF-8-safe text preview up to 256 KB. Binary, oversized, sensitive, missing, and unreadable files return explicit sanitized errors. Both workspace endpoints are read-only and remain project-scoped when brokered to a peer server.

### `GET /projects/{key}/skills/{agent}`

Discovers skills for the project workspace and agent harness, reusing `HQ::SkillDiscovery`.

### `GET /setup`

Returns Remote UI readiness metadata: local URL, public Tailscale/MagicDNS URL, auth state, counts, harness readiness, skill installation status, schema/config readiness, log/storage summary, refresh intervals, and safety defaults. Harness readiness entries may include `model_suggestions`, `reasoning_effort_suggestions`, and `catalog_source`; these are UI hints only and are not validation allowlists.

### `GET /skills`

Returns the source/version/verification guidance and missing, installed, outdated, blocked, or error state for Codex, Claude Code, and OpenCode. Paths are resolved against the Tycho server user's home directory.

### `POST /skills/{harness}/install`

Installs missing Tycho skills into the selected harness. The JSON body must contain `{"confirmed":true}`. A successful response includes `result.changed_skills`; a repeated install of a current version returns an empty list.

### `POST /skills/{harness}/update`

Updates an outdated skill only when its Tycho ownership marker and installed checksums prove that no local edits would be overwritten. The JSON body must contain `{"confirmed":true}`. Unowned collisions and locally edited managed skills return `409` without changing files.

When no projects are configured, the payload includes onboarding metadata so the
Remote UI can render a first-run screen without the normal header or footer.

### `GET /settings/response-style`

Returns the active global response-style file as `response_style`, including its `path`, `content`, UTF-8 byte count, and `exists` state. A missing file returns an empty, addable configuration instead of an error. The endpoint resolves `TYCHO_RESPONSE_STYLE_PATH` first and otherwise uses `~/.tycho/config/response_style.md`.

### `PATCH /settings/response-style`

Atomically replaces the global response-style file from a JSON `content` string and returns the saved `response_style` payload. Content may be empty and is limited to 64 KB. The previous file is retained with a `.bak` suffix.

### `DELETE /settings/response-style`

Removes the configured global response-style file and returns the empty `response_style` payload. An existing `.bak` file is retained for manual recovery.

### `GET /settings/session-loops`

Returns the default `interval_minutes`, local `end_time`, and editable prompt templates used by the Remote UI Loop session form.

### `PATCH /settings/session-loops`

Validates and saves Loop session defaults in `hq.yml`. Intervals must be between 1 and 59 minutes, cutoff times use `HH:MM`, and every template requires a name and prompt.

### `POST /agents/{key}/loop-schedule`

Adopts an idle, unscheduled managed agent as a normal schedule whose target includes that agent key. The request supplies a unique schedule key and name, interval, future ISO-8601 cutoff, and run message. Tycho appends the standard schedule system prompt to the existing session before the immediate first run, records the schedule in `schedules.yml`, and ensures the scheduler daemon is active for later runs. The schedule expires to `stopped` after its cutoff.

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

Skill mutation errors can also include `details.category` (`permission`, `network`, or `compatibility`) and `details.changed_skills` when an earlier skill completed before a later failure.

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
