# Archive delegates review handoff

## Scope

This change adds a selection step to the existing Remote UI archive page for active direct delegates. All delegates are selected by default. The existing single-agent archive route handles an empty selection. The existing server-local bulk archive behavior handles selected delegates.

## Review blockers addressed

- Selected delegates now use the parent agent's server route, headers, raw keys, and response scope.
- Each checkbox has a stable state key based on its server-scoped client key. The dialog stores exclusions for its full lifetime, including while a delegate is absent from the catalog.
- One general confirmation authorizes the complete archive workflow. The server stops running agents, records pending work as aborted in archive history, and archives all selected agents in one locked operation.
- The confirmation is bound to a fresh work token for the parent and every selected delegate. The archive store checks all tokens under its exclusive lock before it changes any agent. A mismatch returns a conflict; the UI restores the agents and asks the same general confirmation before retry.
- A parent and its selected delegates are archived in one locked operation. The parent-only operation uses the same server guard. Peer actions use the owning server route and raw agent keys.
- Each delegate uses the standard agent row with a checkbox at the left. Exclusions remain in effect while the dialog is open, even if a delegate disappears and returns.

## Verification

- Synthetic Chrome fixture: default selection, Cancel, deselection, parent-only archive, selected parent-plus-delegate archive, exclusion persistence across disappearance and return, reset on a new dialog, desktop and mobile layout, peer route and key scope, server conflict, renewed confirmation, and guarded retry passed.
- Server regressions: a new synthetic run between detail read and locked archive returns a conflict and leaves all selected agents active; confirmed archive stops a synthetic process, archives every selected agent, and records queued work as aborted.
- `bin/test` and exact-head `signoff/tycho-bin-test` are run for the final pushed head.
- Latest desktop and mobile synthetic screenshots are attached to the pull request. They are not stored in this repository.

## Independent review status

The fixes are ready for independent review on the draft pull request. Do not merge until review is complete.
