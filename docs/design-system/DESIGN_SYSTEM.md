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

- Shared selectors use the `ui-` prefix. Product patterns keep product names.
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

API: `.ui-button`, optional `data-variant="brand|danger"`, `data-size="small|large"`, `data-loading="true"`, and `.ui-icon-button`.

States: default, hover, active, focus-visible, disabled, loading. Loading does not automatically disable behavior; the caller sets `disabled` while a request is pending.

Keyboard: native button/link behavior. Icon-only buttons require `aria-label`.

Test matrix: all variants, disabled, loading, long label, 390px width, focus-visible, reduced motion.

Migration: retain existing behavior classes/data attributes and add `.ui-button`; convert `primary` to `data-variant="brand"` and `danger` to `data-variant="danger"`. Every generated button or link that still carries the legacy `primary`, `danger`, `inline-icon-button`, `icon-button`, or `button-link` adapter now consumes this contract. Product-specific menu items, navigation tabs, reader controls without those adapters, and non-interactive loading labels retain their own contracts.

### Field and input

Purpose: label a native input, select, or textarea and connect help/error content.

Anatomy: `.ui-field`, `.ui-field__label`, `.ui-input`, optional description/error. Help and error nodes require IDs referenced by `aria-describedby`; errors pair with `aria-invalid="true"`.

States: default, focus-visible, disabled, read-only, invalid, long value. Textareas resize vertically.

Keyboard: native control behavior. Mobile controls remain at 16px to prevent browser zoom.

Migration: replace the visual `field-card` wrapper only when its card boundary is not a product grouping; otherwise nest the field anatomy inside it.

### Surface

Purpose: group related content. It is not interactive.

API: `.ui-surface`, optional `data-elevation="raised"`. Product layout belongs on a second class or a layout primitive.

Migration: add to `summary-card`, `detail-card`, and settings panels as they are touched; remove duplicate border/background declarations after the route is visually verified.

### Alert

Purpose: communicate information, success, warning, or failure. Use `role="alert"` only for urgent errors introduced after page load; use `role="status"` for non-urgent async state.

API: `.ui-alert`, `data-intent="success|warning|danger"`, `.ui-alert__title`.

The marker and text communicate intent without color alone.

### Layout primitives

`ui-stack`, `ui-cluster`, and `ui-grid` arrange children but do not supply product meaning. Customize gaps with local `--ds-*-gap` variables. `data-collapse="mobile"` changes a cluster to a vertical mobile action group.

### Badge, spinner, skeleton, and empty state

Badges label compact facts or status; they do not replace full error or recovery copy. Spinners accompany a persistent text label. Skeletons are for predictable loading geometry and stop animating with reduced motion.

`ui-empty-state` represents a settled absence, not loading or failure. It states what is empty and, when useful, what to do next. It has `data-state="empty"` and no live-region role by default, so normal polling does not repeatedly announce it.

`ui-loading-state` extends the same stable surface for route-level work. It has `data-state="loading"`, a persistent text label, `role="status"`, `aria-live="polite"`, and `aria-atomic="true"`. The Tycho logo is decorative; the visible label supplies the accessible status. Prefer a spinner inside a control and the branded loading surface for a whole view.

### Alert and recovery feedback

`ui-alert` communicates information, success, warning, or danger through `data-intent`. Visual intent does not determine live-region behavior. Static guidance and restrictions do not receive a live role. A new asynchronous progress message uses a polite status; a new failure that requires attention uses `role="alert"`.

Generated Remote UI markup uses `feedbackMessage(title, body, options)`. Titles and body text are escaped. `options.actions` accepts only trusted, application-owned markup and exists for recovery actions such as Stop agent; never pass server or user content through it. Set `announce: "polite"` or `announce: "assertive"` only when the message enters the page because state changed, not merely because polling rendered the same route again.

### Metadata badge

