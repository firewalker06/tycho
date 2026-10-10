# Card 295 Queue Work Audit

Audit date: 2026-10-10

Audit branch: `audit/card-295-queue-work`

Scope: queue acceptance, durable batches, dispatch, contract injection, Conversation visibility, completion, retry, stop/restart, archive, takeover, and delegated callbacks.

## Result

Current code inspection, focused tests, and controlled fixtures verify the audited current paths. In these paths, a queue entry moves from `prompt_queue` to a durable `queue_work` batch. Tycho writes one `Read queue` event before it starts the next run. A success result records a terminal disposition. A failed, blocked, or input-required result keeps the entry unresolved and visible. This verification does not prove that all retained historical batches followed these paths.

Six retained historical batches have an unexplained evidence gap. Five have `completed` or `incorporated` dispositions. One has a `needs_input` disposition. All six have a delivery count of zero, no `read_id`, and no matching queue-read memory event. The retained metadata proves that these batches became terminal. It does not prove delivery, contract injection, processing, operator removal, archive handling, or work loss. This audit does not assign a cause to these records.

One current gap is reproducible. A manual memory rebuild replaces `memory.jsonl` with data from `raw.log`. Queue-read events exist only in `memory.jsonl`. The rebuild can therefore remove the visible `Read queue` event while the durable batch still has its `read_id` and dispositions. Two retained archived batches have this state. This is a visibility loss, not a queue-work loss.

The TUI has a second presentation gap. It renders a queue-read event as an ordinary `You` message and can group it with adjacent user messages. The queue contract is present, but the TUI does not give it the clear `Read queue` label that the Remote UI gives it.

## Evidence and method

The audit used metadata only for retained agents. It did not copy private prompt or callback bodies into this report.

- Fizzy Card 295 description, image, and comments were inspected. The image shows a pending delegated reply in the queue panel.
- The actual default branch was clean. `git pull --ff-only origin main` reported that it was current before this branch was created.
- This was the only active agent in project `tycho`. No schedule targets project `tycho`.
- The retained scan covered 578 queue-work batches in archived `agent_manifest.json` files.
- Four focused test files passed: `test/prompt_queue_test.rb`, `test/remote_ui_prompt_queue_test.rb`, `test/delegation_test.rb`, and `test/archive_delegation_callbacks_test.rb`.
- The independent review reported a detached-completion fixture failure in `test/delegation_runner_test.rb`. A focused run in this correction workspace passed. The failure was not reproduced, so this audit does not assign an infrastructure cause.
- A temporary fixture created one `Read queue` event, rebuilt memory, and then found zero `Read queue` events. The batch still had its `read_id`.

Retained scan summary:

| Condition | Count | Interpretation |
| --- | ---: | --- |
| Archived queue-work batches | 578 | Full retained manifest sample at audit time |
| Delivered batches | 568 | Delivery count was greater than zero |
| Delivered batches with a `read_id` | 362 | Current disclosure model is present |
| Delivered batches without a `read_id` | 206 | Historical delivery model; all opened on or before 2026-09-27 09:32:36 UTC |
| Zero-delivery terminal batches with only removal-style outcomes | 4 | `declined_with_reason` or `superseded_with_reason` records directly support deliberate terminal removal; they do not claim delivery |
| Zero-delivery resolved batches with `completed` or `incorporated` outcomes | 5 | Unexplained historical evidence; no `read_id` or matching queue-read event proves delivery or processing |
| Zero-delivery blocked batches with a `needs_input` outcome | 1 | Unexplained historical evidence; no `read_id` or matching queue-read event proves that the prompt entered an agent context |
| Batches with a `read_id` but no matching memory event | 2 | Reproducible visibility-loss shape |

The six unexplained records keep source, acceptance, open, resolve, and disposition metadata. Some related run-summary or tool-summary records refer to batch or entry identifiers. Nearby run records also exist. These facts show retained activity near some batches, but they do not connect a queue entry to injected native context. The canonical delivery fields remain zero or absent, and no queue-read event exists. Therefore, the audit does not use the nearby records as delivery evidence.

