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

1. Before a native process starts, `ManagedAgent#start!` now makes sure that an active queue-work batch has durable delivery metadata and one matching `Read queue` event. This check runs after executable validation, so a missing harness does not create false delivery evidence.
2. `record_queue_read!` now restores a missing event when a batch keeps its `read_id`. It still uses the existing event ID, so repair is idempotent.
3. Memory rebuild now merges existing queue-read events into the rebuilt journal in timestamp order. The merge and replacement use one exclusive journal lock, so a concurrent queue read cannot fall between the read and write operations. A repeated rebuild keeps one event with the same event ID.

## Regression coverage

- A direct Start fixture begins with an active batch that has zero deliveries. The test verifies that the native prompt contains the contract, the batch gets delivery count 1 and a `read_id`, and Conversation gets one matching queue-read event.
- A rebuild fixture starts with one delivered batch and one queue-read event. Two rebuilds keep exactly one event with the original event ID and batch ID.

## Evidence limits

The retained logs prove the source and processing result of the six records. They do not prove that every historical conversation rebuild used the same operator action. The code fix therefore protects the proved direct-start and rebuild paths. It does not rewrite archived records.
