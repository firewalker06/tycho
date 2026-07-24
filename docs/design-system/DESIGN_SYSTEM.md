# Tycho Design System

Status: first production increment  
Owners: maintainers of `lib/hq/remote_ui/`

## Principles

### Keep operator state unmistakable

Tycho supervises long-running processes where a hidden wait, failure, or target server can waste time. State labels combine text, shape, and color, and the primary recovery action stays near the state.

Following: “Decision required” with a warning treatment and the requested decision.  
Violating: three orange dots that require the operator to infer whether an agent is running, blocked, or unread.

### Preserve context while work changes

Polling, streaming, and focused readers must not move or erase the operator’s draft, focus, scroll position, or current object.

Following: preserve the response-style textarea node and focus during refresh.  
Violating: rebuilding a focused form every polling cycle.

### Use density deliberately

Tycho serves experienced operators, so dense metadata is useful when it supports a decision. Primary identity and state remain readable; stable implementation detail moves to secondary text or a detail view.

Following: agent name and status first, model and elapsed time second.  
Violating: giving project path, model, effort, harness, timestamp, and status equal visual weight.

### Keep consequential actions explicit

Starting work, answering an inquiry, removing a server, and archiving an agent have different consequences. Labels describe the outcome, danger is not hidden beside routine controls, and bundled actions explain both effects.

Following: “Create and run” plus a secondary “Create without running.”  
Violating: an unlabeled plus button that may create, run, or attach depending on context.

### Prefer stable layout to decorative motion

Motion communicates loading, entry, or spatial change. It never becomes the only state cue, and reduced-motion users keep the same information.

Following: a small spinner beside “Starting.”  
Violating: pulsing an entire card without a text status.

## Architecture

The system follows the repository rather than adding a framework:

1. `design_system.css` owns primitive and semantic tokens, layout primitives, and reusable components.
2. `app.css` owns shell, route, and product-pattern composition.
3. `design_system.html.erb` is a zero-build component preview at `/design-system`.
4. `app.js` keeps product behavior and incrementally adds system classes to existing markup.

The CSS is served as one `/ui.css` response so deployment, cache-busting, and the no-build runtime stay unchanged. `HQ::RemoteUI.asset_version` includes the new assets.

## Tokens

Use `--ds-*` tokens in shared code. The legacy aliases (`--bg`, `--panel`, `--accent`, and similar) map to semantic roles and remain while product CSS migrates.

Token tiers:

- Primitive: `--ds-color-dracula-900`, `--ds-color-lavender`.
- Semantic: `--ds-background-canvas`, `--ds-text-muted`, `--ds-action-brand`, `--ds-feedback-danger`.
- Component values: currently component selectors consume semantic tokens directly. Add component-level tokens only when a component needs a stable exception.

Do not add a raw color to component or product CSS unless it represents content outside the theme, such as syntax data that cannot use an existing semantic role. Add or change a semantic token when the same role occurs in more than one component.

Foundations cover:

- Canvas, surface, raised, sunken, overlay, and backdrop.
- Primary, secondary, muted, disabled, and inverse text.
- Subtle/default/strong borders and focus.
- Brand, neutral hover, link/selection, information, success, warning, and danger.
- System sans/mono typography, seven size steps, three weights, and readable measures.
- A 4/8/12/16/24/32/48px spacing rhythm.
- 36/44/48px controls and a 44px minimum pointer target.
- Three radii, two elevations, standard focus rings.
- Fast/standard/enter motion and a reduced-motion policy.
- A small documented z-index ladder from base through tooltip.

Dark Dracula is the only supported theme. A light theme is intentionally out of scope because there is no product requirement or existing architecture to verify it.

## Component conventions

- Shared selectors use the `ds-` prefix. Product patterns keep product names.
- Variants are semantic `data-variant`/`data-intent` values such as `brand`, `danger`, and `warning`.
- Related controls use `small`, default, or `large`; do not expose pixel heights.
- Native attributes remain the behavior contract: `disabled`, `readonly`, `required`, `aria-invalid`, and `aria-describedby`.
- Icon-only buttons require an accessible name.
- Buttons may contain the existing `.ui-icon`; icons are decorative when adjacent text gives the name.
- Loading keeps the label and width stable, adds `data-loading="true"`, and uses a spinner hidden from assistive technology. Async completion is announced by the product live region.
- Consumers may add product classes for layout, but must not override state semantics.
- Interactive elements must not be nested.
- Existing data attributes remain analytics/test/behavior hooks; the system does not invent a parallel test-selector API.
- IDs stay deterministic because render functions already know the field/object key.
- The app is client-rendered after ERB and has no hydration boundary.
- Long content must wrap or expose scrolling; truncation requires an accessible full-value affordance.

## Implemented contracts

### Button and icon button

Purpose: trigger an action or submit a form. Use links for navigation.

