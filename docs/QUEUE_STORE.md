# Central queue storage

`HOME/.tycho/logs/queues.json` is the authoritative queue store. It contains <!-- local-path-ok -->
one record per target agent key. Each record holds pending entries, the active
claim, dispatch failure state, QueueWork batches and dispositions, and staged
delivery or rollback data indexed by native run ID. Active agent records and
new archive manifests contain only `queue_ref` and `queue_generation` for this
state. Domain objects and API responses project queue data in memory. They do
not create another durable queue copy.

## Migration and deployment

The first lifecycle load migrates legacy active records under the existing
agent-store lock, before polling or dispatch. It copies queue fields before
normalization. Existing entry IDs, order, timestamps, authority, claims,
attachments, batches, and completion evidence remain intact. The central
`migrations` map records the initial queue checksum and entry, claim, and batch
IDs. It is evidence, not an execution source. Legacy archived manifests remain
readable as historical evidence; new or updated manifests use central references.
Historical recovery snapshots remain backups, not dispatch inputs.

Earlier version 1 files can contain empty per-agent placeholders with no
generation while agent records still contain their authoritative inline queues.
Readers treat only these empty placeholders as absent, without writing or
migrating data. A later lifecycle migration records the inline queue and its
initial identifiers normally. Non-empty records without a generation and central
references to missing or empty records still fail closed. An empty placeholder
does not prove that its agent has no pending work.

Deploy all queue writers together. Stop the TUI, server, scheduler and other
writers before the version change. Do not run an older writer against a migrated
store. Preserve the complete logs directory before the first lifecycle load.
This includes the agent store, queue store, journal, delegation ledger, recovery
ledger, archive manifests, and per-agent native-start and memory evidence.
Do not restore one file by itself or delete `queues.json` to force a migration.
Development and acceptance checks must use temporary roots; they must not migrate
operator data.

## Writes and restart recovery

All normal queue reads, claims, and mutations use the agent lifecycle lock.
The queue store writes and syncs a transaction intent before it publishes the
queue file and its target agent file. It removes and syncs the journal only
after both writes finish. The next lifecycle lock holder completes an interrupted
intent before it can claim work. Existing lifecycle transactions include both
queue files in rollback, including native-launch failure paths.

Read-only snapshots can project a pending intent without dispatch or recovery.
They retry if the queue signature changes during a read. Cache signatures include
the queue file and transaction journal. Agent and queue generations must match;
missing, corrupt, or mismatched queue data fails closed. Queue backups are not
silently restored because they can contain an already accepted claim. A stale
public agent save must reload before it can replace a newer queue generation.

## Automatic processing

The existing server timer and scheduler daemon continue to poll the queue when
agents are idle. Keep one of these services running for automatic processing:

```sh
bundle exec bin/tycho serve
bundle exec bin/tycho schedule daemon
```

Dispatcher availability does not make every entry eligible. Schedule state,
workspace contention, inquiry state, delayed eligibility, ownership generations,
native-start acknowledgement, prior failure, and recovery gates still apply.
Neither storage migration nor the server timer resumes a stopped schedule.
CLI, Remote API, UI controls, and native runner completion use the same store
and the same dispatcher rules. No provider or live service is needed for tests.

## Verification

`test/queue_store_test.rb` checks exact migration round trips, target references,
retained archive evidence, crash recovery after each file boundary, concurrent
process writers, rollback, cache invalidation, stale saves, and corrupt or stale
store rejection. `test/prompt_queue_test.rb` retains the existing delayed-entry,
claim, delegated-report, retry, native-start, and dispatch-gate tests.
`test/delegation_runner_test.rb` checks real detached fixture runner completion.
Run the full `bin/test` suite and follow [Local CI](LOCAL_CI.md) for exact-commit
signoff.
