# Technical Debt Audit - 2026-06-15

## Scope

This pass looked for debt that is likely to slow near-term feature work or create operational surprises. The repo is currently healthy at the public-suite level: `bin/test` passes.

## Priority Areas

### 1. Remote UI Client Monolith And Browser Verification

`lib/hq/remote_ui/assets/app.js` is large and owns routing, state preservation, rendering, polling, Markdown rendering, attachments, schedules, push notification UI, and header/menu behavior in one script. Server-side tests assert many static expectations against the served asset, but there is no dedicated JavaScript or browser automation harness in the repo. That leaves the most fragile Remote UI promises, especially polling preservation, sticky docks, mobile layout, and real form behavior, dependent on manual checks.

Recommended first slice:

- Split a small pure module boundary inside the existing no-build setup: sorting/filtering, route parsing, or form draft state.
- Add a lightweight browser smoke script for `bin/tycho serve` using temporary `TYCHO_CONFIG_PATH`, `TYCHO_SYSTEM_PROMPTS_PATH`, and `TYCHO_LOGS_ROOT`.
- Cover one concrete operator workflow first: active agent chat form value survives forced refresh and polling.

### 2. File Persistence Safety And Silent Recovery

Runtime state is file-backed, which fits Tycho's local-first design, but several critical stores still use direct overwrite writes and broad rescue fallbacks. `AgentStore#load_with_poll_events` returns `[]` on any read, parse, poll, or backfill failure; `AgentStore#save`, `ScheduleStore#save`, daemon state writes, action state writes, push stores, and attachment records use direct `File.write`. A partial write or concurrent write between TUI, Remote UI, and scheduler surfaces can therefore look like empty state rather than a recoverable corruption event.

Recommended first slice:

- Add a small shared persistence helper for JSON/YAML writes: write temp file, `fsync`, rename, and optionally keep `.bak`.
- Replace `AgentStore#save` and `ScheduleStore#save` first because those are operator-visible and shared across surfaces.
- Change broad load fallbacks from silent empty state to logged warnings plus backup recovery where practical.

### 3. Managed Agent Responsibility Split

`lib/hq/domain/managed_agent.rb` is 1,900 lines and owns command construction, process lifecycle, native session resume, status files, raw-log parsing, structured result normalization, inquiry normalization, attachment normalization, summary generation, and memory capture. The tests cover important regressions, but the class is now the convergence point for every provider-format change and every agent runtime behavior change.

Recommended first slice:

- Extract command building into an `AgentCommandBuilder` or per-adapter builder while preserving the current command arrays exactly.
- Extract structured result parsing/normalization into a small object with fixture-driven tests for Codex, Claude, and custom Claude-compatible streams.
- Keep process lifecycle in `ManagedAgent` until the parsing and command seams are proven stable.

## Suggested Order

1. File persistence safety: smallest user-visible blast-radius reduction, and it protects all later refactors.
2. Managed-agent parsing/command extraction: reduces risk around the most active feature surface.
3. Remote UI browser harness: needed before larger Remote UI schedule-management work, but easiest to land after the data layer is safer.

## Verification

- `bin/test` passed on 2026-06-15.
- Debt-payment pass completed on 2026-06-15:
  - Added `HQ::FileStore` for atomic JSON writes, `.bak` recovery, and logged read failures.
  - Migrated `AgentStore` and `ScheduleStore` state writes to `HQ::FileStore`.
  - Extracted managed-agent command construction into `HQ::AgentCommandBuilder`.
  - Added `bin/remote-ui-smoke` for a throwaway Remote UI Chrome/Playwright smoke check.
- Continuation pass completed on 2026-06-15:
  - Migrated action state, push notification/subscription stores, PR diff snapshots, VAPID keys, and agent attachment sidecars to `HQ::FileStore`.
  - Extracted raw-log structured payload parsing into `HQ::AgentStructuredResult`.
- Second continuation pass completed on 2026-06-15:
  - Added atomic YAML writes through `HQ::FileStore` and migrated registry and schedule registry YAML persistence.
  - Extracted structured result, inquiry, and attachment normalization into `HQ::AgentResultNormalizer`.
- Remote UI continuation pass completed on 2026-06-15:
  - Added a versioned `app_helpers.js` asset and served it as `/ui-helpers.js`.
  - Moved pure agent-sort normalization and comparators into the helper namespace while keeping state-aware UI wrappers in `app.js`.
- Remote UI route-helper continuation completed on 2026-06-15:
  - Moved hash route parsing, route serialization, diff-scope normalization, and route state-key generation into `app_helpers.js`.
  - Kept thin `app.js` wrappers so rendering, navigation, markdown anchors, and form-draft call sites remain stable.
- Remote UI form-preservation continuation completed on 2026-06-15:
  - Moved control state, text selection, draftable-control, element-key, and safe localStorage primitives into `app_helpers.js`.
  - Kept the high-level view snapshot and form draft flows in `app.js` so same-route refresh behavior stays easy to follow.
- Remote UI Markdown/attachment continuation completed on 2026-06-15:
  - Moved Markdown heading slug/hash fragment helpers and attachment target/id/path/freshness primitives into `app_helpers.js`.
  - Kept Markdown rendering, scrolling, attachment lookup, and attachment UI rendering in `app.js`.

## Completion Assessment

The selected 2-3 debt areas are complete for this pass: file persistence now has shared atomic JSON/YAML helpers, managed-agent command/parsing/normalization responsibilities have been split into focused domain objects, and the Remote UI now has a browser smoke check plus a first helper boundary for pure client logic. Remaining debt is incremental rather than blocking: `app.js` and `ManagedAgent` are still large, but the seams needed for safer follow-up work now exist.
