# Remote UI design audit

Date: 2026-07-11

## Implementation status

Implemented on 2026-07-11. The remediation includes the responsive desktop shell and persistent uncropped in-shell side navigation across top-level and detail routes, consistently named New agent action, explicit creation submission, fixed-region safe-area handling, shared control sizing, mobile zoom-safe form text, live inquiry validation, compact form sections, a sticky Settings section navigator over one continuous page, copyable conversation session IDs, state-dependent notification actions, blocked-agent recovery, summary metadata, adjustable/full-view focused panes, an in-flow desktop conversation composer, compact mobile follow-up composer, clarified primary/secondary agent creation, clarified diff actions, attachment action cleanup, and expanded browser regression coverage.

Final verification covered the same 64 route/state/viewport combinations plus targeted checks at 1100, 1200, 1280, 1366, and 1440 px. It found no page-level horizontal overflow, cropped desktop navigation, composer/content overlap, mobile input zoom risks, or browser console/failed-resource errors. `bin/test` and `bin/remote-ui-smoke` pass.

## Scope and method

The audit covered 64 rendered route/state/viewport combinations using isolated fixture data in Google Chrome. It included 23 primary routes, six transient states, five additional focused states, six tablet checks, and desktop (1440 × 1000), mobile (390 × 844), and tablet (768 × 1024) breakpoints.

Covered surfaces: Now, Agents, Settings, onboarding, project detail/edit/diff, agent conversation states (running, blocked, awaiting input, and success), summary, pull-request diffs, new/edit/clone/archive agent flows, new/edit/message schedule flows, hidden-project settings, Markdown/code/image attachments, quick-agent dialog, menus, flyouts, and bulk mode.

No page-level horizontal overflow was detected. The automated pass did find pervasive undersized controls, mobile inputs below the 16 px zoom-safe size, and four resource 404 console messages. Visual inspection found the higher-impact hierarchy, overlap, discoverability, and action-placement issues below.

## Recommended priorities

### P0 — blocks or hides core actions

1. **Add an explicit primary action to Quick Agent.** The desktop and mobile dialog show project, prompt, Options, and model metadata, but no visible Create/Run/Send action. Add a persistent primary action and a keyboard-shortcut hint; keep it visible above the mobile keyboard.
2. **Prevent fixed controls from covering content.** The mobile bottom dock and floating `+` overlap Settings actions/section headings, schedule fields, project forms, and list cards. Reserve safe-area and dock space in the scrolling container, and hide or relocate the FAB on forms and detail screens.
3. **Make the inquiry form operable without tiny targets.** Environment and confirmation checkboxes render at roughly 13 × 13 px and message overflow menus at 26 × 26 px. Give the whole label row a minimum 44 px hit area, visibly separate required fields, and keep Send Answer disabled with an inline explanation until validation passes.

### P1 — high-impact consistency and responsive improvements

4. **Adopt one responsive shell instead of a narrow mobile column on desktop.** Now, Agents, Settings, forms, and project detail remain about 820 px wide at 1440 px, leaving large dead gutters while still truncating names. Use the space for a wider content column or a contextual side panel. Keep the full-width split pane for conversation + attachment/diff views.
5. **Replace the desktop bottom navigation.** A mobile-style fixed bottom dock is unnecessary on desktop and visually interrupts long pages. Use a persistent top/side navigation at wider breakpoints and reserve the bottom dock for compact screens.
6. **Standardize control geometry.** Normalize buttons, icon buttons, inputs, segmented controls, pills, and row actions around a small set of heights. Many visible controls are below 44 px; conversation overflow buttons are 26 px, and several form inputs are only 28 px high.
7. **Use a contextual creation action.** The global floating `+` is ambiguous and duplicates Add Agent/Add Server/Create Schedule actions. It appears far outside the desktop app frame and covers content on mobile. Label it for the current context, move it into the page header, or show it only on list screens.
8. **Improve the compact header.** Long project/agent titles truncate before the user can distinguish the current object; breadcrumb metadata truncates independently, while Back, status mark, and More consume substantial width. Allow a two-line title/subtitle, prioritize the object name, and move secondary metadata into a details affordance.
9. **Make sticky regions cooperate.** Header, composer, bottom nav, flyouts, and FAB compete for the same viewport. Define a single stacking/safe-area model so content never scrolls underneath an opaque control without matching padding.
10. **Use 16 px text for all mobile form controls.** Settings textareas use 12 px, inquiry controls use 13 px, and several compact inputs are below 16 px, creating iOS auto-zoom risk and reduced legibility.

