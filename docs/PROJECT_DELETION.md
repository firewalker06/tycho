# Project deletion

In the Remote UI, open a project menu and select **Edit project**. The **Delete
project** controls sit in a separate **Danger zone**, with a large gap after Save.
Visible deletion explanations use at most three sentences, including confirmation.
Type the project key, then select
**Delete project**. A second dialog has **Cancel** as its initial focus.

The default stops all project agents, archives them with their pending work and
logs, archives project logs, and removes the project from active configuration.
The project directory and its files stay on disk. Archived project configuration
remains available for audit. This uses the same lifecycle and rollback behavior
as the existing project archive command.

The unchecked **Permanently remove agents and identified logs** option removes the
new agent archives, previous agent archives with the same project identity, and
project-log archives with a matching identity record. This cannot be undone.
It does not remove the project directory. Old project-log archives without a
project identity record stay on disk because their owner cannot be proved.
Global metrics, global application logs, deletion receipts, shared state backups,
and unrelated project data remain. This is project data removal, not secure
media erasure. New project archives include `project_manifest.json` so later
removal can identify them without using directory names.

Remove all schedules that reference the project before deletion. This includes
archived schedules. A reference prevents acceptance and the error lists the
schedule keys. This keeps the schedule configuration valid after project removal.

## Progress and recovery

The authenticated API accepts a POST to the project's `deletion` child resource.
The body contains `confirmation` (the exact project key), boolean `remove_data`,
and a unique `request_id`. A successful response is HTTP 202 and includes the
persisted job. GET on the same resource returns `deletion` or `null`.
The UI polls this resource while work continues. It shows completion or a failure
with **Retry deletion**. The user can leave the page and reopen project settings
or reload the original page to read the same receipt, even after the project is
removed. The UI saves its request ID across reloads in the tab's session storage.

Jobs are stored below the logs root in `project_deletions`. Atomic writes save
`queued`, `running`, `completed`, or `failed`, and the archive/removal phase.
An OS lock prevents duplicate workers for the same project. Admission also checks
agent, configuration, and schedule locks without waiting: busy state returns an
error for an explicit retry. New agent creation, dispatch, project changes, and
schedule references are blocked while the job is pending or failed.
A completed receipt replays the same request. Deleting a project that was added
again requires a new request ID.

Workers run in the server process, outside request handling. Server shutdown can
interrupt them. A job with no live worker becomes failed when read; it never
starts itself after a restart. Retry keeps the same removal option and request
ID. If the archive phase is recorded as complete, retry runs only removal and final
configuration removal. Project configuration stays active until data work succeeds,
so a failed job stays reachable in the project settings. A crash before the phase
receipt can retry archive on the remaining active agents and logs. Matching
project-log manifests preserve ownership even if the earlier attempt moved logs.
A crash after final configuration removal can finish from the saved archive phase.
Filesystem/archive writes still use the existing recovery and rollback mechanisms;
deleting the workspace directory is never a recovery action.

Removal accepts only direct child directories of the configured log archive
roots and refuses symlink directories or manifests. A removal failure preserves
the workspace, keeps the durable failure receipt, and can leave some project
archives already removed. Retry is idempotent for missing directories. Error
responses exclude prompts, raw process commands, and exception path details.

## Verification

- `bundle exec ruby -r ./test/support/push_safety.rb test/project_deletion_test.rb`
  checks archive/removal, confirmation, replay, key reuse, interruption, explicit
  retry, symlink safety, schedule references, and HTTP acceptance/status.
- `bin/remote-ui-project-deletion-smoke` starts an isolated server and runs Chrome
  through Playwright. It checks desktop/mobile confirmation, Cancel, key errors,
  delayed replies, archive, reload, permanent removal, failure, and retry.
  Set `TYCHO_PLAYWRIGHT_PATH` to an installed Playwright package to skip the
  temporary npm install. Set `CHROME_PATH` to select Chrome. Set
  `TYCHO_REMOTE_UI_CAPTURE_DIR` to a directory outside the checkout for evidence.
- `bin/test` remains the required local CI suite. Browser smoke is separate.
