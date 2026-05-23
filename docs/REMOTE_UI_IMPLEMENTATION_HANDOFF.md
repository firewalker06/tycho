# Remote UI Implementation Handoff

> Last updated: 2026-05-10
>
> Related docs:
>
> - `docs/REMOTE_SERVER.md`
> - `docs/REMOTE_UI_AUDIT_CHECKLIST.md`
> - `docs/REMOTE_UI_DESIGN_PROCESS.md`
> - `docs/UI_FEATURE_INVENTORY.md`
> - `docs/hq_ui_mockups_v2.html`

## Current State

The mobile Remote UI direction is implemented as a plain server-served web app at `/`. It remains local-first, uses no frontend build step, and talks to the existing JSON API served by `bin/tycho serve`.

Current implementation files:

- Server entrypoint: `bin/tycho serve`
- Server class and API service: `lib/hq/remote_server.rb`
- UI shell: `lib/hq/remote_ui/templates/index.html.erb`
- CSS: `lib/hq/remote_ui/assets/app.css`
- JavaScript: `lib/hq/remote_ui/assets/app.js`
- Static asset helper: `lib/hq/remote_ui.rb`

The old phase checklist has been retired because the shell, top-level screens, main detail routes, project payloads, setup/readiness payloads, skill discovery, client-side search, guarded project actions, audit fixes, and mobile nav polish are now implemented.

## Implemented

- Five top-level destinations: `Now`, `Agents`, `Search`, `Projects`, `Setup`.
- Fixed bottom nav on top-level screens; it hides on downward scroll and reappears on upward scroll, focus, route changes, or near page top.
- Bottom nav is hidden on subpages with a back button.
- Deep links show loading states instead of transient not-found screens while initial data loads.
- Now screen shows attention count, paused/blocked agents, running agents, and search affordance.
- Agents screen filters and groups managed agents by project.
- Search screen searches agents and projects client-side, prioritizing unread agents on empty query.
- Projects screen lists health, latency, group, and maintenance/action state.
- Setup screen shows URL, Tailscale/MagicDNS state, auth state, harness readiness, schema/config readiness, logs/storage, refresh intervals, and safety defaults.
- Agent detail supports conversation viewing, current activity, run metadata, skill insertion, prompt submission, start run, and stop confirmation.
- Project detail shows health, revision, deploy details, versions/templates, recent agent summary, and guarded project actions.
- Guarded deploy/maintenance/live action screens show consequences and preflight checks before starting a detached Kamal action.
- Copy actions show feedback.
- Long paths and summaries wrap without horizontal page overflow at mobile widths.
- `/favicon.svg` and `/favicon.ico` are served to avoid browser 404 noise.
- Auth token entry is wrapped in a form with browser password-manager friendly markup.

## API Coverage

Implemented Remote UI API surfaces:

- Existing agent lifecycle: `/agents`, `/agents/{key}`, `/agents/{key}/conversation`, `/agents/{key}/messages`, `/agents/{key}/start`, `/agents/{key}/stop`, create/edit/archive.
- Project list and detail: `/projects`, `/projects/{key}`.
- Setup/readiness: `/setup`.
- Search index: `/search`.
- Skill discovery: `/projects/{key}/skills/{agent}`.
- Guarded project action preflight/start: `/projects/{key}/actions`, `/projects/{key}/actions/{action}`.

API behavior is covered in `test/remote_server_test.rb`.

## Remaining Product Gaps

- Dedicated structured inquiry/decision submission UI. Current agent detail shows conversation and prompt submission, but does not yet render specialized inquiry forms.
- Dedicated activity/log detail page with tabs, find/filter, and raw log inspection.
- Full mobile agent create/edit form. The API supports create/edit, but the current mobile UI sends users through project context and keeps advanced setup TUI-first.
- In-browser project modification. This remains intentionally TUI-only because it needs local filesystem handling.
- More explicit action progress polling and post-action health refresh UI around project action logs.
- Optional QR display inside Setup. Startup terminal QR is implemented; in-page QR remains a future enhancement.

## Verification

Run from the repo root:

```bash
bundle exec ruby -c bin/tycho
node --check lib/hq/remote_ui/assets/app.js
bundle exec ruby test/registry_test.rb
bundle exec ruby test/remote_server_test.rb
bundle exec ruby test/tailscale_test.rb
bundle exec ruby test/terminal_qr_test.rb
bundle exec ruby test/rendering_test.rb
```

Manual smoke:

- Start `bin/tycho serve`.
- Open `/` at mobile width.
- Check `Now`, `Agents`, `Search`, `Projects`, and `Setup`.
- Confirm the footer nav hides while scrolling down and shows while scrolling up.
- Deep-link to an agent and project detail route.
- Open a guarded project action preflight.
- Confirm no horizontal page overflow at `390px`.

## Notes For Future Agents

- Preserve the no-build frontend approach unless the user explicitly approves frontend tooling.
- Keep Remote UI state transitions backed by `RemoteService`, `AgentStore`, `ManagedAgent`, `AppProject`, and `KamalAction`.
- Keep dangerous/local project actions guarded by confirmation screens.
- Keep raw paths, logs, and diagnostics behind disclosure or detail routes.
- Avoid changing TUI behavior unless a shared domain contract requires it.