## Page-by-page findings

### Now / Needs attention

- The attention card is clear, but the large count (`1`) and plural copy (“items”) disagree. Add correct pluralization.
- “Review first item” is vague. Use the pending agent/task title or “Answer release strategy” so the outcome is predictable.
- Status hierarchy relies heavily on small pills and orange accents shared by answer, blocked, and unread states. Give operator-required, blocked, unread, and running states distinct semantic treatments.
- Mobile titles and project metadata truncate aggressively. Allow two-line titles or reduce repeated harness/model/effort metadata.
- The fixed nav and FAB cover list content during scroll. Add bottom padding and keep creation controls outside the card area.
- Expanded schedules combine state, counts, and multiple row actions densely. Separate schedule health from run controls and use a clear state label with one primary action per row.

### Agents

- Project headings truncate even on desktop despite large unused gutters. Widen the content frame before truncating group names.
- Search is only 26 px high and visually cramped between two icon-only actions. Increase height, add labels/tooltips to Sort and Bulk Archive, and expose the active sort near the result count.
- Agent rows show title, elapsed time, project, harness, model, effort, icon, and status in a small area. Keep the title and state primary; move stable runtime metadata to the detail page or a secondary line.
- The same `+ Agent` action repeats for every group while the global FAB also creates. Prefer one contextual action per group and remove the duplicate FAB.
- Sort options are presented as a long floating list with no checkmark for the current value. Use radio/check state and clearer groupings (“Agent name,” “Last update,” “Project”).
- Bulk mode needs a stronger mode banner and persistent selection/action summary so users do not confuse checkboxes with ordinary row affordances.

### Settings

- This is the densest screen and lacks a top-level information architecture. Split it into Connection, Servers, Notifications, Automation, Storage, and Preferences subsections or tabs.
- The fixed dock covers the Automation Readiness heading on mobile; the FAB also overlaps notification and server-form controls. This is a functional obstruction, not just visual noise.
- Remote connection status uses several equal-weight pills (“API ok,” “Local,” “Direct URL”) without explaining the desired/active transport. Show one primary connection state and place diagnostic facts behind Details.
- Server rows mix state, token warning, switching, editing, and deletion. Make the active server obvious, put destructive Remove behind a menu/confirmation, and show “Token required” beside the Token action.
- Notification controls expose Enable, Send test, and Disable simultaneously, including unavailable-looking actions. Show actions appropriate to the current permission/subscription state and explain why disabled actions are unavailable.
- Repetitive readiness cards create a long status wall. Group successful checks into a compact “All ready” summary and expand failures/warnings by default.
- Configuration tiles use icon-only copy buttons without saying what will be copied. Add accessible labels/tooltips and make path/value copy discoverable.
- The Add Server form opens inline inside an already long page. Use a focused modal/sheet or accordion with a sticky Save action; ensure the dock does not cover the final fields.

### Agent conversation: running, blocked, awaiting input, success

- Conversation cards are readable, but role labels, timestamps, section counts, and per-message overflow actions are too small and low-emphasis.
- Every message exposes a 26 × 26 px overflow target. Increase the hit area and only show secondary menus on hover/focus at wide breakpoints.
- The sticky header reappears between conversation blocks while scrolling and consumes a large portion of the narrow viewport. Reduce its collapsed height and avoid duplicating information already visible in the conversation.
- The composer, navigation chips, attachment count, upload, agent settings, archive, and Send Prompt compete in one dock. Establish a clear primary action, group utilities in one menu, and keep the text area visually dominant.
- Summary/PR Diff chips change by state and location. Keep a stable secondary-navigation row and show the current view as selected.
- Code blocks clip long lines without an obvious horizontal-scroll affordance. Add a visible scroll treatment, wrapping toggle, or copy action.
- Blocked state should make the blocker and recovery action the first element after the header, rather than requiring users to infer it from conversation history.
- Success state repeats summary information in the timeline and a separate Summary screen. Use the timeline card as a compact link and reserve the dedicated view for full result details.

### Inquiry

- The form begins below a long conversation, so the required decision is not immediately visible. On awaiting-input agents, jump to or pin a compact decision panel near the top.
- Required labels, help copy, inputs, checkboxes, confirmation, upload, and Send Answer use several different component sizes and emphasis levels. Standardize the form rhythm.
- Checkbox controls and confirmation are too small; the label row should be clickable and at least 44 px high.
- The confirmation sentence is long and styled like a warning card. Shorten it to an explicit acknowledgement and explain any irreversible consequence separately.
- Preserve the user's progress if they inspect conversation, attachments, or other routes before submitting.