`ui-metadata-badge` is for compact factual context with no health, urgency, progress, selection, or filter meaning. Formats, counts, file sizes, commit identifiers, PR numbers, branches, diff scopes, process IDs, and timestamps belong here. Use ordinary secondary text when the fact is sentence-length or essential to comprehension.

Generated Remote UI markup uses `metadataBadge(label, "pill" | "chip")`. The second argument preserves existing product geometry during migration; it is not a semantic variant. Metadata badges do not use `data-intent`, icons, live-region roles, or color to imply state.

### Product status

`ui-status` extends the badge contract with six operational intents:

| Intent | Meaning | Examples |
| --- | --- | --- |
| `neutral` | Context with no health or urgency claim | Idle, fixed, read-only |
| `info` | Informational state requiring no response | No action, configured, snapshot |
| `active` | Work currently progressing | Running, fetching |
| `warning` | Attention, user action, or degraded freshness | Answer required, unread, paused, dirty, stale |
| `success` | Healthy or completed state | Succeeded, scheduled, ready, clean, fresh |
| `danger` | Failed, blocked, stopped, or invalid state | Blocked, failed, missing, stopped |

Remote UI agent outcomes use standalone official Lucide status icons: `pause` for paused or stopped, `check` in the success color for succeeded or success, `ban` in the failure color for failed, cancelled, or blocked, and the same `check` shape in grey for no-action. These indicators have an accessible name through `aria-label` and `title`, but no visible text, badge background, border, or padding. Scheduled agent rows give terminal outcomes the primary icon slot and retain scheduling as a separate named icon. Terminal surfaces retain their plain status text and do not use emoji for these states.

Visible labels carry the meaning. Color is reinforcement. Product status icons remain `aria-hidden` when an adjacent badge supplies the text. Neutral product states such as Idle, Fixed, and Read only still use `ui-status`; factual context uses `ui-metadata-badge`.

The migration keeps legacy `need`, `running`, `done`, `fail`, `info`, and `detail` classes as layout/color adapters. `statusIntent` is the single mapping to semantic intent; new code should not add another status-class vocabulary.

### Menu overlay

`ui-overlay-surface` owns the semantic overlay background, boundary, elevation, and dropdown layer. Product classes continue to own anchoring, width, collision handling, and content layout.

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

`confirmAction` is the single contract for consequential actions that need an explicit second step. It renders a native `dialog` with `ui-confirmation-dialog` anatomy and returns a promise resolving to the operator’s choice.

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

### Form layout

`ui-form-layout` supplies the shared grid boundary and 12px section rhythm for lifecycle forms. Product classes decide column count, spanning, sticky mobile actions, and feature-specific grouping.

`ui-form-section-heading` pairs an operational section label with short scope copy. It spans the product grid, uses document-order text rather than a visual-only divider, and stacks at narrow widths. It does not create a heading element automatically; consumers choose the correct semantic heading level for the surrounding page.

`ui-form-actions` aligns and wraps native actions with consistent spacing. Product patterns may make it sticky or change the mobile layout, but must preserve DOM order, explicit labels, disabled behavior, and at least 44px targets.

Use this pattern for multi-section create/edit flows. A single compact field group should use `ui-field` inside `ui-surface` without adding form-page ceremony.

The agent lifecycle form keeps its high-frequency identity, workspace, and instruction fields visible, then places prompt/runtime configuration in a native Advanced disclosure. Its closed summary lists the current template, response-style source, harness, model, and effort, so simplifying the form does not hide the defaults or make the available configuration opaque. The summary is synchronized after any advanced choice changes; the native controls keep their normal labels, submission behavior, and keyboard interaction.

### Section navigation

`ui-section-nav` is a horizontally scrollable set of in-page controls. The selected button uses `aria-current="location"`; each button needs `aria-controls` pointing to a `ui-section-panel`. Product code owns sticky positioning and the active-section observer because header offsets and route behavior are application concerns.

`ui-section-panel` supplies a stable grid and section rhythm. It does not add a visual surface, landmark, heading, or scroll offset by itself; compose those according to the content.

