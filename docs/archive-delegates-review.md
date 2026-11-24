# Archive delegates review handoff

## Scope

This change adds a selection step to the existing Remote UI archive page for active direct delegates. All delegates are selected by default. The existing single-agent archive route handles an empty selection. The existing server-local bulk archive behavior handles selected delegates.

## Review blockers addressed

- Selected delegates now use the parent agent's server route, headers, raw keys, and response scope.
- Each checkbox has a stable state key based on its server-scoped client key. Exclusions stay in place when the catalog order or membership changes.
- The archive action reads fresh detail for the parent and selected delegates. It asks for explicit confirmation when any selected agent has a run, queued work, or an open inquiry. It reads status again after confirmation and asks again when the work state changes.

## Verification

- Synthetic Chrome fixture: default selection, Cancel, deselected delegate, parent-only archive, selected parent-plus-delegate archive, reorder/removal preservation, peer route and key scope, running-work confirmation, and a run-status change while confirmation was open passed.
- `bin/test` passed.
- Exact-head `signoff/tycho-bin-test` status is green.
- Screenshot: `docs/screenshots/archive-delegates-dialog.png`.

## Independent review status

The fixes are ready for independent review on the draft pull request. Do not merge until review is complete.