The metadata-only check used these retained manifests:

- `~/.tycho/logs/agents/archive/20260926-153045-breaker-agent/agent_manifest.json`
- `~/.tycho/logs/agents/archive/20260928-101657-secondbrain-agent-20260926-044700-363830/agent_manifest.json`
- `~/.tycho/logs/agents/archive/20260928-131120-secondbrain-agent-20260925-060814-889508/agent_manifest.json`
- `~/.tycho/logs/agents/archive/20261006-161321-tycho-agent-20261006-021132-206133/agent_manifest.json`
- `~/.tycho/logs/agents/archive/20261008-164635-kids-education-agent-20261008-013844-185859/agent_manifest.json`
- `~/.tycho/logs/agents/archive/20261008-164729-kids-education-agent-20261008-082800-019367/agent_manifest.json`

These paths identify provenance without copying prompt, callback, disposition-reason, or memory-event bodies.

The latest retained delivered batch without a `read_id` is in:

`~/.tycho/logs/agents/archive/20260928-101657-secondbrain-agent-20260926-044700-363830/agent_manifest.json`

The two retained `read_id` mismatches are in:

- `~/.tycho/logs/agents/archive/20260930-055309-secondbrain-agent-20260927-025706-972713/agent_manifest.json`
- `~/.tycho/logs/agents/archive/20260930-055309-secondbrain-agent-20260927-025706-972713/secondbrain-20260927-025706-c7ea0180.memory.jsonl`

The retained files prove the mismatch. They do not prove which operation removed the events. The controlled fixture proves that the current rebuild operation can create the same mismatch.

Relevant merged changes explain the historical transition:

- `b9bfcdf` / PR 191 added a `Read queue` event to automatic dispatch.
- `1e45bb8` / PR 193 restored the expandable Remote UI disclosure.
- `47f5a5b` / PR 194 added automatic terminal dispositions after successful processing.
- `15aa724` / PR 199 hid active work from the pending list after the read event exists.
- `cf99718` / PR 203 exposed unresolved result states.
- `b99d45c` / PR 208 retained and reconciled failed claims.
- `e863a01` / PR 213 added safe process and remove controls.
- `87d8f4c` / PR 215 released later work after partial results.
- `a16d4b5` / PR 217 added durable queue-failure notifications.

## Lifecycle and visibility matrix