API: `.ds-button`, optional `data-variant="brand|danger"`, `data-size="small|large"`, `data-loading="true"`, and `.ds-icon-button`.

States: default, hover, active, focus-visible, disabled, loading. Loading does not automatically disable behavior; the caller sets `disabled` while a request is pending.

Keyboard: native button/link behavior. Icon-only buttons require `aria-label`.

Test matrix: all variants, disabled, loading, long label, 390px width, focus-visible, reduced motion.

Migration: retain existing behavior classes/data attributes and add `.ds-button`; convert `primary` to `data-variant="brand"` and `danger` to `data-variant="danger"`.

### Field and input

Purpose: label a native input, select, or textarea and connect help/error content.

Anatomy: `.ds-field`, `.ds-field__label`, `.ds-input`, optional description/error. Help and error nodes require IDs referenced by `aria-describedby`; errors pair with `aria-invalid="true"`.

States: default, focus-visible, disabled, read-only, invalid, long value. Textareas resize vertically.

Keyboard: native control behavior. Mobile controls remain at 16px to prevent browser zoom.

Migration: replace the visual `field-card` wrapper only when its card boundary is not a product grouping; otherwise nest the field anatomy inside it.

### Surface

Purpose: group related content. It is not interactive.

API: `.ds-surface`, optional `data-elevation="raised"`. Product layout belongs on a second class or a layout primitive.

Migration: add to `summary-card`, `detail-card`, and settings panels as they are touched; remove duplicate border/background declarations after the route is visually verified.

### Alert

Purpose: communicate information, success, warning, or failure. Use `role="alert"` only for urgent errors introduced after page load; use `role="status"` for non-urgent async state.

API: `.ds-alert`, `data-intent="success|warning|danger"`, `.ds-alert__title`.

The marker and text communicate intent without color alone.

### Layout primitives

`ds-stack`, `ds-cluster`, and `ds-grid` arrange children but do not supply product meaning. Customize gaps with local `--ds-*-gap` variables. `data-collapse="mobile"` changes a cluster to a vertical mobile action group.

### Badge, spinner, skeleton, and empty state

Badges label compact status; they do not replace full error or recovery copy. Spinners accompany a persistent text label. Skeletons are for predictable loading geometry and stop animating with reduced motion. Empty states state what is empty and, when useful, what to do next.

### Product status

`ds-status` extends the badge contract with six operational intents:

| Intent | Meaning | Examples |
| --- | --- | --- |
| `neutral` | Context with no health or urgency claim | Idle, fixed, read-only |
| `info` | Informational state requiring no response | No action, configured, snapshot |
| `active` | Work currently progressing | Running, fetching |
| `warning` | Attention, user action, or degraded freshness | Answer required, unread, paused, dirty, stale |
| `success` | Healthy or completed state | Succeeded, scheduled, ready, clean, fresh |
| `danger` | Failed, blocked, stopped, or invalid state | Blocked, failed, missing, stopped |

Visible labels carry the meaning. Color is reinforcement. Product status icons remain `aria-hidden` when an adjacent badge supplies the text. Metadata such as a PID, branch, format, or item count is not a status and should use a neutral badge or ordinary text.

The migration keeps legacy `need`, `running`, `done`, `fail`, `info`, and `detail` classes as layout/color adapters. `statusIntent` is the single mapping to semantic intent; new code should not add another status-class vocabulary.

### Menu overlay

`ds-overlay-surface` owns the semantic overlay background, boundary, elevation, and dropdown layer. Product classes continue to own anchoring, width, collision handling, and content layout.

Native `details` menus opt into the shared interaction contract with `data-overlay-menu` and a stable `data-overlay-key`. The trigger remains a direct `summary` with `aria-haspopup="menu"`; menu actions use `role="menuitem"` or `role="menuitemradio"`.

Keyboard behavior:

- Opening focuses the first enabled item.
- Arrow Up/Down wraps through enabled items; Home/End move to an edge.
- Escape closes the current menu and restores focus to its trigger.
- An outside click dismisses without stealing focus from the clicked target.
- Opening one registered details menu closes registered peers.

The global More menu and agent switcher use the same focus-origin helpers because their open state lives in application state rather than a native `details` element. The quick-agent modal remains a native `dialog`; its focus trap, Escape behavior, and focus restoration stay browser-owned.

Use this contract for action and exclusive-selection menus. Do not use it for persistent disclosure sections, form expanders, tooltips, or full-screen editors.

### Confirmation dialog

`confirmAction` is the single contract for consequential actions that need an explicit second step. It renders a native `dialog` with `ds-confirmation-dialog` anatomy and returns a promise resolving to the operator’s choice.

API:

- `title`: a concrete question naming the object or system.
- `description`: the consequence, what remains, and any recovery boundary.
- `confirmLabel`: the exact action, never a generic “Yes”.
- `cancelLabel`: defaults to “Cancel”.
- `intent`: `danger` for destructive actions or `warning` for disruptive but recoverable actions.

