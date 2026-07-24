# Design-system migration

## Current adoption

The system is loaded on every Remote UI route. Migrated product areas now include Settings → Response style, agent/project/schedule lifecycle forms, structured inquiries, representative agent/schedule/project/setup/diff statuses, primary non-modal menu overlays, and consequential confirmation flows. The preview route exercises all first-release components.

Classification:

- Direct replacement: common buttons, icon buttons, fields, inputs, alerts, and non-interactive surfaces.
- Small adapter: legacy button/surface classes that still carry route layout or JavaScript selectors.
- Requires product decision: compact metadata hierarchy, tooltips, and product-specific full-screen overlays.
- Intentionally product-specific: app shell, conversation, composer, inquiry flow, diff/code reader, attachment reader.
- Deprecated but supported: `--bg`, `--panel`, `--text`, `--muted`, `--border`, `--accent`, and intent aliases.
- Out of scope for the first release: a standalone package, Storybook, light theme, RTL, chart/data-grid primitives.

## Waves

1. Migrate high-frequency buttons, fields, alerts, and surfaces on agent/project/schedule forms. Remove duplicate declarations only after browser comparison.
2. Normalize form validation and feedback, including inquiry fields, server token forms, and pending states.
3. Resolve status taxonomy, then migrate badges and non-modal menu interaction.
4. Define composite patterns for form pages, searchable agent lists, focused readers, and confirmation flows.
5. Remove compatibility token aliases and obsolete selectors after repository searches reach zero.

Compatibility classes are allowed when they keep behavior selectors stable. Mark them `Legacy adapter: remove after <route> migration` and do not add new visual rules to them.

## Safeguards

- New shared CSS belongs in `design_system.css`; route-specific CSS belongs in `app.css`.
- New shared color declarations require a semantic token.
- Review checks: component contract, native semantics, focus, 44px targets, 390px reflow, reduced motion, and route/browser evidence.
- `test/remote_server_test.rb` asserts the asset, preview, semantic tokens, component selectors, and representative migration.
- The component preview is a stable visual capture target.

No codemod is included because current markup is generated from many context-sensitive template strings; the mapping is not safe enough for mechanical replacement.

## Adoption indicators

Track per release:

- Routes with at least one `ds-` component / total primary routes.
- Remaining legacy token references in `app.css`.
- Remaining raw palette declarations outside token foundations.
- Remaining `.primary`, `.danger`, and unclassified button occurrences in generated markup.
- Field controls without programmatic descriptions/errors.
- Browser-verified routes and states.
- Open accessibility defects.

Current baseline:

- 6 representative product form/decision surfaces migrated.
- 7 menu families use the shared overlay surface or interaction contract.
- 7 destructive or disruptive action families use the shared confirmation dialog.
- 1 preview route added.
- Shared system loaded on all routes.
- Legacy aliases remain; broad route migration is incomplete.

## Next implementation wave

Define composite form-page and settings-section patterns next, using the migrated lifecycle and Response style surfaces as evidence. The dedicated agent archive page remains product-specific because its clone alternative cannot fit a binary confirmation contract. Remaining legacy metadata pills can move independently because they do not encode health or urgency.
