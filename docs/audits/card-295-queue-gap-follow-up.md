# Card 295 Queue Gap Follow-up

Investigation date: 2026-10-11

Fix branch: `fix/card-295-preserve-queue-reads`

Dependency: this follow-up uses the lifecycle audit in PR 231. It does not change PR 231.

## Result

The retained evidence explains all six terminal batches that the first audit could not classify.

- One batch is not production work. It came from the sleep circuit-breaker recovery test. A test child process used the real Tycho log root before commit `5998af1` isolated the child environment. The retained agent name, run ID, entry ID, and timestamps match that fixture.
- The other five batches entered native agent context. Each raw run contains the queue-work contract and its batch ID. Each run also contains a queue-work disposition command that reached a successful result. The terminal dispositions agree with those commands. This evidence proves delivery and processing for these five records. It does not depend on prompt, callback, memory-event, or disposition-reason bodies.

The five production records expose a current accounting path. `ManagedAgent#prompt_for_execution` adds an active queue-work contract to every run. A direct Start operation called `start!` without first calling `record_queue_read!`. The native agent received the contract, but the batch kept `delivery_count: 0`, did not get a `read_id`, and did not get a Conversation event. The agent could then record a terminal disposition. This sequence creates the exact retained shape.

The memory rebuild gap has a separate cause. `AgentChatLog#rebuild_memory_from_raw_log!` replaced the full event journal with events parsed from `raw.log`. A queue-read event exists only in the event journal, so the replacement removed it.

## Fix

1. `ManagedAgent#start!` uses a two-phase native launch. The outer Ruby runner waits behind a run-scoped release gate. Tycho first commits the queue batch, journal event, runner PID, and staged-launch metadata. It then releases the runner and requires an acknowledgement written only after the actual harness `Process.spawn` succeeds.
2. A native spawn failure rolls back the staged queue evidence and settles one durable failed run. An accounting failure never opens the release gate. Tycho stops and reaps the waiting runner, settles the failed run, and then permits a safe retry.
3. Each batch has one stable read identity. The agent store commits the batch update and journal event in one rollback-capable transaction. The transaction holds the journal lock while it changes the event set and saves the batch. Rollback removes only the staged identity, so it cannot overwrite a concurrent rebuild.
4. Event repair preserves the existing read ID and delivery count. A matching event must use that ID, have `queue_read: true`, and name the same batch. Repair removes every duplicate record with the canonical ID and writes one canonical queue-read event.
5. Automatic queue dispatch and Direct Start use the same gated native-launch protocol. Explicit queue-claim reads keep their existing behavior for archive and read-only workflows.
6. Memory rebuild merges existing queue-read events into the rebuilt journal in timestamp order. Rebuild, queue-read update, and rollback use the journal's exclusive lock.
7. Staged-launch metadata contains the durable queue, claim, and journal rollback snapshot. After a Tycho restart, `AgentStore` keeps the gate closed until it owns both acknowledgement and failure callbacks. It saves a native acknowledgement before polling or completing the claim. On failure, it settles the run and restores the batch, claim, and journal before retry is available.
8. The internal delegated-acknowledgement flag is set only for the structured correction wrapper. Every non-correction launch explicitly removes an inherited flag before it starts the stream recorder.

## Regression coverage

- Capture harnesses prove that Direct Start and automatic dispatch receive the queue contract only with matching durable batch and journal evidence.
- A real executable with a missing shebang interpreter passes preflight but fails native spawn. The test verifies rollback, failed-run settlement, and safe retry.
- Persistent batch-save and journal-append failures keep the native gate closed. The tests verify no capture, stopped and reaped runners, zero delivery evidence, durable failed runs, and successful later retry.
- A missing-event repair keeps the existing read ID and delivery count.
- Same-ID assistant events, non-read events, events for another batch, and duplicate canonical IDs do not satisfy the semantic match.
- Barrier-controlled tests cover rebuild with append and rebuild with failed-launch rollback. The journal lock preserves the rebuild result and one canonical queue-read event.
- Production-path restart tests stop the first Tycho process after durable staging and before acknowledgement. Failed native spawn restores zero delivery evidence and one retryable claim; one retry records one delivery. Successful native acknowledgement is saved once without duplicate retry.
- A non-correction native launch runs with an inherited delegated-acknowledgement flag in the parent environment. The child receives the flag as unset and writes its normal acknowledgement.

## Evidence limits

The retained logs prove the source and processing result of the six records. They do not prove that every historical conversation rebuild used the same operator action. The code fix therefore protects the proved direct-start and rebuild paths. It does not rewrite archived records.
