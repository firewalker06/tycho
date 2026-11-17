# Panel slots and mobile prompt controls

Panel capacity follows viewport CSS width, using the existing 900-pixel mobile
and 1440-pixel wide-screen boundaries:

| Viewport width | Reserved slots |
| --- | --- |
| Below 900 pixels | 1 |
| 900–1439 pixels | 2 |
| At least 1440 pixels | 3 |

Let W be the agent workspace grid content width, after the global navigation
track and page padding. W excludes the workspace's own padding and borders.
For N reserved slots, each panel has width `(W - 12 * (N - 1)) / N` pixels.
The calculation reserves every 12-pixel column gap, including gaps next to empty
slots. The full available content width is used without a centered width cap.
Panels start at the left. Their widths do not change when another panel opens.
The existing global sidebar breakpoint remains 1100 pixels. Other pages retain
their existing layouts after leaving an agent workspace. Browser checks cover
Agents, Projects, Schedules, Attachments and Settings at 390, 900, 1440 and 1920
pixels, including the intentionally scrollable Settings tabs.

For example, a 1800-pixel grid has three 592-pixel slots and two 12-pixel gaps.
One panel occupies the first slot; two leave the last slot vacant. At medium
widths, Conversation and the newest peer are visible. Other requested peers stay
selected in the controls. Small screens show the selected single view. Resizing
preserves that selection. Detail-only mode hides Conversation without widening
the remaining panel.

A file from Focus or Summary keeps its source as the first requested peer and
replaces the second peer with the attachment. Thus the source owns logical panel
two and the file owns panel three. A medium or small screen selects the file
without squeezing a third column. Ordinary external links keep their navigation.
Focus attachment grids follow their own container content width: one column
below 640 pixels, two from 640, three from 960. Sidebar changes can cross these
boundaries at the same viewport width; opening a peer cannot.

## Mobile prompt diagnosis

The previous inline dock was capped at 60dvh. The editor, toolbar, tabs and
prompt actions could exceed that cap. Its inline layout also used innerHeight
while only the fullscreen editor tracked visualViewport. In Chrome at a real
844 × 390 browser viewport, Submit ended at 431 pixels, below the viewport.
A modeled visible bottom of 784 pixels on a phone left Submit at 838 pixels.

The workspace now follows the visual viewport bottom. The composer measures the
available region below the actual header and budgets its editor after the
actual tool and action heights. Long text scrolls inside the bounded textarea.
The action row stays sticky at the dock bottom; the dock can scroll when the
remaining region is very short. Compact editor controls sit side by side, with
scroll clearance so they remain reachable above the sticky action row. Existing
safe-area variables are included. Drafts survive all layout changes.

## Browser checks

Run each profile with `TYCHO_REMOTE_UI_SIDE_CONVERSATIONS_ONLY=1` and
`bin/remote-ui-smoke` from the repository root:

| Profile flag | Optional WebKit flag | Checks |
| --- | --- | --- |
| `TYCHO_REMOTE_UI_FIXED_SLOTS_ONLY=1` | `TYCHO_REMOTE_UI_FIXED_SLOTS_WEBKIT=1` | 1/2/3 panels around both breakpoints, sidebar widths, source replacement, reading position, drafts and overflow |
| `TYCHO_REMOTE_UI_MOBILE_PROMPT_ONLY=1` | `TYCHO_REMOTE_UI_MOBILE_PROMPT_WEBKIT=1` | Long focused drafts, viewport resizing, visible prompt actions, editor reachability, running/idle Stop and retained drafts |
| `TYCHO_REMOTE_UI_PANEL_PLACEMENT_ONLY=1` | `TYCHO_REMOTE_UI_PANEL_PLACEMENT_WEBKIT=1` | Section/bulk collapse, polling and both attachment sources across peer orders |
| `TYCHO_REMOTE_UI_FOCUS_ATTACHMENTS_ONLY=1` | `TYCHO_REMOTE_UI_FOCUS_ATTACHMENTS_WEBKIT=1` | Standard icons/actions, real download bytes and names, external navigation, unavailable files and 3/2/1 container grids |

Set `TYCHO_REMOTE_UI_CAPTURE_DIR` outside the checkout for screenshots and JSON
geometry. Fixtures use isolated config and logs, including a held synthetic
harness for running/idle transitions. Chrome and WebKit perform real viewport
resizes and DOM hit tests. The prompt profile also models visualViewport offset
and height changes and injects CSS safe insets. It does not open an OS keyboard
or test physical iOS browser chrome and its animation.

PR 372 remains separate. Its attachment polling reconciliation overlaps this
renderer and needs explicit integration; these changes do not merge it.