| Condition | Durable state | Conversation evidence | Audit result |
| --- | --- | --- | --- |
| Message arrives while an agent runs | Entry is appended under the agent-store lock with a stable ID, source, acceptance time, attachments, and ownership stamp. | The pending queue remains visible. A queue notice is advisory and does not consume work. | Verified by code and focused tests. |
| Due entries are claimed | Eligible entries move to one batch. The claim is saved before prompt preparation and process start. Later entries remain pending. | No entry is deleted. The batch becomes the source of truth. | Verified by code and race tests. |
| Automatic dispatch | Tycho marks the batch delivered and stores `read_id`, delivery count, and run provenance. | Tycho writes one idempotent `Read queue` event before process start. | Verified on current code. Historical records before the disclosure fix do not have this event. |
| Explicit `tycho queue` read | Pending entries move to one open batch under a file transaction. A failed write rolls back the state change. | The same idempotent `Read queue` event is written. | Verified by code and failure tests. |
| New user input arrives with pending queue work | The existing or new batch remains durable and the claim state is cleared. | The user message and one `Read queue` event enter the next native context. | Verified by code and tests. |
| Agent is running a claimed batch | Unresolved entries remain in the active batch. | Claimed entries are hidden from the pending list to prevent duplicate display. The `Read queue` block is the evidence. | Legitimate pending-list disappearance. |
| Success, no-action-needed, or partial result | Under the current completion policy, unresolved user entries become `completed`. Delegated reports become `incorporated`. Later entries can run. | The existing block projects the resolved state and dispositions. | Verified for current code and tests. The six unexplained historical batches are not proof of this path. |
| Failed, blocked, or input-required result | The batch stays open. No automatic success disposition is recorded. | Entries return to the queue view with an exact unprocessed reason. | Verified by code and tests. |
| Dispatch start failure | The prepared claim, batch, and error remain durable. | Retry reuses the same read event. It does not add a duplicate. | Verified by code and tests. |
| Stop or process exit | The store polls final state and dispatches eligible queued work once. Workspace, inquiry, schedule, and failure gates still apply. | Automatic dispatch writes the read event before the successor run. | Verified by code and tests. |
| Restart | Persisted claim and batch state are normalized and reconciled. The exclusive lock prevents a second claim. | Existing read metadata remains available if `memory.jsonl` is unchanged. | Verified by code and tests. |
| Operator removes work | Entries receive source-appropriate terminal dispositions with a reason. Stale snapshots do nothing. | Resolved batch metadata remains auditable. An unread entry does not get a false read event. | Verified by code and tests. |
| Agent archive | Undelivered work is copied to read-only history. Delivered work is marked `aborted_with_uncertainty`. Callback-only queues can be archived with history. | Archive history states whether delivery occurred. | Verified by code and tests. |
| Direct-user takeover | Ownership generation changes. Undelivered old-generation reports are suppressed in the delegation ledger. Delivered parent queue entries remain parent work. | A suppressed report was never delivered, so no parent queue-read event is expected. | Verified by delegation tests. |
| Parent reclaim | Generation changes again. A stale user-owned run cannot report after reclaim. A later parent-owned run can report once. | Eligible callbacks use the normal durable queue and read path. | Verified by delegation tests. |
| Manual memory rebuild | Queue-work manifests are not rebuilt or cleared. | Existing queue-read events can be overwritten because raw logs do not contain them. | **Reproducible gap.** |
| TUI rendering | Durable data is unchanged. | The event is labeled `You` and may join an adjacent user-message group. | **Presentation gap.** Remote UI has a separate `Read queue` disclosure. |

## Supporting code references

- Queue acceptance and durable batch creation: `lib/hq/domain/managed_agent.rb:504-631`
- Shared read-event writer and user-input inclusion: `lib/hq/domain/managed_agent.rb:638-685`
- Pending visibility while processing: `lib/hq/domain/managed_agent.rb:864-923`
- Automatic completion policy: `lib/hq/domain/managed_agent.rb:2189-2227`
- Claim persistence, dispatch, retry, and explicit read: `lib/hq/domain/agent_store.rb:447-635` and `lib/hq/domain/agent_store.rb:1127-1213`
- Memory rebuild replacement: `lib/hq/domain/agent_chat_log.rb:50-68`
- Remote conversation state overlay: `lib/hq/remote_server.rb:3059-3093`
- Remote UI `Read queue` disclosure: `lib/hq/remote_ui/assets/app.js:9900-10018`
- TUI user-message grouping: `lib/hq/ui/rendering/chat_rendering.rb:353-403`
- Contract documentation: `docs/AGENT_DELEGATION.md:52-64`

## Recommendations

1. Preserve durable memory-only events during rebuild. At minimum, keep queue-read events and their event IDs. Add a regression test that starts with a delivered batch and verifies that rebuild keeps one matching `Read queue` event.
2. Add an invariant check for `read_id`. If a batch has a `read_id`, Conversation must contain that event. Report a repairable diagnostic when it does not.
3. Add a repair path for retained mismatches. The batch keeps canonical entries and dispositions, so Tycho can reconstruct a safe queue-read event without reading private raw output.
4. Give queue-read events a separate `Read queue` block in the TUI. Do not group them with ordinary user messages.
5. Keep the current Remote UI rule: active claimed entries leave the pending list only after the durable read event exists.

This audit does not change runtime behavior. A separate approved implementation should address the rebuild and TUI presentation gaps.
