# Archive delegates review handoff

## Scope

This change adds a selection step to the existing Remote UI archive page for active direct delegates. All delegates are selected by default. The existing single-agent archive route handles an empty selection. The existing server-local bulk archive behavior handles selected delegates.

## Review blockers addressed

- Selected delegates now use the parent agent's server route, headers, raw keys, and response scope.
- Each checkbox has a stable state key based on its server-scoped client key. The dialog stores exclusions for its full lifetime, including while a delegate is absent from the catalog.
- The archive action reads fresh detail for the parent and selected delegates. It asks for explicit confirmation when any selected agent has a run, queued work, or an open inquiry.
- Each detail response includes a digest of its active run and pending work. The archive store checks this digest under its exclusive lock before it archives any selected agent. A mismatch returns a conflict and asks the user to review and confirm the current work again.
- A parent and its selected delegates are archived in one locked operation. The parent-only operation uses the same server guard. Peer actions use the owning server route and raw agent keys.

## Verification

- Synthetic Chrome fixture: default selection, Cancel, deselected delegate, parent-only archive, selected parent-plus-delegate archive, exclusion persistence across disappearance and return, reset on a new dialog, peer route and key scope, held-read run change, server conflict, renewed confirmation, and guarded retry passed.
- Server regression: a new synthetic run between detail read and locked archive returns a conflict and leaves all selected agents active.
- `bin/test` and exact-head `signoff/tycho-bin-test` are run for the final pushed head.
- The latest synthetic screenshot is attached to the pull request. It is not stored in this repository.

## Independent review status

The fixes are ready for independent review on the draft pull request. Do not merge until review is complete.
