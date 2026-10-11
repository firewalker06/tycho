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

1. `ManagedAgent#start!` records delivery only after process creation succeeds. A preflight or spawn failure creates no delivery count, read ID, or Conversation evidence.
2. Each batch has one stable read identity. The agent store commits the batch update and journal event in one rollback-capable file transaction. A transient save failure restores both files and in-memory batch state before one immediate retry.
3. Event repair preserves the existing read ID and delivery count. A matching event must use that ID, have `queue_read: true`, and name the same batch. A conflicting event with the same ID is replaced by the canonical queue-read event.
4. Automatic queue dispatch and Direct Start use the same post-spawn accounting path. The queue contract is built before launch, but durable read evidence is not created for an attempted launch.
5. Memory rebuild merges existing queue-read events into the rebuilt journal in timestamp order. The merge, replacement, and queue-read upsert use the journal's exclusive lock. A concurrent append cannot be lost, and a repeated rebuild keeps one event with the same event ID.

## Regression coverage

- A capture harness records the argument that the native executable receives. The test verifies that this argument contains the queue contract, then checks one matching batch and journal identity.
- A deterministic post-preflight spawn failure leaves no delivery evidence. A successful retry records one delivery with the stable batch-derived identity.
- A deterministic first save failure rolls back and retries the transaction. The final batch and journal contain one matching identity and one delivery.
- A missing-event repair keeps the existing read ID and delivery count.
- Same-ID assistant events, non-read events, and events for another batch do not satisfy the semantic match.
- A barrier-controlled rebuild and append race keeps one queue-read event. Two sequential rebuilds also keep the original event ID and batch ID.

## Evidence limits

The retained logs prove the source and processing result of the six records. They do not prove that every historical conversation rebuild used the same operator action. The code fix therefore protects the proved direct-start and rebuild paths. It does not rewrite archived records.