Behavior:

- Cancel receives initial focus so Enter cannot immediately trigger destruction.
- Escape, backdrop click, and Cancel resolve false.
- The explicit action resolves true.
- The native dialog traps focus and makes the rest of the page inert.
- Closing restores focus to the invoking control when it still exists.
- At mobile widths, actions use full-width 44px controls without horizontal overflow.
- A native `window.confirm` fallback remains only for browsers without `dialog.showModal`.

Use a confirmation when an action removes data, archives multiple objects, stops automation, or interrupts the server. Do not add it to reversible navigation, local form cancellation, or removal of an unsaved attachment from a draft. The dedicated agent archive page remains product-specific because it offers “Clone instead” and shows the full source-agent context.

## Representative migration

Settings → Response style is the first vertical slice:

- Summary uses `ds-surface`.
- Edit/delete/cancel/save use the shared button contract.
- The editor uses field anatomy, a programmatic description, and shared textarea.
- Failure uses a danger alert with `role="alert"`.
- Existing polling preservation, file persistence, deletion confirmation, data attributes, and API calls are unchanged.

This slice exercises foundations, layout, typography, actions, form controls, async error feedback, destructive action styling, focus, and mobile reflow without replacing business behavior.

The second adoption wave migrates agent, project, schedule, and schedule-message lifecycle forms. Each form keeps its existing product layout and JavaScript contract while shared classes own labels, descriptions, native controls, read-only treatment, and action variants. Descriptive copy now has deterministic IDs connected with `aria-describedby`.

The third wave migrates structured inquiries. Text, number, select, multiline, and feedback controls use the field/input contract. Multi-select answers expose a named `role="group"` instead of pointing a label at a nonexistent control. Invalid controls and groups use `aria-invalid` plus `aria-errormessage`; descriptive copy remains connected independently. The form-level polite status announces the current missing field or readiness without turning every field error into a live region.

The fourth wave introduces the product status taxonomy and migrates agent lists/switchers, schedules, project health, setup readiness, notification readiness, and diff freshness/file states. Display labels are consistently humanized while persisted/API state values remain unchanged.

The fifth wave centralizes non-modal overlays. Header, schedule, sort, view-layout, summary-attachment, and attachment-action menus now share focus origins, peer dismissal, Escape restoration, arrow navigation, and the semantic dropdown layer without replacing their product positioning or native details behavior.

The sixth wave replaces scattered browser confirmations with the shared native-dialog contract for response-style removal, peer-server removal, scheduler restart/stop, bulk archive, schedule deletion, attachment deletion, and Remote restart. Titles name the target, descriptions state what changes and what remains, and action labels describe the consequence.

## Accessibility and responsive rules

Target: WCAG 2.2 AA.

- Focus is a 2px semantic ring with 2px offset.
- Pointer targets are at least 44px for default/icon controls.
- Intent always includes text or a symbol, not color alone.
- Native controls and dialog/details semantics remain intact; registered menus add Escape restoration and arrow-key movement.
- Errors use `aria-invalid` and descriptions use `aria-describedby`.
- Product live regions announce polling/growl updates; avoid nesting extra live regions.
- CSS supports text resizing and narrow reflow; new layout primitives have no fixed content widths.
- Animation is reduced or removed under `prefers-reduced-motion`.
- Forced-colors mode restores explicit control boundaries.
- The application language is English. Do not claim RTL support until strings, icons, overflow, and interaction order are verified.

## Using the preview

Run `bundle exec bin/tycho serve`, then open `/design-system`. The preview uses realistic Tycho actions and states rather than exhaustive prop permutations. It is deliberately static and dependency-free.

## Contribution and governance

For a shared component proposal:

1. Show at least two product occurrences or one high-risk accessibility/behavior need.
2. State what remains product-specific.
3. Define semantics, API, states, keyboard behavior, responsive behavior, and content rules.
4. Add or update the preview, Ruby assertions, browser coverage, and migration mapping.
5. Verify at 390px and desktop, keyboard focus, reduced motion, and the affected product workflow.

Maintainers of the Remote UI decide proposals in normal review. Versioning follows the Tycho release because this is an internal system, not a separately published package. Add user-visible changes to `CHANGELOG.md`; record architectural decisions here. Deprecations must name the replacement, include a searchable comment, survive at least one release unless security requires otherwise, and define removal criteria.

Breaking changes require migration notes and all affected routes to migrate in the same release. Support targets current stable Chrome/Chromium, Safari, and Firefox versions that implement the modern CSS/native features already used by Tycho; exact minimum versions remain a follow-up governance task. Product-specific exceptions are allowed when documented in the inventory and implemented with semantic tokens.

Copy `COMPONENT_TEMPLATE.md` for future component documentation.
