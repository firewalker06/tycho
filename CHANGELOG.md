# Changelog

All notable changes to Tycho will be documented in this file.

## Unreleased

## 0.4.0 - 2026-06-06

- Add grouped Web Push badge support so Remote UI notifications can update
  scoped browser badges and document push behavior.
- Improve the Remote UI Summary surface and keep run summary blocks out of the
  main conversation stream.
- Fix Remote readiness checks by sharing executable resolution for `mise`,
  Kamal, Codex, Claude, and compatible harnesses.
- Fix Claude structured output schema handling so Claude-compatible runs can
  produce and parse structured results reliably.
- Resume stopped schedules safely after interactive scheduled agents are
  archived, while preserving protection for user-touched sessions.
- Add managed-agent model and reasoning effort settings with config inheritance,
  harness catalog suggestions, and TUI/Remote UI editing.
- Keep schedule rows visible in the Remote UI as schedule and daemon state
  changes.
- Add copyable Remote UI details for operator-facing metadata.
- Add a Remote UI agent sort dropdown for faster agent list triage.
- Clarify scheduled-agent titles so recurring run history is easier to scan.
- Add Remote UI project editing with JSON API support.
- Add drag-and-drop file attachments to the Remote UI composer.
- Simplify schedule status handling to `scheduled`, `paused`, and `stopped`,
  with last outcome and error diagnostics tracked separately.

## 0.3.0 - 2026-05-31

- Add first-run onboarding for pristine installs, including TUI and Remote UI
  welcome sandbox creation under `~/.tycho/workspaces/welcome`.
- Simplify the Remote UI around `Now`, `Agents`, and `Settings`, with project
  and agent filtering consolidated into the Agents workspace.
- Add Remote UI bulk archive for idle agents and keep zero-agent projects
  reachable for first-agent creation.
- Improve Remote UI agent messages and summaries with markdown rendering,
  better iPad/PWA header spacing, and safe-area handling.
- Add clipboard paste uploads for Remote UI prompt attachments.
- Dedupe attachments by normalized URL or file path and show newly added
  attachments first.

## 0.2.1 - 2026-05-29

- Add a Remote UI attachment navigation drawer.
- Add a Remote UI unread agents panel on the header logo and keep detail
  headers visible while scrolling or focusing footer controls.
- Add an Intel macOS Lipgloss compatibility backend, `tycho doctor`, and
  install/release smoke checks for the Charm Ruby native extension path.

## 0.2.0 - 2026-05-28

- Add hidden project and group visibility settings for TUI and Remote UI
  project/agent filtering.
- Add Remote UI schedule controls for manual runs, pause/resume, and scheduler
  daemon start/stop/restart.
- Add Remote UI attachment management, including uploads, previews, copy,
  refresh, and delete flows.
- Make Remote UI attachment summaries toggleable and preserve relevant state
  across polling renders.
- Preserve mobile newlines in the Remote UI composer while keeping explicit
  keyboard Enter submission.
- Scroll the active Remote UI tab to the top when its selected nav item is
  clicked again.
- Replace the old HQ loading logotype with the Tycho wide banner and update
  visible TUI product copy.
- Add README screenshots for TUI and Remote UI workflows.

## 0.1.1 - 2026-05-24

- Add release maintainer runbook.
- Add README hero image.
- Make Remote UI prompt submission use Enter while preserving Shift+Enter
  newlines and IME composition.

## 0.1.0 - 2026-05-23

- Add MIT license and public contribution/security/code-of-conduct documentation.
- Add open-source readiness plan.
- Add Homebrew-first public README with source-install fallback.
- Add CI and `bin/test` test runner.
- Add version and gemspec metadata.
- Replace real parser fixtures and tool-shape notes with synthetic examples.
- Replace provider-specific Claude wrapper support with generic custom Claude harness configuration.
- Add Remote UI warning for unauthenticated non-loopback binds.
- Use `TYCHO_*` environment variables as the public runtime override contract.
- Add `tycho serve` and `tycho schedule daemon` so packaged installs can use one `tycho` command.
- Move default config, schedule prompts, runtime state, and logs under `~/.tycho`.
- Keep Homebrew installs from writing runtime process-shim files under the Cellar.

Upgrade notes:

- Homebrew users run `tycho`, `tycho serve`, and `tycho schedule daemon`.
- Existing source-checkout users should move local config, schedules, and logs
  into `~/.tycho` before relying on the new defaults.
