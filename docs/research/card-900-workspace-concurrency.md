# Card 900: concurrent runtime admission

[Card 900](https://fizzy.startkit.tech/1/cards/900) permits distinct managed
agents to run in the same workspace. Repository task ownership and cleanup
rules still apply. This change does not permit uncontrolled concurrent edits.

## Reproduction

Before the implementation, the new
`ManualScheduleQueueTest.assert_shared_workspace_allows_manual_delivery`
failed with: `paused: another agent in the workspace blocked manual delivery`.
The fixture used a real running process for one agent and queued work for a
second agent in the same temporary workspace. No live agent was used.

The checkout was clean on `main`. Fetch and fast-forward-only pull confirmed
that it matched the remote default branch. No other Tycho task agent was active;
the current implementation agent was the only active agent for this project.
Work started on a fresh branch. No prior task work required cleanup.

## Admission audit

| Path | Finding and change |
| --- | --- |
| Manual start, CLI and API | `AgentStore.start_agent!` and `start_target!` already check the target agent under the store lock. No workspace exclusion was present. |
| Immediate send, CLI and API | `accept_or_abort_prompt!` uses the same locked target start. A running target retains the prompt in its queue. |
| Automatic queue, retry, selected processing | Removed the other-agent workspace scan from `dispatch_prompt_queue!`. Persisted claims, delivery accounting, native acknowledgement, and failure recovery remain. |
| Manual queue under paused or stopped schedules | Removed the workspace contention blocker. Target running, inquiry, unavailable directory, and recovery checks remain. Schedule state is unchanged. |
| Delegated callback | Removed sibling workspace checks for both queued and legacy parent implementations. Parent-running, inquiry, ownership generation, report deduplication, and archived-parent rules remain. |
| Saved callback state | Continue to read `workspace_busy` as a legacy eligible state. Do not generate it for new waits. |
| Scheduled messages and fresh scheduled agents | Both launch through the locked per-agent start. No workspace exclusion was present. Paused and stopped schedule policy is unchanged. |
| API queue state and UI | Removed workspace waiting state and its display label. A target can be ready while another agent runs in its workspace. Unavailable directories still report a blocker. |
| Data integrity | Store `flock`, queue journal and claims, file transactions, and per-agent process checks are unchanged. |
| Repository workflow | No cleanup, task ownership, branch allocation, or merge rule changed. |

## Verification

`test/workspace_concurrency_test.rb` starts real native synthetic harnesses in
one temporary workspace. A ready marker proves that each process received its
input while both processes are still running. It covers automatic queue,
manual start, immediate send, and scheduled-message paths.

Four independent processes race manual starts, then four independent processes
race automatic queue dispatch. Both cases must produce one native harness
start and one new agent run. Queue dispatch must retain one claimed entry and
one durable read receipt.

Manual schedule service tests cover paused and stopped delivery beside a
running sibling. Existing tests retain authority, inquiry, delayed eligibility,
claims, failure recovery, and schedule policy coverage. Delegation tests cover
same-workspace parent progress, callback deduplication, and recovery of a saved
`workspace_busy` report.

The existing Chrome manual-schedule smoke test now creates a running sibling
for every case. It proves selected queue delivery completes before that sibling
stops. It also checks selection across polling, inquiry blockers, inactive
schedule state, and desktop/mobile Dark/Light layout.

Commands:

```bash
bundle exec ruby -r ./test/support/push_safety.rb test/workspace_concurrency_test.rb
bundle exec ruby -r ./test/support/push_safety.rb test/remote_server_test.rb
TYCHO_REMOTE_UI_MANUAL_SCHEDULE_QUEUE_ONLY=1 TYCHO_REMOTE_UI_CAPTURE_DIR=path/to/temp/evidence bin/remote-ui-smoke
TYCHO_REMOTE_UI_QUEUE_RESULT_ONLY=1 bin/remote-ui-smoke
bin/test
```

The full suite and required signoff must be recorded against the published PR
head. Browser evidence uses temporary config, log, and workspace roots. No
production restart, deployment, or merge is part of this work.
