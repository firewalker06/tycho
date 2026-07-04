# Web Push Notification Behavior

This note explains how Tycho Remote UI uses browser push notifications, notification grouping, silent delivery, and PWA app icon badges. It is meant as a learning map for future improvements, not as the original implementation plan.

## Current Flow

1. The Remote server polls managed agents through `AgentStore#load_with_poll_events`.
2. When a running agent transitions to `awaiting-input`, `succeeded`, `failed`, `stopped`, or `blocked`, Tycho marks that agent unread and records a push event.
3. `RemoteService#dispatch_agent_push_events` builds a compact JSON payload for the event.
4. `WebPushNotifier#send_payload!` sends that payload to every enabled browser subscription with VAPID authentication.
5. `/service-worker.js` receives the push event, updates the installed-app badge when a `badge_count` is present, and calls `registration.showNotification(title, options)`.
6. When the Remote UI page is open, `syncUnreadAlert()` also mirrors the unread-agent count into the app badge so foreground state and background push state stay aligned.
7. Notification clicks focus an existing Tycho Remote tab when possible, otherwise they open the payload URL, usually `/#agent/{key}`.

## Grouping Model

The Web Notifications API does not provide a portable native "group" primitive like some mobile notification frameworks do. The closest standard tool is the notification `tag` option:

- A notification with the same `tag` as an existing notification replaces the older notification.
- `renotify: true` asks the browser to alert the user again when replacement happens.
- `renotify` only makes sense when a `tag` is present.

Tycho uses this replacement model for agent pushes:

```json
{
  "tag": "hq:agents",
  "renotify": true,
  "url": "/#agent/smoke-agent-1"
}
```

All agent transition notifications share the `hq:agents` tag. That means repeated agent updates collapse into one visible Tycho agent notification instead of piling up. The newest notification wins, and when more than one unread agent exists Tycho appends the unread count to the notification body.

This is intentionally coarse-grained. A future improvement could split tags by priority, for example `hq:agents:input-required` and `hq:agents:finished`, if replacing finished notifications with input-required notifications feels too aggressive.

## Silent Notifications

The Notification API `silent` option suppresses notification sounds and vibrations. It does not make a push invisible, and it does not guarantee that the browser will avoid showing a notification.

Tycho uses this policy:

- `awaiting-input`: `silent: false`, `renotify: true`, Web Push urgency `high`
- finished states (`succeeded`, `failed`, `stopped`, `blocked`): `silent: true`, Web Push urgency `normal`

This keeps "agent needs your answer" events attention-grabbing while making routine completions less disruptive. Browser behavior still varies by platform and user notification settings.

Important limitation: do not rely on Web Push as a fully silent background transport for badge-only updates. Browsers can require a visible notification whenever a push event is received. Tycho treats background push as a visible notification path and uses the app badge as supplemental state.

## PWA App Icon Badges

There are two different "badge" concepts:

- `showNotification({ badge: "/pwa-icon-192.png" })` is the small notification-shelf icon used by some platforms.
- `navigator.setAppBadge(count)` / `navigator.clearAppBadge()` update the installed PWA app icon badge when supported.

Tycho uses both:

- The service worker keeps the notification `badge` image pointed at Tycho's PWA icon.
- Agent push payloads include `badge_count`, derived from the current unread-agent count.
- The service worker calls `setAppBadge(badge_count)` when it handles a push payload with `badge_count`.
- The foreground Remote UI calls `setAppBadge(unread_count)` during normal rendering and `clearAppBadge()` when unread agents drop to zero.
- Unsupported browsers are treated as no-ops.

Example agent payload:

```json
{
  "title": "Agent requires response",
  "body": "Smoke Project reviewer: Needs review confirmation (2 unread agents)",
  "tag": "hq:agents",
  "renotify": true,
  "silent": false,
  "badge_count": 2,
  "url": "/#agent/smoke-agent-1"
}
```

## Files To Read

- `lib/hq/remote_server.rb`: builds agent push payloads and unread badge counts.
- `lib/hq/domain/web_push_notifier.rb`: sends encrypted Web Push payloads.
- `lib/hq/remote_ui/assets/service-worker.js`: receives push events, displays notifications, and updates badges in the background.
- `lib/hq/remote_ui/assets/app.js`: mirrors unread-agent state to the header logo badge and the installed PWA app badge.
- `test/remote_server_test.rb`: regression coverage for push payload shape, service worker behavior, and Remote UI hooks.

## Improvement Ideas

- Add Settings toggles for notification mode: grouped, per-agent, silent completions, or all-silent.
- Split group tags by severity so input-required notifications do not replace routine completion notifications.
- Add notification actions such as "Open agent" and "Mark read" once action support is tested across target browsers.
- Persist per-subscription preferences so a desktop browser and phone can use different notification policies.
- Include schedule failures in the app badge count, or document why app badges are agent-only.
- Add a "last push payload" debug view under Settings for diagnosing service worker behavior.
- Explore a summary notification body that lists the top two unread agents instead of only the newest event.

## References

- [MDN: ServiceWorkerRegistration.showNotification()](https://developer.mozilla.org/en-US/docs/Web/API/ServiceWorkerRegistration/showNotification)
- [MDN: Badging API](https://developer.mozilla.org/en-US/docs/Web/API/Badging_API)
- [Chrome for Developers: Badging for app icons](https://developer.chrome.com/docs/capabilities/web-apis/badging-api)
