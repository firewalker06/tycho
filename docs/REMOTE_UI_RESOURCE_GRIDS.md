# Agent and schedule block grids

Agent cards on Now, flat/grouped Agents lists, and schedule blocks use their own
responsive page grid. This is separate from Conversation panel slots and Focus
attachment container queries.

| Viewport CSS width | Columns |
| --- | --- |
| Below 900 pixels | 1 |
| 900 through 1439 pixels | 2 |
| At least 1440 pixels | 3 |

These reuse the existing responsive boundaries. Each grid fills the available
page content width after navigation and page/group padding. Columns share that
width equally, after reserving 12 pixels for each column gap. The page shell is
left aligned and has no centered width cap on these pages. A sparse final row
leaves unused columns on the right.

Now section labels remain outside each card grid. Agent project headings span
all columns. Delegated families remain together as one cell, with the parent
before its descendants and the existing depth cues. Sorting, filtering, search,
status and unread indicators keep their behavior. Grid order follows DOM order
from left to right, then top to bottom.

Long labels wrap inside their card. Schedule actions use a separate row so the
schedule name and status have room. Pause/Resume, menus, edit and agent-opening
controls retain their existing semantics. Empty/loading states span the grid.
Projects, Settings and other pages keep their own layouts.

## Verification

```sh
TYCHO_REMOTE_UI_RESOURCE_GRID_ONLY=1 bin/remote-ui-smoke
```

Add `TYCHO_REMOTE_UI_RESOURCE_GRID_WEBKIT=1` for installed Playwright WebKit.
Set `TYCHO_REMOTE_UI_CAPTURE_DIR` outside the checkout for PNG and JSON evidence.

The isolated fixture creates long Unicode and unbroken agent/schedule names,
two project groups, a delegated family and unread agent cards. Browser checks
cover Now, flat/grouped Agents and Schedules at 320, 390, 899, 900, 901, 1099,
1100, 1101, 1439, 1440, 1441 and 1920 pixels in Dark and Light. Expanded and
absent sidebar tracks stress the available width at the same viewport size.
The checks assert column counts, equal widths, left alignment, full-width group
headings, stable ordering through polling, no horizontal overflow, and actual
fixture Pause/Resume, keyboard Edit, search and agent navigation actions. They
do not start a schedule or contact a provider.
