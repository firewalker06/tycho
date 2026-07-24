# Design-system visual evidence

Captured: 2026-07-24  
Application: Tycho Remote UI  
Server: isolated `bin/tycho serve` fixture at `http://127.0.0.1:7487`  
Authentication: local operator, `TYCHO_REMOTE_TOKEN` unset  
Fixture: one local project for workflow captures; no real agents or production data  
Browser: installed Google Chrome, headless; Playwright used for true mobile viewport, focus, and form-state captures  
Worktree: local implementation worktree on the capture date

## Baseline

- `baseline/onboarding-default-1440x900.png`
- `baseline/onboarding-default-390x844.png`
- `baseline/settings-default-1440x900.png`
- `baseline/settings-default-390x844.png`

The baseline settings capture was taken before the isolated project fixture was added and includes the loading/unavailable state. The earlier full-state evidence remains in `docs/REMOTE_UI_DESIGN_AUDIT_2026-07-11.md`.

## Implementation

- `implementation/design-system-components-1440x900.png` — `/design-system`, default component states.
- `implementation/settings-default-1440x900.png` — `#settings`, initial/loading state.
- `implementation/settings-response-style-edit-390x844.png` — `#settings`, Response style editor open.
- `implementation/settings-response-style-confirmation-390x844.png` — destructive confirmation with safe initial focus, explicit consequence copy, and mobile action layout.
- `implementation/agent-create-390x844.png` and `agent-create-1440x900.png` — agent lifecycle form at mobile and desktop widths.
- `implementation/project-edit-390x844.png` — project lifecycle form at mobile width.
- `implementation/schedule-create-390x844.png` — schedule lifecycle form at mobile width.
- `implementation/inquiry-ready-fullscreen-390x844.png` — completed structured inquiry in the full-screen decision flow.
- `implementation/agents-status-taxonomy-390x844.png` and `agents-status-taxonomy-1440x900.png` — agent list with neutral, informational, active, warning, success, and danger states.
- `implementation/agent-sort-menu-open-390x844.png` — shared menu overlay with a visible keyboard focus ring at mobile width.
- `implementation/design-system-preview-390x844.png`, `design-system-preview-768x1024.png`, and `design-system-preview-1440x900.png` — current `/design-system` reference page including status and menu-overlay contracts.

## Responsive and accessibility

- `responsive/design-system-components-390x844.png` — `/design-system`, true 390px Playwright viewport, full page.
- `responsive/design-system-components-768x1024.png` — `/design-system`, tablet Playwright viewport, full page.
- `accessibility/button-focus-visible.png` — brand button with focus-visible state.
- `accessibility/inquiry-multiselect-error-390x844.png` — required multi-select group with focus, visible error text, and disabled submission.

Animations were reduced for the Playwright component capture. Dynamic timestamps and real agent data were not used.
