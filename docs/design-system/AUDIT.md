# Tycho Remote UI audit

Date: 2026-07-24  
Scope: the browser Remote UI served by `bin/tycho serve`; the Bubbletea TUI was inspected for product context but is not migrated.

## Technical map

| Concern | Verified implementation |
| --- | --- |
| Application | Ruby 3.2+ gem and executable; `HQ::RemoteServer` serves a local JSON API and HTML shell |
| Rendering | Server-rendered ERB shell, then client-side rendering from one vanilla JavaScript application |
| Package manager | Bundler; no JavaScript package or build step |
| Routing | Hash router in `app_helpers.js`/`app.js`; top-level Now, Agents, Settings plus project, agent, diff, attachment, archive, schedule, and hidden-setting subroutes |
| Styling | Plain CSS served at `/ui.css`; formerly one 5,930-line product stylesheet |
| Existing tokens | A small Dracula variable set in `app.css`, plus control-size variables appended in an audit-remediation section |
| Components | String-render functions in `app.js`; no framework component runtime |
| UI dependencies | No browser UI/headless dependency; native `dialog`, `details`, inputs, links, and buttons |
| Icons | Inline, Lucide-style SVG strings from the `ICONS` map; product logo PNGs |
| Typography | System sans stack; system monospace stack for code; no web fonts |
| Theme | Dark-only Dracula theme; `color-scheme: dark`; PWA theme/background `#282a36` |
| Internationalization | English strings embedded in templates/JS; no i18n library |
| RTL | No declared product support; new primitives use logical margins/padding where practical, but the application is not verified for RTL |
| Forms/validation | Native controls and custom submit handlers; no form or schema-validation library in the browser |
| Tables/charts | Semantic Markdown/diff tables; no data-grid or chart library |
| Overlays | Native `<dialog>` and `<details>` plus custom positioned panels; no centralized focus/portal layer |
| Tests | Ruby assertion files under `test/`; `bin/test` is CI-equivalent |
| Browser automation | `bin/remote-ui-smoke` installs temporary Playwright and drives local Chrome against isolated fixtures |
| Visual regression | Screenshot audit artifacts exist, but no committed pixel-diff gate |
| Accessibility tooling | Manual/browser assertions; no axe dependency |
| Formatting/linting | Ruby syntax checks and optional RuboCop; no JS/CSS linter |
| Deployment | Gem packaging includes `lib/hq/remote_ui/**/*`; no frontend compilation |
| Browser policy | Not formally stated before this work; current code depends on modern CSS (`:has`, `color-mix`, dynamic viewport units) and native dialog |

## Evidence and recurring values

`app.css` contained 177 occurrences of `8px`, 122 of `12px`, 114 of `1px`, 106 of `10px`, 68 of `6px`, and 67 of `16px`. It also contained repeated raw Dracula colors, 28 occurrences of `42px`, and scattered z-index values from 1 to 9,999. The raw values sometimes express real product constraints, but their frequency shows there was no ownership boundary between foundations and route composition.

The most repeated product patterns are:

- Button and button-like links with local size, border, and icon variations.
- `summary-card`, `detail-card`, `field-card`, `notice`, and several settings-only surfaces.
- `field-label`/`field-hint` pairs around native controls.
- `pill`, `chip`, and status-mark variations.
- Header, bottom navigation, agent dock, flyouts, menus, dialogs, and growls with independent layer values.
- Form actions repeated across agent, project, schedule, server, inquiry, loop, and response-style forms.
- Mobile queries primarily at 640px, with secondary 380px, 520px, and 560px rules; desktop layout changes at 760px, 900px, and 1100px.

Intentional distinctions preserved:

- Conversation messages and tool activity remain product patterns because their layout and behavior are agent-specific.
- Diff/code viewers keep dense typography and horizontal scrolling.
- Waiting, running, blocked, failed, and unread states retain separate product semantics.
- Mobile bottom navigation and desktop side navigation remain one responsive shell, not two component APIs.

## Route and workflow matrix