Keyboard behavior remains native button order. Selection must update `aria-current`, focus must remain visible when the row scrolls, and activating a control must move or reveal the named section without changing the route unexpectedly.

### Detail header

`ui-detail-header` is the shared shell header for focused project, agent, summary, attachment, and diff routes. Its fixed anatomy is:

- `ui-detail-header__back`: a native button with an explicit accessible name.
- `ui-detail-header__identity`: product mark plus the title/metadata block.
- `ui-detail-header__text`, `__title`, and `__metadata`: one page `h1` and one compact context line with deterministic truncation.
- `ui-detail-header__actions`: route-owned view, schedule, and overflow slots; each visible trigger uses `ui-detail-header__action`.

The shared contract owns the three-column grid, minimum widths, type hierarchy, truncation, action spacing, and 44px targets. The Remote UI shell owns fixed versus sticky positioning, safe-area padding, scroll behavior, split-reader width, menu contents, and route history.

Use it once at the top of a focused route. Keep the object name in the title and put project, state, branch, harness, or scope in the metadata line. Do not repeat the page title inside the reader body, turn metadata into an unlabeled action, or place primary form submission in the header.

Keyboard behavior stays native: Back follows route history, contextual buttons remain in DOM order, and menus use the shared overlay interaction contract. Long titles and metadata truncate visually but remain complete in the DOM and accessible name. At narrow widths, identity yields space to the leading and action slots without causing horizontal page overflow.

### Searchable collection

`ui-searchable-collection` composes a `ui-collection-toolbar`, a concise result status, and `ui-collection-results`. `ui-search-field` owns the compound search-control boundary and visible focus; the native search input retains its built-in editing and clearing behavior. `ui-collection-group` provides a stable clipping boundary for product rows without prescribing their content or selection model.

The result status must state the filtered count and current query, and the search input must reference it with `aria-describedby`. Product code owns filtering, sorting, grouping, empty-state copy, bulk selection, and row actions. Keep those behaviors outside the shared CSS contract because they differ by collection.

Use this pattern when search changes an on-page collection immediately. Do not use it for command palettes, server-backed query builders, or a single static list that does not need result feedback.

## Representative migration

Settings → Response style is the first vertical slice:

- Summary uses `ui-surface`.
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

The seventh wave extracts composite structure already shared by agent, project, schedule, schedule-message, and loop forms plus Settings. Shared classes now own form rhythm, section headings, action alignment, in-page section selection, section-panel spacing, and Session loop input presentation; route CSS retains responsive columns, sticky action bars, header offsets, and feature-specific surfaces. The agent form uses progressive disclosure for lower-frequency runtime settings while exposing their selected defaults in the closed summary.

The eighth wave migrates the Agents index to the searchable-collection contract. Search, sort, project grouping, bulk selection, empty states, and row navigation keep their existing product behavior; shared classes now own toolbar/search geometry, result spacing, and the visible result-count contract.

The ninth wave extracts the focused-route shell header used by project, agent, summary, attachment, and diff pages. Shared classes own its anatomy, title hierarchy, truncation, action spacing, and target size; existing route code still supplies text, back navigation, view controls, menus, fixed/sticky positioning, and split-reader behavior.

The tenth wave migrates Settings server connection, browser-token recovery, and harness-catalog forms. Shared field anatomy now owns label hierarchy, input surfaces, programmatic descriptions, action alignment, and pending presentation. Remote peer actions use one 44px More trigger and the shared native-details menu contract; Refresh, Edit token, and Remove server remain available without reserving a permanent action rail. The Agents toolbar owns the non-mutating server filter, while project groups and resource details show explicit owner and health badges. The destructive action is separated, Escape restores trigger focus, and removal still uses the shared confirmation dialog. Custom model/effort fields sit inside a native, state-preserving disclosure; its collapsed summary shows configured values or “No custom values,” so hiding the editor never hides active overrides. Product code still owns peer validation, browser-only token persistence, catalog parsing, API compatibility fallbacks, and the server/harness grids.

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
