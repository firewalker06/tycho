# Tycho Desktop Diorama Visualizer

Research current to 2026-08-31.

## Executive recommendation

Build the first companion as a separate, read-only macOS app in Swift, using AppKit for window and lifecycle control and SpriteKit for the scene. Make it a quiet desktop-layer diorama by default, with one transparent borderless window per selected display, a menu-bar controller, no Dock icon, no global shortcuts, and no Accessibility permission. Use a deliberate **Inspect** mode for hotspots; outside that mode the scene is click-through.

The MVP should poll Tycho's existing `GET /servers/activity`, server-qualified peer activity, `GET /servers/resources`, and local `GET /schedules` surfaces. It should use the existing resource-refresh trigger to update that cached catalog, not fetch project Git metadata itself. Do not add an event stream. The only justified server change is an optional `prompt_queue_count` field in the existing activity agent record, because the full agent list already computes it while the compact activity snapshot omits it. Treat a missing field as unknown so the companion remains compatible with older Tycho servers.

The scene should communicate state, not score it. Projects become small work sites, agents become caretakers, and state changes become brief physical cues. Idle is healthy. More motion is not better. Never expose token counts, costs, leaderboards, streaks, experience, currency, or “productivity” inferred from run volume.

Godot 4 is the runner-up if Windows/Linux delivery and artist-led scene authoring become near-term priorities. Do not start with Tauri 2: its web workflow is attractive, but Tauri's macOS transparent-window setting requires its private-API feature and its documentation says that setting prevents App Store acceptance. Electron is the weakest fit for an always-running ambient utility.

## Product thesis and precedents

### Thesis

Tycho already asks operators to understand several simultaneous, mostly slow-moving processes. A bottom-edge diorama can make that state legible at a glance without becoming another dashboard: look for a moving caretaker, a waiting lantern, a closed bridge, or a glowing mailbox, then return to work.

The product succeeds when it reduces checking, not when it increases engagement. Its loop is:

1. Glance at the scene.
2. Notice only the exceptional state.
3. Enter Inspect mode or open Tycho when action is needed.
4. Let the scene return to calm.

### What to borrow