| Route/surface | User goal | Role/auth | Major UI | Important states | Responsive concern | Source |
| --- | --- | --- | --- | --- | --- | --- |
| `#now` | See work needing attention | Local operator; optional bearer token | attention summary, running/recent agents, schedules | empty, waiting, running, server token required | attention hierarchy, schedule action density | `renderNow` |
| `#agents` | Find and open an agent | Same | search, sort, groups, bulk actions | empty, filtered empty, bulk selection, unread | one-row mobile toolbar, long names | `renderAgents` |
| `#settings` | Configure Remote UI and agent defaults | Same | connection, servers, notifications, automation, configuration, preferences | unavailable, token required, ready/missing tools, editing response style | sticky section navigation, long forms | `renderSetup` |
| project detail/edit/diff | Inspect or edit workspace context | Same | metadata, agents, forms, diff viewer | loading, dirty/clean, missing diff | code overflow, two-column desktop | `renderProject*` |
| agent create/edit/clone | Configure managed agent | Same | field groups, workspace, model/effort, submit choices | validation, pending, read-only workspace | sticky mobile actions | `renderAgentForm` |
| agent conversation | Supervise and continue work | Same | messages, composer, inquiry, attachments, activity | loading, running, waiting, blocked, failed, success | fixed composer, split desktop reader | `renderAgent*` |
| summary/attachment/PR diff | Read an outcome or artifact | Same | reader toolbar, navigation, Markdown/code/image | loading, empty, fetch error, long content | focused view and split panes | `renderAgent*View` |
| archive | Confirm destructive change | Same | consequence, alternatives, action | blocked while running, pending | clear danger hierarchy | `renderAgentArchive` |
| schedule create/edit/message | Automate recurring work | Same | grouped fields, cron, message editor | validation, pending, read-only generated values | long form and sticky actions | `renderSchedule*` |
| hidden settings | Control project visibility | Same | three-state controls and legend | inherited, hidden, visible | compact but understandable controls | `renderHiddenSettings` |
| `/design-system` | Review foundations and components | Local developer | tokens, actions, fields, feedback | disabled, loading, read-only, error, empty | 390px and desktop reference | `design_system.html.erb` |

Authentication is a local operator model, not a role/permission matrix. No production or external data was used in the audit. Baselines used a temporary configuration/log root.

## Component inventory and priority

| Existing patterns | Occurrences | Main risk | Canonical target | Migration |
| --- | --- | --- | --- | --- |
| Generic `button`, `primary`, `danger`, `inline-icon-button`, `icon-button` | Nearly every route | divergent states and geometry | `ds-button`, `ds-icon-button` | Small adapter: keep behavior/data attributes, add classes and semantic `data-variant` |
| `field-card`, local labels/hints/controls | all create/edit/settings flows | inconsistent relationships and state styling | `ds-field`, `ds-input` | Direct replacement inside existing form patterns |
| `summary-card`, `detail-card`, settings-only panels | all index/detail pages | repeated surface values | `ds-surface` | Add canonical class, retain product layout class |
| `notice`, recovery/inquiry banners | settings and agent states | role/state inconsistencies | `ds-alert` | Direct replacement where message intent is known |
| `pill`, `chip`, status marks | lists, detail, settings | visual vocabulary overlaps semantics | `ds-badge` plus product status mark | Requires state-by-state product decision |
| bespoke flex/grid wrappers | all routes | repeated gap and collapse rules | `ds-stack`, `ds-cluster`, `ds-grid` | Adopt in new and touched markup |
| quick-agent native dialog | global creation | modal behavior must remain complete | documented product dialog pattern | Keep native dialog and browser-owned focus behavior |
| details menus/flyouts | navigation and readers | keyboard/focus behavior varies | shared overlay surface and interaction contract backed by native details | Primary menu families migrated; product flyouts remain local |
| conversation, diff, attachment, shell | product-specific | high behavior/regression risk | product patterns consuming tokens/components | Intentionally product-specific |

Priority score considered frequency, user impact, accessibility risk, maintenance cost, and migration feasibility. Foundations, actions, fields, surfaces, and alerts are the first release because they occur everywhere and can be adopted without changing business logic.

## Baseline evidence

Screenshots are under `artifacts/design-system/baseline/`. Captures record the route/state/viewport in the filename. They were produced from `http://127.0.0.1:7487` with temporary config and logs, no remote token, the current local commit/worktree, and Chrome headless.

Known audit limits:

- The empty fixture did not expose every agent state before implementation; the broader 64-state audit in `docs/REMOTE_UI_DESIGN_AUDIT_2026-07-11.md` remains the evidence source for those workflows.
- No project locale/RTL infrastructure exists, so RTL is documented as unsupported rather than implied.
- There is no automated screen-reader driver or established visual-diff threshold.

## Adoption update

The second implementation wave migrated agent create/edit/clone, project edit, schedule create/edit, and schedule-message edit markup to the shared field, input, surface, and button contracts. The third migrated structured inquiry controls and fixed multi-select group/error relationships. The fourth defines six status intents and migrates the highest-value agent, schedule, project, setup, and diff states. Existing product classes remain as layout/behavior adapters.
