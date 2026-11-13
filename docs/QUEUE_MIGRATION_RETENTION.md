# Queue migration receipt retention

`bin/tycho queue-work cleanup-migrations` prints a local JSON dry-run report.
`--apply` explicitly applies the current plan. There is no automatic cleanup,
remote endpoint, schedule, or queue deletion. Do not use apply without operator
authorization for the target store.

## Policy

Only entries in the top-level `migrations` map are eligible. The receipt must
exactly match the original empty migration shape: SHA-256 of the two bytes
`{}`, empty `entry_ids` and `batch_ids`, and null `claim_id`. Extra fields,
nonempty receipts, and unknown formats stay.

The current `agents[key]` queue must exist and contain only a valid
`generation`. A missing queue or legacy empty placeholder is not proof of an
empty queue. Any other field keeps the receipt, even an empty array or object.
This includes pending prompts, claims, dispatch failures, work batches,
completion evidence, staged delivery, rollback data, and unknown future data.
A previously nonempty migration receipt stays even after its queue becomes empty.

Keep 100 eligible receipts. Legacy receipts have no reliable date. Sort keys
lexically and keep the last 100; this is a stable selection rule, not an age
or recency claim. Remove at most 1,000 other eligible receipts in one apply.
The report lists `candidates`, `retained` reasons, `removed`, and these limits.
Repeat an explicit apply to reduce a larger eligible backlog. The bound applies
to eligible empty audit receipts after enough applies. Protected receipts and
queue records have no retention limit in this mechanism.

## Invariants and recovery

Cleanup never removes or changes an `agents` queue record, queue generation,
agent file, archive manifest, creation request receipt, or completion proof.
Archive queue references continue to resolve. A referenced missing queue still
fails loading; cleanup does not repair it. Keeping the queue record also stops
normal writes from creating another first-migration receipt for the same key.

Planning and apply use the agent lifecycle lock, as do queue writers.
Apply recalculates its plan under that lock; it does not accept a stale dry-run
plan. All cooperating writers serialize. Direct edits outside this lock are
unsupported. The scan reads the full store; the deletion cap does not bound
scan time or store memory.

Apply writes a version 2 queue-only intent to the existing queue transaction
journal before it installs the queue file. Recovery installs that intent
idempotently before a later mutation. Read-only agent snapshots can use the
intent while it is pending. No agent or archive file needs a rewrite.
A write failure before durable intent leaves the old state; a failure after
intent can mean apply will finish on recovery even if the command reported an
error. Retry by inspecting a new report. Lifecycle lock entry can recover an
earlier transaction even for a dry run; dry-run planning itself writes no data.

This change was verified only with isolated synthetic fixtures. It does not
authorize cleanup of operator history or repair of missing records.