### Summary

- The summary screen is extremely sparse on desktop and does not use available width. Add structured outcome metadata (status, completion time, run duration), key changes, verification, attachments, and next actions.
- Long attachment names dominate the card while type/path metadata remains noisy. Lead with a concise title, then file/link type and a compact path.
- The composer remains visible on a read-focused result page. Collapse it behind “Continue conversation” unless immediate follow-up is the dominant workflow.

### Pull-request diffs

- Desktop split view is useful, but three refresh actions (“Refresh list,” “Refresh all diffs,” and “Fetch”) have overlapping meaning. Consolidate them into refresh metadata vs fetch content, with clear scope.
- Mobile stacks three full-width toolbar buttons before the PR card, consuming significant vertical space. Use a compact overflow toolbar and retain one primary Fetch/Refresh action.
- The PR card truncates its title while allocating a narrow right rail to Fetch, Collapse all, and Open PR. On mobile, place title/metadata first and actions in a compact row/menu below.
- “Not Found (HTTP 404)” and “metadata unavailable” need an actionable recovery explanation (repository access, remote URL, authentication, or retry), not only a raw transport error.
- The large empty “Diff not fetched” panel should include the Fetch action and required-state explanation directly in the empty state.

### Project detail

- Desktop project detail leaves most of the viewport unused while long paths wrap inside narrow cards. Use a two-column summary (workspace/revision/changes and managed agents) or widen the content area.
- Status chips such as PR, branch, dirty count, configured, unread, and in progress use the same visual family despite different semantics. Establish a consistent semantic color/status system.
- Revision Copy is text, while other copy actions elsewhere are icon-only. Normalize copy affordances and feedback.
- “Templates and workspace” hides important context behind a low-emphasis disclosure. Show the active template/workspace summary before collapse.

### Project diff

- Desktop layout is clear, but long lines clip without an obvious scrolling or wrapping control.
- On mobile, Worktree/Staged/All becomes a three-row stack and Collapse/Refresh become two more full-width rows. Replace with a horizontally compact segmented control or select plus an overflow menu.
- The global FAB overlaps the code diff/card boundary and can be mistaken for a diff action. Hide it on diff/detail screens.
- File status appears both in the summary and file card with limited explanation. Clarify staged/unstaged/untracked semantics and make changed-line counts consistently formatted.

### Project edit

- Read-only project facts are presented as three nested cards inside a larger card, making the editable fields start far below the header. Compress fixed metadata into a summary block.
- Name and Group inputs are 28 px high on mobile and differ from the larger select controls. Normalize input height and typography.
- Long workspace/PR values wrap awkwardly; provide middle truncation with a Copy/View affordance.
- The FAB appears on an edit form and overlaps fields. Remove global creation actions from focused forms.

### Agent new / edit / clone

- Each field sits in its own large bordered card, producing excessive vertical scrolling. Use a conventional form with section headings and consistent field spacing.
- Template, harness, model, and effort read like inputs but are visually indistinguishable from editable text fields. Use native select semantics and clear chevrons/current-value treatment.
- Long default names are clipped inside 28 px inputs. Increase height, use 16 px text, and allow full-value inspection.
- Workspace cards consume substantial height and wrap paths over many lines. Use middle truncation plus Copy/Open; only show full path on demand.
- New Agent has two competing primary outcomes (“Create agent” and “Create and run”). Make one primary and the other a secondary split/menu action with explanatory copy.
- Clone Agent’s “Clone and archive” bundles creation and destructive archival. Explain the two-step consequence near the action and offer Clone only where appropriate.

### Agent archive

- This is one of the cleaner screens: consequence, source facts, and alternatives are visible.
- “Clone instead” is styled as the primary action, which may be intentional but can bias users away from the requested archive flow. Use neutral hierarchy unless cloning is the recommended safety path, and state why.
- Keep the destructive Archive action visually distinct and require confirmation only once; avoid forcing the user through a second modal without new information.

### Schedule new / edit / message

