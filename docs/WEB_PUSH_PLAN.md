---
name: WEB_PUSH_PLAN
description: Implementation plan for browser push notifications in HQ Remote UI
type: project-plan
---

# Web Push Implementation Plan

## Goal

Add browser push notifications to HQ Remote UI so a user can be notified when a managed agent needs attention or finishes while the Remote UI is not focused.

This plan targets the Remote Sessions web UI served by `bin/tycho serve`. It does not add push behavior to the Bubbletea TUI.

## Current Implementation

The first implementation slice is in place:

- `web-push` dependency and local VAPID key generation.
- `~/.tycho/logs/push_subscriptions.json` subscription persistence.
- `~/.tycho/logs/push_notifications.json` event de-duplication for agent transition notifications.
- `/push/config`, `/push/subscriptions`, and `/push/test` JSON endpoints.
- `/service-worker.js` static route for displaying notifications and opening HQ Remote routes.
- Setup-screen notification controls.
- HTTP MagicDNS soft warning before enabling browser push without HTTPS.
- Automatic notifications when an agent requires response or finishes.

## Tailscale HTTPS Guidance

Browser Push API and Notification API usage requires a secure browser context. Local development can use `localhost` or `127.0.0.1`, but phone and remote-device usage must be served over HTTPS.

For HQ, non-local push notifications are expected to work through a Tailscale MagicDNS domain when that origin is served over HTTPS, for example `https://machine.tailnet-name.ts.net/`. Plain HTTP MagicDNS URLs such as `http://machine.tailnet-name.ts.net:7373/` should show a soft warning, but the UI should still let the user try enabling notifications when the browser exposes the required push APIs.

When `bin/tycho serve` starts and Tailscale HTTPS is enabled, HQ checks `tailscale serve status --json`.
If Tailscale Serve is actively forwarding HTTPS traffic to the current HQ port, HQ binds locally for the proxy and the printed Remote UI URL and terminal QR use the HTTPS MagicDNS origin automatically.
If HTTPS is enabled but Serve is not forwarding to HQ, the QR stays on the reachable HTTP MagicDNS URL and the startup log prints the `tailscale serve --bg {port}` hint.
Port `80` is not a workaround for browser push. HQ can keep serving HTTP on local port `7373`; Tailscale Serve should provide the HTTPS origin, usually as `https://machine.tailnet-name.ts.net/`. A `:7373` HTTPS URL only works when Serve is explicitly configured with `--https=7373`.

Implementation requirements:

- Show a soft warning when `window.isSecureContext` is false.
- Allow localhost development for tests and local browser checks.
- For Tailscale usage, recommend an HTTPS URL under the tailnet's `*.ts.net` MagicDNS name.
- Document that the operator must enable HTTPS in the tailnet before enabling remote push.
- Warn clearly when the user opens HQ Remote through an HTTP MagicDNS origin and tries to enable notifications.
- Only hard-block when required browser APIs are unavailable or notification permission is denied.

Tailscale notes:

- Tailscale Serve can expose a local service over HTTPS inside the tailnet.
- Tailscale Funnel can expose a local service over HTTPS outside the tailnet when explicitly enabled.
- Tailscale's CLI for Serve/Funnel has changed across client versions, so implementation docs should link to current Tailscale docs instead of hardcoding a single canonical command.

References:

- https://tailscale.com/docs/features/tailscale-serve
- https://tailscale.com/docs/features/tailscale-funnel

## Gem Summary

Use the `web-push` gem from Pushpad:

- Repository: https://github.com/pushpad/web-push
- RubyGems: https://rubygems.org/gems/web-push

The gem sends standards-based Web Push messages from Ruby. It supports encrypted payloads and VAPID authentication, which fits HQ's local-first model because no hosted push-notification service account is required.

The repo currently targets Ruby `>= 3.2.0`; `web-push` currently supports Ruby `>= 3.0`, so it is compatible with HQ's runtime requirement.

## MVP Notification Scope

Send notifications for managed-agent state transitions:

- Agent enters `awaiting-input`.
- Agent transitions from running to `succeeded`.
- Agent transitions from running to `failed`, `stopped`, or `blocked`.

Defer project action notifications until the agent notification path is stable.

## Configuration

Add the gem:

```ruby
gem "web-push", "~> 3.1"
```

Add VAPID configuration via environment variables:

- `TYCHO_WEB_PUSH_VAPID_PUBLIC_KEY`
- `TYCHO_WEB_PUSH_VAPID_PRIVATE_KEY`
- `TYCHO_WEB_PUSH_VAPID_SUBJECT`

The default subject is `mailto:tycho@example.com`. For real usage,
prefer setting `TYCHO_WEB_PUSH_VAPID_SUBJECT` to a real `mailto:` contact or
an HTTPS URL. Apple Web Push rejects invalid VAPID JWT subjects with
`BadJwtToken`.