- **Rusty's Retirement:** borrow the thin bottom/side strip, zoom control, automation, and an explicit focus mode. Its official store page describes a farm that sits at the bottom while other work continues, supports a vertical side layout, and slows production in Focus Mode to reduce distraction. The transferable idea is spatial coexistence and user-controlled intensity, not an economy or upgrade loop. [Rusty's Retirement on Steam](https://store.steampowered.com/app/2666510/Rustys_Retirement/)
- **The emerging bottom-of-screen category:** Steam now sells an official bundle built around games meant to run while the user does other things. That validates the strip as a recognizable interaction pattern, but also shows how quickly the pattern converges on currencies, upgrades, optimization, and collection. Tycho should look alive without importing those reward systems. [Bottom-Of-Your-Screen bundle on Steam](https://store.steampowered.com/bundle/48558/BottomOfYourScreen/)
- **Spirit City: Lofi Sessions:** borrow an intentionally soothing setting and tools that stay subordinate to focus. Avoid its explicit “gamified focus tool” framing, integrated habit tracking, and unlock loop; Tycho activity is operational state, not a proxy for personal discipline. [Spirit City on Steam](https://store.steampowered.com/app/2113850/Spirit_City_Lofi_Sessions/)
- **DeskBuddies and xpet:** borrow menu-bar control, adjustable position/size, offline-first posture, simple idle/walk modes, and clear privacy copy. Their App Store pages show that native, lightweight, locally contained desktop companions are an understandable Mac product shape. [DeskBuddies on the Mac App Store](https://apps.apple.com/us/app/deskbuddies/id6801264233?mt=12), [xpet on the Mac App Store](https://apps.apple.com/us/app/xpet/id6767799186?mt=12)
- **NotiSprite:** borrow selectable movement modes and soft, non-streak reminders. Its store page explicitly promises bottom wandering, fixed positions, configurable notification behavior, and wellbeing nudges “without pressure or streaks.” Tycho should be even quieter: lifecycle changes replace generic messages. [NotiSprite on the Mac App Store](https://apps.apple.com/us/app/notisprite-smart-desktop-pet/id6752292657?platform=mac)

### What to avoid

- **Desktop Goose's adversarial charm:** mouse theft, mud, pop-up notes, and screen-filling behavior are memorable because they interrupt. They are exactly wrong for an operational companion. Do not capture input, move the pointer, create surprise windows, or occlude work. [Desktop Goose official page](https://samperson.itch.io/desktop-goose)
- **Pet-maintenance guilt:** no hunger, sickness, neglect, death, daily streak, or decay when Tycho is quiet. A failed or blocked run is a work condition, not a harmed character.
- **Activity theatre:** no constant running animation, particle shower for routine completions, or larger settlement for more agents. High activity may mean churn, retries, or an incident; low activity may mean the system is finished.
- **Duplicate work management:** no timer, to-do list, prompt composer, task queue editor, or miniature Remote UI in the MVP. The companion is a visualizer and launcher.
- **Attention traps:** no random demands, audio by default, collectible drops, achievements, badges for volume, or notification text unrelated to Tycho state.

## Interaction model

### Default state: ambient and non-interactive

The diorama occupies a user-selected height, initially 96–160 points, along the bottom of one display. Transparent pixels show the desktop. The scene ignores mouse events, never becomes key, produces no sound, and uses no keyboard monitor. A menu-bar item is the stable control surface for Show/Hide, Inspect, display selection, motion level, launch at login, Open Tycho, Settings, and Quit.

The default placement is at desktop level: visible over wallpaper but behind normal app windows. This is the calmest interpretation of “companion.” A later opt-in **Overlay** mode may keep the strip above normal windows while preserving click-through behavior. Do not make Overlay the default because it consumes usable pixels and can sit over editors, subtitles, and controls.

### Inspect mode

Inspect is explicit and temporary. Choosing it from the menu bar, or clicking the menu-bar status item and selecting an alert, enables only visible project/agent hotspots for 15 seconds. Hover reveals a compact native label: name, status, server, age of data, and queued-prompt count when known. Clicking opens the corresponding resource in Tycho Remote UI. Escape, a click outside, timeout, Space change, screen lock, or full-screen transition exits Inspect.

This design avoids fragile per-pixel cross-app hit testing. AppKit can make a whole window transparent to mouse events with `ignoresMouseEvents`; `NSView.hitTest(_:)` only chooses a view within that window, so it is not by itself a guarantee that arbitrary transparent pixels pass through to another app. [Apple: `NSWindow.ignoresMouseEvents`](https://developer.apple.com/documentation/appkit/nswindow/ignoresmouseevents), [Apple: `NSView.hitTest(_:)`](https://developer.apple.com/documentation/appkit/nsview/hittest%28_%3A%29)

### Focus and accessibility

The ambient scene is decorative and absent from the accessibility hierarchy. The menu-bar menu and Settings use standard AppKit controls. In Inspect mode, each hotspot becomes a named `NSAccessibilityElement` with role, label, status value, and press action; custom elements need explicit accessibility properties/actions while standard AppKit controls supply much of that behavior automatically. [Apple: Accessibility for AppKit](https://developer.apple.com/documentation/appkit/accessibility-for-appkit), [Apple: `NSAccessibilityProtocol`](https://developer.apple.com/documentation/appkit/nsaccessibilityprotocol)

Honor Reduce Motion by replacing walking, travel, particles, and camera easing with cross-fades and static pose changes. Honor Reduce Transparency with an optional opaque backing shelf behind labels and Settings; Apple exposes both preferences through `NSWorkspace`, and specifically advises avoiding large simulated-depth animation when Reduce Motion is active. [Apple: Reduce Motion](https://developer.apple.com/documentation/appkit/nsworkspace/accessibilitydisplayshouldreducemotion), [Apple: Reduce Transparency](https://developer.apple.com/documentation/appkit/nsworkspace/accessibilitydisplayshouldreducetransparency)

## Tycho-state-to-visual mapping

The metaphor is a chain of small coastal workshops. It can read as pixel art or clean illustrated sprites, but its semantics must remain theme-independent.

| Tycho concept | Diorama object or behavior | Guardrail |
|---|---|---|
| Server | A separate horizon band with a stable crest, name, and accent color | Never merge same-key resources across servers; server identity is always visible in Inspect. |
| Project | A work site or island labeled by project name; zero-agent projects are quiet empty sites | Size reflects layout needs, never status or importance. |
| Idle agent | A caretaker resting, tidying, reading, or observing | Idle is a complete, healthy state. |
| Running work | The caretaker performs one slow, purposeful loop at its project's workbench | Motion indicates state only; it does not accelerate with token or tool volume. |
| Queued prompts | Sealed parcels in a small inbound rack, with `1`, `2`, or `3+` only in Inspect | Count comes from `prompt_queue_count`; never infer a queue from run count. |
| Awaiting input | The caretaker waits beside a steady amber question lantern | This outranks normal running cues and remains calm, not flashing. |
| Blocked work | A lowered bridge or closed workshop gate with a muted red knot | Do not depict injury, punishment, or urgency beyond the persistent obstruction. |
| Success | A two-second lamp glow or single sprout, then the caretaker returns to rest | Routine success does not create currency, fireworks, or permanent growth. |
| Failure / stopped / partial | A tool is set down; a small rain cloud or cracked sign persists until the next run or read | Use shape and icon as well as color. Distinguish stopped from failed in Inspect text. |
| Unread result | A mailbox lamp remains on until Tycho's explicit read state clears | Never mark a result read from the companion; opening Remote UI remains the action boundary. |
| Schedule | A clockwork weather vane over the local project; the next due time appears only in Inspect | A schedule-owned agent keeps its small clock badge. Peer schedules show only what the agent record proves. |
| Parent-child delegation | A thin dotted footpath and one handoff-lantern traveling child → parent on a terminal transition | Render only server-local relationships present in `delegation`; no speculative cross-server links. |
| Offline/stale server | The horizon desaturates, waves stop, and an age marker appears in Inspect | Preserve the last known arrangement; never convert stale agents to failed. |
| No configured data | An empty shoreline with “Connect Tycho” in the menu, not in the scene | No fabricated characters or demo activity after onboarding. |

Priority when states overlap: offline/stale server treatment wraps the scene; blocked and awaiting input override running; unread adds the mailbox cue without replacing the terminal outcome; scheduled is identity metadata, not lifecycle state.

## Technical option matrix

Scores are decision judgments for this product, from 1 (poor fit) to 5 (best fit), not cross-framework benchmarks. “CPU/memory” rates the likely idle footprint and the control available to stop work; it must be validated with the same scene and hardware.

| Option | Window control | Animation workflow | CPU / memory | Packaging | Cross-platform path | Tycho integration | Long-term fit | Total / 35 |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| AppKit + SpriteKit | 5 | 4 | 5 | 5 | 2 | 5 | 5 | **31** |
| Godot 4 | 3 | 5 | 3 | 4 | 5 | 3 | 4 | **27** |
| Tauri 2 + PixiJS | 4 direct / 2 App Store | 4 | 4 | 3 | 4 | 4 | 3 | **24–26** |
| Electron + PixiJS | 4 | 4 | 2 | 3 | 5 | 4 | 2 | **24** |

### AppKit + SpriteKit — recommendation

AppKit directly exposes borderless style, opacity/background, window levels, mouse transparency, activation policy, screen enumeration, display-change notifications, Spaces/Stage Manager collection behavior, accessibility, and occlusion state. SpriteKit is Apple's Metal-backed 2D scene framework; `SKView` exposes pause and preferred frame rate controls, which makes 15/30 fps operation and true idle pauses straightforward. [Apple: borderless windows](https://developer.apple.com/documentation/appkit/nswindow/stylemask-swift.struct/borderless), [Apple: `NSScreen.screens`](https://developer.apple.com/documentation/appkit/nsscreen/screens), [Apple: SpriteKit](https://developer.apple.com/documentation/spritekit), [Apple: `SKView`](https://developer.apple.com/documentation/spritekit/skview)

The cost is a macOS-only Swift/AppKit codebase and a less game-centric scene editor than Godot. That is the right trade: window behavior, energy use, accessibility, and distribution are core product features, while the first scene needs modest 2D animation rather than a general engine.

### Godot 4 — runner-up

Godot has the best authoring workflow and cross-platform path. Its current feature list includes multiple windows, borderless transparent overlays, polygon mouse passthrough, ignore-focus windows, tray integration on macOS, and screen-reader support. Its macOS exporter produces Universal 2 bundles and documents signing, notarization, and sandbox options. [Godot feature list](https://docs.godotengine.org/en/stable/about/list_of_features.html), [Godot macOS export](https://docs.godotengine.org/en/stable/tutorials/export/exporting_for_macos.html)

The gap is precise Mac desktop behavior. “Always on top” and overlay features are first-class, but desktop-level ordering, Stage Manager policy, AppKit accessibility elements, and nuanced activation will require a native extension or platform-specific code. Godot's published baseline for a simple native exported project is 150 MB of storage and 2 GB system RAM, not an app's measured resident set; it reinforces the need to benchmark an always-running build rather than assume engine overhead is free. [Godot exported-project requirements](https://docs.godotengine.org/en/stable/about/system_requirements.html)

Choose Godot only if a Phase 2 Windows/Linux commitment arrives before MVP build starts or if an artist must own scene logic in an editor from day one.

### Tauri 2 + PixiJS

Tauri uses the operating system webview instead of bundling a browser and exposes always-on-bottom, focusable, skip-taskbar, and visible-on-all-workspaces window options. PixiJS supplies a retained 2D scene graph, WebGL production renderer, transparent backgrounds, low-power GPU hint, and a ticker that can be stopped. [Tauri architecture](https://v2.tauri.app/concept/architecture/), [Tauri window API](https://v2.tauri.app/reference/javascript/api/namespacewindow/), [PixiJS application options](https://pixijs.com/8.x/guides/components/application), [PixiJS ticker lifecycle](https://pixijs.com/8.x/guides/components/application/ticker-plugin)

The blocker is distribution strategy: Tauri documents that a transparent macOS window requires `macOSPrivateApi` and warns that use prevents App Store acceptance. Native Rust/AppKit escape hatches also erase much of the promised simplicity for Stage Manager, accessibility, and per-display lifecycle. It is viable for direct notarized distribution, but it should not define the architecture before Tycho decides whether the Mac App Store matters. [Tauri window API](https://v2.tauri.app/reference/javascript/api/namespacewindow/), [Tauri macOS signing and notarization](https://v2.tauri.app/distribute/sign/macos/)

### Electron + PixiJS

Electron has mature APIs for transparent/focusable windows, whole-window mouse pass-through, all-workspace/full-screen visibility, and Mission Control hiding. It is the fastest web-team prototype path and offers consistent Chromium rendering. [Electron `BrowserWindow`](https://www.electronjs.org/docs/latest/api/browser-window)

It also embeds Chromium's browser/renderer multi-process model and Node in the main process; Electron's own performance guide treats memory and CPU reduction as an application responsibility. That is a poor default for a utility expected to remain open all day, especially when the scene is small and platform-specific window behavior dominates. [Electron process model](https://www.electronjs.org/docs/latest/tutorial/process-model), [Electron performance guide](https://www.electronjs.org/docs/latest/tutorial/performance)

## Recommended architecture

```text
Tycho Remote server(s)
  GET /servers/activity + peer /activity ─┐
  GET /servers/resources + refresh trigger ├─> DioramaStore (immutable normalized snapshot)
  GET /schedules (local) ──────────────────┘        │
                                       ├─> SceneMapper (pure state → visual intents)
Keychain: bearer token ─> APIClient     │
UserDefaults: display/theme prefs       └─> SpriteKit scenes, one per NSScreen

Menu-bar NSStatusItem ─> Settings / Inspect / Open Tycho / Quit
```

### Process and module boundaries

- **`APIClient`:** read-only `URLSession` client, bearer auth, request timeout, revision/ETag-like deduplication at the application layer, and independently backed-off server errors.
- **`DioramaStore`:** owns the last complete immutable snapshot. It never exposes bearer tokens, prompts, summaries, paths, attachments, or conversation content to the scene layer.
- **`SceneMapper`:** a pure function that takes normalized server/project/agent/schedule state plus prior state and returns stable entities and one-shot transition intents. Persist only display preferences and stable cosmetic assignments, not activity history.
- **`DisplayCoordinator`:** creates/removes one window and `SKView` per selected `NSScreen`, recalculates from `visibleFrame`, and reacts to screen parameter changes. Apple says `NSScreen.screens` and `visibleFrame` must not be cached because displays, Dock, menu bar, and safe areas can change. [Apple: `NSScreen.screens`](https://developer.apple.com/documentation/appkit/nsscreen/screens), [Apple: `NSScreen.visibleFrame`](https://developer.apple.com/documentation/appkit/nsscreen/visibleframe)
- **`SceneWindowController`:** owns level, collection behavior, click-through/Inspect transitions, and frame rate. Scene nodes never change native window policy directly.
- **`MenuController`:** standard `NSStatusItem` menu and Settings window. Use accessory activation policy so the app has no Dock icon or ordinary menu bar while remaining activatable; AppKit defines accessory apps as absent from the Dock/menu bar but still activatable programmatically or by their windows. [Apple: activation policies](https://developer.apple.com/documentation/appkit/nsapplication/activationpolicy-swift.enum)

### Smallest data contract

Use these shipped surfaces; details are documented in [Remote Server](../REMOTE_SERVER.md) and implemented in [`remote_server.rb`](../../lib/hq/remote_server.rb), [`agent_activity_snapshot.rb`](../../lib/hq/domain/agent_activity_snapshot.rb), and [`scheduler.rb`](../../lib/hq/domain/scheduler.rb).

1. `GET /servers/activity` at 5 seconds while any server has a running/blocked/awaiting-input agent and the display is awake; 15 seconds when visible but quiet; 60 seconds when the scene is hidden. It already returns `schema_version`, content-derived `revision`, server identity/health/staleness, aggregate unread count, and compact agents with lifecycle, unread, schedule identity, timing, result, summary, and delegation fields. The companion ignores `summary`.
2. `GET /servers/{server_key}/activity` for each non-local server on the same cadence, as the current Remote UI does. The combined catalog supplies identity and a retained peer fallback; the focused request supplies each peer's current in-memory snapshot without waiting for a full resource refresh. Back off peers independently and keep the combined fallback when a peer is unreachable.
3. `GET /servers/resources` every 30 seconds while visible and after an activity record references an unknown project; 2 minutes while hidden. It supplies project name/group/status and consistent agent/project ownership without synchronous peer or Git work. Follow a read with the existing `POST /servers/resources/refresh` only when the catalog says a server is due; the trigger updates Tycho's read cache asynchronously and deduplicates in-flight work. It does not mutate projects or agents.
4. `GET /schedules` every 60 seconds while visible and after wake. It is local-server scope by design; use it for exact local next-due/status. On peers, render only the `scheduled`/`schedule_key` identity present on activity agents.

Proposed additive activity field:

```json
{
  "agents": [
    {
      "key": "tycho-agent-20260831...",
      "prompt_queue_count": 2
    }
  ]
}
```

`agent_list_payload` already calculates `queued_prompts.length`, so add the same integer to `AgentActivitySnapshot#activity_payload` and `ACTIVITY_AGENT_FIELDS`. Treat absent as `null`, not zero, until a server proves support. This does not justify a new endpoint. If strict schema consumers exist, publish it as activity schema version 2 while accepting versions 1 and 2 in the companion.

Do not add SSE/WebSocket for MVP. The present activity endpoint is in-memory, revisioned, compact, authenticated, and intentionally independent of full-page polling. The Remote UI already uses 3-second visible and 30-second hidden activity polling, while its broader refresh defaults are 5/10/30 seconds; the companion can poll more slowly because it is ambient and must favor energy use. See [`app.js`](../../lib/hq/remote_ui/assets/app.js).

## Windowing and platform constraints

### Transparent, borderless, and behind-the-desktop placement

Use a borderless `NSPanel`/`NSWindow`, `isOpaque = false`, clear background, no shadow, and a transparent `SKView`. Borderless windows do not become key/main by default, which fits ambient mode. [Apple: borderless style](https://developer.apple.com/documentation/appkit/nswindow/stylemask-swift.struct/borderless), [Apple: `NSWindow.backgroundColor`](https://developer.apple.com/documentation/appkit/nswindow/backgroundcolor)

For Desktop mode, derive a level at or just above Core Graphics' public desktop window level and below desktop icons, then verify behavior against Finder on each supported macOS release. Core Graphics exposes distinct desktop and desktop-icon level keys, and AppKit states that level stacking takes precedence over within-level ordering. This is feasible but not a contractual “always behind every possible third-party window” guarantee; screen savers, login windows, and system overlays remain outside product control. [Apple: `CGWindowLevelKey`](https://developer.apple.com/documentation/coregraphics/cgwindowlevelkey), [Apple: desktop icon window level](https://developer.apple.com/documentation/coregraphics/cgwindowlevelkey/desktopiconwindow), [Apple: window levels](https://developer.apple.com/documentation/appkit/nswindow/level-swift.struct)

Overlay mode should use a documented normal/floating relationship, stay below Dock/menu system levels, and remain click-through except during Inspect. Never use screen-saver or higher levels.

### Multiple displays and the Dock

Create separate windows rather than one virtual-desktop-spanning window. Re-read `NSScreen.screens` and each `visibleFrame` after display, resolution, arrangement, menu-bar, or Dock changes. Let the user choose all displays, main display, or a named display; default to main display only. If the Dock is on the same edge, place the scene inside `visibleFrame` and let the Dock win. Never move or reserve Dock space. [Apple: screen enumeration](https://developer.apple.com/documentation/appkit/nsscreen/screens), [Apple: visible frame](https://developer.apple.com/documentation/appkit/nsscreen/visibleframe)

### Spaces, Stage Manager, and full-screen apps

Use `canJoinAllSpaces` only when the user chooses “All Spaces”; otherwise bind windows to their current Space. AppKit documents `canJoinAllSpaces` directly. For Stage Manager, test `.auxiliary` with `.fullScreenNone` as the default so the diorama can accompany normal work but does not intrude into another app's full-screen Space. Apple's current collection behavior API explicitly covers Mission Control, Spaces, Stage Manager, and full screen, and marks primary/auxiliary/canJoinAllApplications as mutually exclusive. [Apple: `canJoinAllSpaces`](https://developer.apple.com/documentation/appkit/nswindow/collectionbehavior-swift.struct/canjoinallspaces), [Apple: collection behaviors](https://developer.apple.com/documentation/appkit/nswindow/collectionbehavior-swift.struct), [Apple: auxiliary behavior](https://developer.apple.com/documentation/appkit/nswindow/collectionbehavior-swift.struct/auxiliary)

Do not promise identical behavior in Stage Manager and full-screen apps without an OS-version test matrix. A later “Show over full-screen apps” option can evaluate `canJoinAllApplications`, which Apple describes for overlays that can join other apps and not participate in Stage Manager layout. It must remain opt-in because a companion above full-screen video or presentation content is intrusive. [Apple: `canJoinAllApplications`](https://developer.apple.com/documentation/appkit/nswindow/collectionbehavior-swift.struct/canjoinallapplications)

### Focus, input, and permissions

Ambient windows never become key and use whole-window `ignoresMouseEvents`. Inspect can temporarily accept mouse events without installing a keyboard event tap. A global mouse-move monitor is technically available and does not require Accessibility trust for mouse events, but the MVP does not need it; Apple notes that key monitoring is the portion gated by Accessibility trust. [Apple: global event monitor](https://developer.apple.com/documentation/appkit/nsevent/addglobalmonitorforevents%28matching%3Ahandler%3A%29)

The app needs no Accessibility, Screen Recording, Input Monitoring, Automation, microphone, camera, or full-disk permission. It needs outgoing network access when sandboxed; Apple's `com.apple.security.network.client` entitlement explicitly covers connecting to a server on the same or another machine. [Apple: outgoing network entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.network.client)

### Power and lifecycle

Run at 30 fps during a visible state transition, 15 fps for slow ambient loops, and zero continuous frames when hidden, screen-locked, sleeping, or fully static. Pause SpriteKit views on sleep/screen-sleep and resume with a fresh snapshot after wake. Avoid per-frame network or layout work. Apple recommends limiting animation frame rate/duration, stopping updates the user cannot see, and minimizing timer-driven wakeups; App Nap is a backstop, not a substitute for reaching idle. [Apple: rendering efficiency](https://developer.apple.com/documentation/xcode/improving-your-app-s-rendering-efficiency), [Apple: timer energy guidance](https://developer.apple.com/library/archive/documentation/Performance/Conceptual/power_efficiency_guidelines_osx/Timers.html), [Apple: App Nap](https://developer.apple.com/library/archive/documentation/Performance/Conceptual/power_efficiency_guidelines_osx/AppNap.html)

A fully transparent window can still be reported as visible by AppKit's occlusion state, so do not rely on occlusion alone to throttle; combine app visibility, screen/session notifications, mode, and whether the scene has active transitions. [Apple: `NSWindowOcclusionState`](https://developer.apple.com/documentation/appkit/nswindow/occlusionstate-swift.struct)

### App Store and direct distribution

Keep both paths open. Mac App Store submission requires App Sandbox; direct distribution should use Developer ID signing, Hardened Runtime, and notarization. Apple says notarization is an automated malicious-content and code-signing check, not App Review, and App Store submission already includes equivalent checks. [Apple: preparing for distribution](https://developer.apple.com/documentation/xcode/preparing-your-app-for-distribution), [Apple: notarizing macOS software](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)

Use only public APIs, include all code/resources in the app bundle, ask consent before launch at login, and ship App Store updates only through the store if that channel is chosen. Those are explicit Mac App Store rules. [Apple App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/)

The network client entitlement is sufficient for Tycho HTTP calls in the sandbox. Local/IP HTTP may also need a narrow `NSAllowsLocalNetworking` declaration under current App Transport Security behavior; prefer HTTPS when Tycho provides it, and document why any local-network exception is needed. [Apple: `NSAllowsLocalNetworking`](https://developer.apple.com/documentation/bundleresources/information-property-list/nsapptransportsecurity/nsallowslocalnetworking)

## MVP and phased roadmap

### MVP: one calm, trustworthy scene

Ship only:

- one bundled art theme and one horizontal layout;
- main-display default, with an option to choose another or all displays;
- Desktop placement only; no always-on-top Overlay mode yet;
- menu-bar Show/Hide, Inspect, Open Tycho, motion level, display, launch-at-login, Settings, Quit;
- server/project/agent identity; running, idle, awaiting input, blocked, succeeded, failed, partial, stopped, unread, stale/offline, scheduled identity, delegation, and queued prompts when supported;
- read-only polling of the three existing APIs;
- Keychain-backed bearer token and no activity persistence;
- Reduce Motion, Reduce Transparency, shape-plus-color state cues, accessible Inspect elements, and silent-by-default operation;
- frozen last-known scene with an honest stale/offline treatment.

Explicitly exclude audio, currencies, customization economy, notifications, prompt submission, archive/read mutations, result text, token/cost metrics, arbitrary remote URLs, full-screen overlay, and Windows/Linux builds.

### MVP acceptance criteria

Product:

- In a moderated test, 8 of 10 Tycho users correctly identify running, awaiting-input, blocked, unread-success, failure, and offline states after a five-minute introduction.
- 8 of 10 can identify the owning project and server in Inspect mode when two servers contain duplicate agent keys.
- No participant interprets a quiet/empty site as poor performance after reading onboarding copy.
- Ambient mode never intercepts a click in 100 scripted clicks across transparent and painted pixels.

State and resilience:

- A local lifecycle change appears within 7 seconds under normal connectivity; quiet project metadata within 35 seconds.
- Duplicate, delayed, or unchanged revisions produce no duplicate transition animation.
- A failed peer never clears healthy servers or converts retained agents to failure.
- Sleep/wake, server restart, token rejection, and network loss preserve the last good scene, show age/error state, and recover without relaunch.
- Missing `prompt_queue_count` renders “unknown” in Inspect and no parcels, never a false zero.

Platform:

- Verified on the current shipping macOS and previous major release, with one/two displays, left/right/bottom/hidden Dock, separate and shared Spaces, Stage Manager on/off, and another app full screen.
- No unexpected Dock icon, app activation, Space switch, focus steal, menu-bar takeover, or appearance above full-screen content in default mode.
- VoiceOver can reach every Inspect hotspot and menu/Settings action; all state remains understandable with color removed and with Reduce Motion/Transparency enabled.

Performance, measured on an M1 MacBook Air baseline after five minutes:

- static visible scene: median CPU ≤ 1%, 95th percentile ≤ 3%; animated quiet scene: median CPU ≤ 3%; hidden/static: no continuous render loop;
- resident memory ≤ 150 MB with one display and ≤ 220 MB with two displays;
- no more than one activity request per configured interval, no tight retry loop, and exponential backoff after failures;
- Activity Monitor reports no “Preventing Sleep,” and a 30-minute Instruments Energy Log shows no sustained High energy-impact interval.

### Phase 2: polish after evidence

- Overlay mode with a clear onboarding warning and per-Space/full-screen controls.
- More layouts/themes, side placement, density control, and reduced-detail mode.
- Transition history limited to the current session for debugging, never scoring.
- Exact peer schedule metadata only if Tycho first exposes a read-only multiserver schedule catalog for another product need.
- Optional native notification handoff only if the diorama fails to surface awaiting-input/blocked states; reuse Tycho's existing notification semantics rather than duplicate them.

### Phase 3: platform expansion

Reassess engine choice with measured demand. A Godot implementation becomes credible if Windows/Linux are funded; keep the normalized data contract and scene semantics portable. Do not pre-emptively weaken the macOS window model for hypothetical reach.

## Privacy and security boundary

- The companion is a separate least-privilege client. It never reads `~/.tycho`, the workspace, Git state, logs, memory, conversations, prompts, summaries, attachments, or cost/token metrics directly.
- Accept only user-configured loopback or Tailscale/MagicDNS Tycho origins. Do not provide an arbitrary URL browser or proxy.
- Authenticate exactly like Remote UI and store each bearer token as a Keychain item scoped by server identity. Apple describes Keychain Services as encrypted storage for small secrets. [Apple: Keychain Services](https://developer.apple.com/documentation/security/keychain-services/)
- Keep tokens out of URLs, logs, crash metadata, analytics, scene state, and `UserDefaults`. Redact host error bodies before display.
- Request only compact read endpoints, plus the existing asynchronous `/servers/resources/refresh` cache trigger when due. Never call mark-read, prompt, start/stop, schedule mutation, archive, settings, or attachment endpoints.
- Persist only preferences and cosmetic stable IDs. Keep the last server snapshot in memory; discard it on quit.
- Default analytics and crash upload to off. If later added, make it opt-in and exclude server names, project names, agent names/keys, summaries, URLs, and timing traces precise enough to reveal work patterns.
- Tailscale connections are end-to-end encrypted at the tailnet layer even when an application sees an HTTP URL, but HTTPS remains preferable for service identity and ATS clarity. [Tailscale connection types](https://tailscale.com/docs/reference/connection-types), [Tailscale network security](https://tailscale.com/kb/1429/secure)

## Failure and offline behavior

1. Keep the last complete snapshot per server and timestamp it.
2. After one failed poll, leave the scene unchanged and show a small disconnected crest only in Inspect/menu.
3. After data exceeds twice the normal interval, desaturate that server and stop its motion; show “Last updated …”.
4. On `401`, stop automatic requests for that server after one confirmation attempt and ask for a token through Settings. Never repeatedly prompt.
5. On schema newer than supported, retain the last understood snapshot and show “Update companion”; do not partially reinterpret fields.
6. On first launch with no successful snapshot, show connection help in Settings/menu. The desktop scene remains empty.
7. On wake, wait for network reachability or a short randomized delay, then fetch once. Do not replay transitions that happened while asleep; render current truth.

## Risks and open questions

| Question / risk | Decision needed or mitigation |
|---|---|
| Should the companion be visible while normal windows cover the desktop? | MVP says no: desktop-level calm wins. Validate whether users instead expect Rusty's always-visible strip before building Overlay mode. |
| Mac App Store or direct download first? | Keep native/public-API/App Sandbox compatibility. Decide before designing update, purchase, and login-item flows. |
| Is a 96–160 point strip too much desktop area? | Test three fixed densities and a side layout mockup. Do not auto-resize other apps. |
| What art style belongs to Tycho? | Commission one semantic prototype before production animation. Test readability in light/dark wallpapers and color-vision simulations. |
| Are agent names/project names safe on a shared screen? | Add a Privacy mode that replaces labels with stable symbols and hides all text until Inspect. Decide whether it should default on during screen sharing; automatic screen-capture detection is not required for MVP. |
| Should success remain visible when read? | Recommendation: brief transition only; the idle pose carries no outcome. Unread is the durable cue. |
| Does `summary` belong in the activity endpoint consumed by a companion? | The app must ignore it. Consider a future server-side field projection only if data minimization cannot be enforced confidently in the client. |
| Do queued prompts justify an API addition? | Yes, one optional integer on existing activity; no endpoint or stream. Confirm queue semantics during running, awaiting-input, and stopped states before implementation. |
| How should many projects/agents scale? | MVP caps visible agents per project and groups excess as a quiet roster marker. Define thresholds with real snapshots; never shrink sprites below readable size or convert count to “busyness.” |
| Will desktop-level ordering remain stable across macOS releases? | Maintain an automated/manual OS matrix and a safe fallback that hides the window. Do not use private APIs to force placement. |
| How should peer schedules render? | Only the scheduled-agent badge is trustworthy today. Exact next-run clocks remain local until Tycho has a genuine multiserver schedule use case. |

## Sources

### Product precedents

- [Rusty's Retirement — Steam](https://store.steampowered.com/app/2666510/Rustys_Retirement/)
- [Bottom-Of-Your-Screen bundle — Steam](https://store.steampowered.com/bundle/48558/BottomOfYourScreen/)
- [Spirit City: Lofi Sessions — Steam](https://store.steampowered.com/app/2113850/Spirit_City_Lofi_Sessions/)
- [Desktop Goose — official itch.io page](https://samperson.itch.io/desktop-goose)
- [DeskBuddies — Mac App Store](https://apps.apple.com/us/app/deskbuddies/id6801264233?mt=12)
- [xpet — Mac App Store](https://apps.apple.com/us/app/xpet/id6767799186?mt=12)
- [NotiSprite — Mac App Store](https://apps.apple.com/us/app/notisprite-smart-desktop-pet/id6752292657?platform=mac)

### Apple platform and distribution

- [NSWindow](https://developer.apple.com/documentation/appkit/nswindow)
- [NSWindow collection behaviors](https://developer.apple.com/documentation/appkit/nswindow/collectionbehavior-swift.struct)
- [NSScreen screens](https://developer.apple.com/documentation/appkit/nsscreen/screens)
- [NSScreen visibleFrame](https://developer.apple.com/documentation/appkit/nsscreen/visibleframe)
- [Accessibility for AppKit](https://developer.apple.com/documentation/appkit/accessibility-for-appkit)
- [SpriteKit](https://developer.apple.com/documentation/spritekit)
- [Improving rendering efficiency](https://developer.apple.com/documentation/xcode/improving-your-app-s-rendering-efficiency)
- [App Sandbox](https://developer.apple.com/documentation/security/app-sandbox)
- [Notarizing macOS software](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)
- [App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/)

### Frameworks

- [Godot feature list](https://docs.godotengine.org/en/stable/about/list_of_features.html)
- [Godot macOS export](https://docs.godotengine.org/en/stable/tutorials/export/exporting_for_macos.html)
- [Tauri architecture](https://v2.tauri.app/concept/architecture/)
- [Tauri window API](https://v2.tauri.app/reference/javascript/api/namespacewindow/)
- [Tauri macOS signing](https://v2.tauri.app/distribute/sign/macos/)
- [PixiJS application](https://pixijs.com/8.x/guides/components/application)
- [Electron BrowserWindow](https://www.electronjs.org/docs/latest/api/browser-window)
- [Electron process model](https://www.electronjs.org/docs/latest/tutorial/process-model)

### Tycho repository

- [Remote server architecture and endpoint reference](../REMOTE_SERVER.md)
- [Multiserver resource design](../MULTISERVER_RESOURCES_PLAN.md)
- [Scheduled runs](../SCHEDULED_RUNS.md)
- [Agent delegation](../AGENT_DELEGATION.md)
- [`AgentActivitySnapshot`](../../lib/hq/domain/agent_activity_snapshot.rb)
- [`RemoteServer` and payload serializers](../../lib/hq/remote_server.rb)
- [Remote UI polling client](../../lib/hq/remote_ui/assets/app.js)
- [Scheduler payload](../../lib/hq/domain/scheduler.rb)
