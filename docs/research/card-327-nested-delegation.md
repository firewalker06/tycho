# Card 327: nested delegation investigation

[Card 327](https://fizzy.startkit.tech/1/cards/327) reports that a child report causes Takeover on an intermediate delegated agent. The root then receives no completion report.

## Result

The isolated A → B → C scenario passes on main `8d813dc`. This investigation did not reproduce the reported fault. There is no established root cause and no production code fix in this change. Keep the card open until the affected version, agent keys, or exact trigger is known.

## Repeatable check

Run from the repository root:

```sh
bundle exec ruby -r ./test/support/push_safety.rb test/delegation_runner_test.rb
```

The test uses temporary config and log roots, a fake Codex executable, and actual CLI commands and detached runners. It does not dispatch production agents. The push safety helper blocks real push transport.

The added scenario creates A → B → C with explicit recorded parent declarations. C completes, its callback starts B, and B's completion starts A. It checks both edges for parent ownership and generation 1, one resumed report per edge, B's upstream run stamp, agent message authorship, and the protected `delegation_callback` queue source at both hops.

The test then sends a direct user prompt to B. This causes user ownership at generation 2. Another C report starts B with that user stamp and produces no new report to A. Only a later prompt from recorded parent A restores parent ownership at generation 3. It does not replay the user-owned runs.

This scenario starts B from an idle state. It does not prove the absence of every timing fault involving a running B or simultaneous input.

## Hypotheses and source checks

1. Callback acceptance changes B's edge owner. Prediction: the A → B relation becomes user-owned after C completes. The isolated test rejects this prediction for the tested path. `DelegationCoordinator#deliver_reports!` enqueues the callback directly with B's current upstream ownership stamp. It does not pass the report through ordinary user prompt acceptance.
2. Queue dispatch loses B's upstream stamp. Prediction: B's resumed run has no parent stamp, so the root report is absent. The test rejects this prediction for the tested path. `AgentStore#dispatch_prompt_queue!` uses the newest entry's authority. The callback entry contains B's own upstream stamp, not C's identity.
3. A manual start or send causes Takeover. Prediction: an operation without the recorded parent declaration changes B to user ownership. The test confirms this documented behavior. It does not establish that such an operation caused the reported incident.

CLI `--parent-agent` and Remote API `parent_agent_key` remain trusted declarations. Neither path infers a parent from `TYCHO_AGENT_KEY`. Callback delivery does not need a fabricated parent key and must not restore a user-owned edge.

Existing tests cover stale generations, queued mixed-authority batches, disconnect/reconnect, callback-only archive, dispatch failures, and queue recovery. The full suite must remain green before signoff.

## Historical evidence limit

Only local relationship metadata and selected journal metadata were read. Prompt, result, and tool contents were not printed. Historical metadata contained a user-owned intermediate edge, but this alone does not identify the operation that changed its owner. No causal claim is supported by that record.

No running services, schedules, identities, or production agent state were changed. No real push notification was sent.

## Next step

Obtain the affected version and exact trigger or affected A/B/C keys. Reproduce that path in an isolated fixture before changing production ownership logic. The current draft is test coverage and investigation evidence, not a completed bug fix. Screenshots do not apply because there is no UI change.
