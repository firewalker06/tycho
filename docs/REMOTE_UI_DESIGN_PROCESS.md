# HQ Remote UI Design Process

> Status: V2 selected on 2026-05-09.

## Source Material

The design pass started from `docs/UI_FEATURE_INVENTORY.md`, which captures the current HQ surfaces:

- Terminal-first project and agent cockpit.
- Remote `/` agent controls.
- Managed-agent conversation, structured inquiry, logs, and process state.
- Project health, Kamal actions, action logs, and remote access constraints.

The inventory made it clear that the current feature set is broad enough to support a full cockpit, but the mobile web UI should not mirror the CLI/TUI hierarchy directly.

## V1 Direction

The first static mockup explored a fuller remote cockpit:

- Agent queue.
- Agent conversation.
- Structured inquiry.
- Projects with health and actions.
- Action log.
- Remote access/token state.
- Desktop adaptation.

This helped expose the product surface area, but it also showed the main risk: the mobile UI felt like a compressed version of the TUI. It put Agents, Projects, Logs, Deploy, Terminal, Archive, tokens, health, action logs, structured inquiry, and chat into one parallel hierarchy.

## V1 Drawbacks

The review identified these issues:

- The first screen did not clearly answer "what needs my attention now?"
- Top tabs and bottom navigation duplicated each other.
- Project detail and project list were combined in a master-detail layout that was awkward on mobile.
- Tool-call and block-count language leaked TUI implementation details into the web UI.
- Destructive or local-only operations were too close to routine actions.
- Logs appeared as a primary destination rather than an on-demand support surface.
- Remote access diagnostics showed implementation details before recovery actions.

## V2 Direction

V2 reorganizes the mobile app around task-first surfaces:

1. **Attention** - the start screen prioritizes paused agents, blocked work, running work, and search.
2. **Decision** - structured inquiry becomes an explicit decision flow with clear consequences.
3. **Conversation** - chat focuses on the active agent, current activity, and a compact composer.
4. **Activity Detail** - logs and tool activity are available on demand, with summary first and raw detail secondary.
5. **Project Health** - project operations start from health triage rather than a full project object view.
6. **Guarded Action** - deploy and other local actions require a dedicated confirmation flow with preflight context.

The selected V2 artifact is `docs/hq_ui_mockups_v2.html`.

## Icon Direction

V2 uses inline Lucide-style SVG symbols directly inside the static HTML file.

Reasons:

- Works in plain server-served HTML/CSS with no build step.
- Renders reliably on mobile without requiring a Nerd Font install.
- Keeps icons accessible through normal SVG semantics and CSS `currentColor`.
- Maintains a consistent web icon style while the TUI can continue using Nerd Font glyphs.

The TUI and web UI should share semantic icon names where useful, but they do not need to share the same rendering technology.

## Current Decision

Use V2 as the chosen direction for future Remote UI design work.

The next implementation step should treat the mockup as product direction, not as a one-to-one DOM target. In particular, implementation should preserve the new information hierarchy:

- Start with attention and decisions.
- Keep chat focused.
- Keep logs and raw process detail on demand.
- Gate local and destructive operations behind explicit confirmation.
- Avoid reintroducing the full TUI object hierarchy into mobile navigation.
