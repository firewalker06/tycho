# Archive delegates review handoff

## Scope

This change adds a selection step to the existing Remote UI archive page for active direct delegates. It uses the existing single-agent archive route when the selection is empty and the existing bulk archive route when one or more delegates are selected.

## Review points

- Delegate choices come from the active agent catalog and must have the parent relationship key and server key of the parent being archived.
- Every listed delegate is selected on first render.
- Cancel and Clone keep their existing actions.
- The batch result restores agents that the server did not confirm as archived.
- The existing running and queued work confirmation remains in place.

## Verification

- Synthetic Chrome fixture: default selection, Cancel, unchecked delegate, parent-only archive, all-selected parent-plus-delegate archive, and unrelated-agent preservation passed.
- `bin/test` passed.
- Screenshot: `docs/screenshots/archive-delegates-dialog.png`.

## Independent review status

This is a review handoff for the draft pull request. An independent reviewer has not reviewed the change yet. The PR is a draft so a formal PR review has not been started.