Generate keys using the gem's key helper:

```ruby
WebPush.generate_key
```

The public key may be exposed to the browser. The private key must never be served, logged, or persisted into Remote UI assets.

## Persistence

Add `HQ::PushSubscriptionStore` under `lib/hq/domain/`.

Persist subscriptions in:

```text
~/.tycho/logs/push_subscriptions.json
```

Stored fields:

- `endpoint`
- `p256dh`
- `auth`
- `user_agent`
- `created_at`
- `updated_at`
- `last_seen_at`
- `failure_count`
- `disabled_at`

Treat push endpoints as secrets because they are capability URLs.

Persist sent agent-transition notification IDs in:

```text
~/.tycho/logs/push_notifications.json
```

This file prevents repeated notifications for the same completed run while
still allowing future runs of the same agent to notify again.

## Remote Server API

Add JSON endpoints:

| Method | Path | Purpose |
|--------|------|---------|
| `GET` | `/push/config` | Return push readiness and the VAPID public key. |
| `POST` | `/push/subscriptions` | Save or refresh a browser push subscription. |
| `DELETE` | `/push/subscriptions` | Disable the current browser subscription. |
| `POST` | `/push/test` | Send a local test notification for verification. |

Reuse the existing Remote Server bearer-token authorization path for these endpoints. The static service worker file can be public, but subscription mutation endpoints must use the same authorization behavior as the rest of the JSON API.

## Service Worker

Serve a service worker from the origin root:

```text
/service-worker.js
```

The worker should:

- handle `push`
- parse a compact JSON payload
- call `registration.showNotification(title, options)`
- handle `notificationclick`
- focus an existing HQ Remote tab when possible
- otherwise open `/#agent/{key}` or another payload URL

Payload shape:

```json
{
  "title": "Agent needs input",
  "body": "Web agent is awaiting input",
  "url": "/#agent/web-agent-1",
  "tag": "agent:web-agent-1:awaiting-input"
}
```

## Remote UI

Add notification controls to the Setup screen:

- status: unsupported, blocked, disabled, enabled, or misconfigured
- `Enable notifications` button
- `Disable notifications` button
- `Send test notification` button when enabled

Client flow:

1. Check `window.isSecureContext`.
2. Check `navigator.serviceWorker`, `PushManager`, and `Notification`.
3. Register `/service-worker.js`.
4. Request notification permission from an explicit user click.
5. Subscribe using the VAPID public key from `/push/config`.
6. POST the subscription to `/push/subscriptions`.

Do not request permission automatically during page load.

## Notification Sender

Add `HQ::WebPushNotifier`.

Responsibilities:

- Load enabled subscriptions.
- Send with `WebPush.payload_send`.
- Use VAPID private key and subject from environment.
- Set payload TTL and urgency deliberately.
- Disable expired or invalid subscriptions.
- Increment failure counts for transient send errors.

Suggested urgency:

- `awaiting-input`: high
- `failed`: high
- `succeeded`: normal
- `stopped`: normal

## Event Detection

Use a small event ledger:

```text
~/.tycho/logs/push_notifications.json
```

Persist notification IDs for completed runs so notifications are sent once per meaningful transition.

Remote Server handles requests in one process and also runs a lightweight periodic poll inside `RemoteServer#start`:

- every 5 seconds
- load agents via `AgentStore`
- call `poll!`
- detect status transitions
- notify via `HQ::WebPushNotifier`
- save changed agent state

Keep the polling path shared with existing `AgentStore` and `ManagedAgent` behavior.

## Testing

Automated coverage currently includes:

- `/push/config` response with generated VAPID readiness.
- subscription save and disable behavior.
- service worker route and Remote UI push-control JavaScript checks.
- agent transition ledger sends once for `awaiting-input` and completion states.
- Tailscale HTTPS Serve URL parsing for QR selection.

Browser verification:

- start `bin/tycho serve` with temp `TYCHO_CONFIG_PATH`, `TYCHO_SYSTEM_PROMPTS_PATH`, and `TYCHO_LOGS_ROOT`
- verify `/service-worker.js` loads
- verify Setup notification controls render
- verify insecure non-local origins show a blocked state
- verify localhost can reach the subscription flow in a real browser engine

Manual verification:

- enable Tailscale HTTPS for the machine
- open HQ Remote through the HTTPS Tailscale URL
- enable notifications
- send test notification
- run an agent to `awaiting-input`
- confirm notification opens the correct agent detail route

## Implementation Order

1. Add gem and VAPID config readiness.
2. Add subscription store and JSON endpoints.
3. Serve service worker and add Remote UI controls.
4. Add notifier with test endpoint.
5. Add agent transition ledger.
6. Add Remote Server periodic poll.
7. Add browser verification and operational docs for Tailscale HTTPS.