- Schedule forms are very long because every field is card-wrapped and large textareas dominate. Group Identity, Timing, Agent, and Messages into compact sections.
- Cron has helpful translated copy, but the next run/validation state is missing. Show timezone-aware next-run previews and inline validation.
- Fixed Key and generated System Message use the same input treatment as editable values. Use read-only styling and explain what will change when dependent fields change.
- The FAB overlaps Agent Name/System Message on mobile and has no relevant meaning on a schedule form. Hide it.
- Keep Cancel/Save/Create actions sticky above the safe area on long forms, but do not obscure fields.
- Schedule Message is too sparse for a recurring run action. Include schedule identity, last/next run, message preview, and whether this run joins the existing session.

### Hidden project settings

- Three icon-only states (hidden, inherit/group, visible) are difficult to infer, and selected colors vary between warning red, neutral, and green. Add a legend and text labels or a proper three-state segmented control.
- Group and project cards repeat counts and visibility phrases densely. Put the effective visibility first, then inherited source and agent count.
- Long names truncate before the distinguishing text. Allow two lines or show full names on focus/press.
- The global FAB is unrelated to visibility management and overlaps a project row. Hide it on Settings subroutes.

### Attachment viewer: Markdown, code, image

- Desktop split-pane preserves context well, but the attachment pane starts at half width even for reading long Markdown/code. Provide draggable pane sizing and a distraction-free Full View toggle.
- Attachment title, type, context, full local path, index, copy, secondary copy, download, and delete are visually crowded. Establish a header hierarchy and move secondary/destructive actions into an overflow menu.
- The full local path wraps across several mobile lines and overwhelms the content. Use middle truncation with Copy/Reveal details.
- Two adjacent copy controls (“Copy content” plus icon-only copy) are ambiguous. Name their different scopes or remove the duplicate.
- Code is clipped horizontally without a visible scroll/wrap affordance. Add line wrapping toggle, horizontal-scroll cue, and sticky line numbers if applicable.
- The image fixture renders as a nearly invisible dot. A real image should have a bounded preview area, loading/error state, dimensions/file size, zoom, and fit-to-screen controls.
- The mobile viewer leaves a very large empty region above the fixed composer. Let content define page height and collapse the composer on read-only attachment pages.
- Delete sits next to frequent copy/download actions. Separate it spatially and confirm with the attachment name.

### Onboarding

- The core message and single CTA are clear.
- The local workspace path wraps mid-word on mobile (`wel` / `come`). Use `overflow-wrap: anywhere`, middle truncation, or a copyable code block without breaking path semantics.
- “Create Welcome Sandbox” does not explain what will be created or whether it is safe to remove. Add a short outcome statement and approximate next step.
- Desktop onboarding is confined to a small card within a narrow column and leaves substantial unused space. Use a slightly wider, balanced welcome layout while keeping one dominant action.

### Header switcher, menus, flyouts, and transient states

- The header switcher packs notification, hidden projects, refresh, active server, and restart actions into a dense panel. Group Navigation, Connection, and Server actions and keep destructive/restart actions separate.
- Menus need visible selected states, keyboard focus, outside-click dismissal, and Escape behavior.
- The attachment flyout becomes a tall overlay on mobile and competes with the composer. Use a bottom sheet with its own scroll area and a clear close/header, or navigate to a dedicated attachments screen.
- Attachment rows wrap local paths heavily and place download/delete beside each other. Lead with title/type and place risky actions in a menu.
- Dialogs/sheets should have a visible primary action, scrollable body, sticky footer, and safe-area/keyboard handling.

## Design-system and accessibility follow-up

1. Define tokens for input/button heights, icon-button sizes, card spacing, radii, status colors, sticky offsets, and mobile safe areas.
2. Target at least 44 × 44 px pointer areas for touch controls while allowing smaller visual icons inside those areas.
3. Add visible focus styles, accessible names for icon-only actions, selected state beyond color, and text alternatives for status icons.
4. Validate contrast for muted metadata, borders, disabled controls, orange status text, and purple-on-purple selections.
5. Add responsive visual regression coverage for sticky overlap, Quick Agent action visibility, long paths/titles, code overflow, and form controls at 390, 768, and 1440 px.
6. Investigate the four resource 404 console messages and ensure failed assets/data requests produce intentional in-UI error states.

## Suggested implementation order

1. Fix Quick Agent submission, dock/FAB overlap, inquiry target sizes, and mobile input font sizes.
2. Introduce the responsive shell and hide/rehome the global FAB and desktop bottom nav.
3. Normalize form/control components and compact the long Settings, Agent, and Schedule screens.
4. Refine conversation/composer, PR diff, and attachment information architecture.
5. Add design tokens, accessibility checks, and screenshot regressions to prevent recurrence.
