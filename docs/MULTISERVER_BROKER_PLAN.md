# Multiserver Broker Plan

## Goal

Let one Tycho Remote UI connect to multiple Tycho Remote servers without browser CORS or client-side aggregation. The browser talks only to the local Remote server that served the UI. That server acts as a broker for requests to configured peer Remote servers.

This is not a mesh replication design. At any moment the UI is scoped to one active server, and mutations execute on that selected server.

## Architecture

### Server Directory

Add a configured list of broker targets. Keep the first implementation config-driven instead of UI-writable.

Suggested config shape:

```yaml
remote_servers:
  - key: office-mac
    name: Office Mac
    url: http://office-mac.tailnet-name.ts.net:7373
    token_env: TYCHO_OFFICE_MAC_REMOTE_TOKEN
  - key: laptop
    name: Laptop
    url: http://laptop.tailnet-name.ts.net:7373
    token_env: TYCHO_LAPTOP_REMOTE_TOKEN
```

Rules:

- `key` is stable and URL-safe.
- `url` is the target Tycho Remote server base URL.
- `token_env` is preferred over inline `token` for real use.
- The broker never accepts arbitrary proxy destinations from the browser.
- The local server is always available as a synthetic server entry.

### Broker API

Expose broker-only routes from the UI-serving Remote server:

```text
GET  /servers
ANY  /servers/:server_key/proxy/*
```

`GET /servers` returns local plus configured remote entries with display metadata. `/servers/:server_key/proxy/*` forwards the original HTTP method, JSON body, query string, and target-specific Authorization header to the selected server.

The existing local routes stay unchanged:

```text
GET /agents
GET /projects
POST /agents/:key/messages
...
```

The UI chooses between local and brokered paths:

```text
local active server:  /agents
remote active server: /servers/office-mac/proxy/agents
```

### UI State

The Remote UI stores only:

- active server key
- optional display preferences per server
- current route and existing form drafts

Remote credentials stay on the broker. The browser continues to authenticate only to the broker with the existing `TYCHO_REMOTE_TOKEN` flow.

Use server-scoped cache buckets for detail data that can collide:

- conversations
- project details
- project diffs
- pull request diffs
- attachment details and object URLs
- skills and preflight state

Top-level lists (`agents`, `projects`, `schedules`, `setup`) represent only the active server.

### Request Ownership

Agents, projects, schedules, and attachments are owned by the active server. The UI should show the active server name in the header/status area so operators know where a mutation will run.

No cross-server bulk archive, search, unread count, or dashboard aggregation in the first slice.

### Error Model

The broker normalizes target failures:

- missing configured server: `404`
- target unreachable: `502`
- target unauthorized: `502` with a clear broker-facing message
- target timeout: `504`
- target non-JSON error: preserve status and return a JSON wrapper

Target server response bodies should otherwise pass through unchanged.

## Tech Stack

### Ruby Backend

Use Ruby stdlib first:

- `Net::HTTP` for brokered requests
- `URI` for URL/path/query composition
- existing `HQ::Registry` or a small companion config loader for `remote_servers`
- existing `HQ::RemoteServer` manual routing style
- existing JSON response helpers

Add small focused classes rather than expanding `RemoteService` too much:

- `HQ::RemoteServerRegistry`: loads and validates configured target servers
- `HQ::RemoteClient`: forwards authenticated requests to one target server
- `HQ::RemoteBroker`: lists targets and performs proxy calls

### Frontend

Keep plain JavaScript with no build step:

- extend `lib/hq/remote_ui/assets/app.js`
- keep API helpers centralized
- resolve API paths through active server state
- add a compact server selector/status panel in the existing header/settings UI

### Security

- Do not proxy arbitrary URLs.
- Redact configured tokens from `/servers`.
- Prefer `token_env` over inline tokens.
- Keep request timeouts short.
- Do not forward browser Authorization to remote targets; use the target credential from broker config.
- Keep attachment blob proxying authenticated by the broker.

## Implementation Plan

### Phase 1: Broker Backend

1. Add config loading for `remote_servers`.
2. Add validation for `key`, `url`, and token source.
3. Add `RemoteClient` with JSON request forwarding and timeout handling.
4. Add `RemoteBroker` with server listing and request proxying.
5. Add routes:
   - `GET /servers`
   - `GET|POST|PUT|PATCH|DELETE /servers/:key/proxy/*`
6. Add `test/remote_server_test.rb` coverage with a local fixture target server.

### Phase 2: UI Server Switching

1. Add active server state with local default.
2. Add `apiPath(path)` helper and update all API helpers to call active-server paths.
3. Server-scope detail caches and object URL cleanup.
4. Add server selector/status UI.
5. Show active server name in the header or settings/status panel.
6. Preserve existing token prompt behavior for the broker.

### Phase 3: Verification

1. Run `bin/test`.
2. Run `bundle exec ruby test/remote_server_test.rb`.
3. Run a browser smoke check with one broker and one fixture target server.
4. Verify:
   - switching servers changes agents/projects/schedules
   - sending a prompt runs on the selected target
   - target auth failure is clear
   - target offline state is clear
   - attachments still load through the broker
   - form drafts do not leak between servers

### Phase 4: Follow-Ups

Consider later:

- UI-managed server entries persisted to Tycho config.
- mDNS/Tailscale discovery helpers.
- SSE broker forwarding for lower-latency updates.
- Cross-server dashboard aggregation.
- Backend state replication through NATS/JetStream if the product goal changes back to "any node has all state."
