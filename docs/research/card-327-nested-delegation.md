# Card 327: nested delegation investigation

[Card 327](https://fizzy.startkit.tech/1/cards/327) reports that a child report causes Takeover on an intermediate delegated agent. The root then receives no completion report.

## Result

The original Takeover observation remains unproven. Two automatic upstream report omissions were reproduced and fixed. The first occurs when Stop dispatches a queued child callback. The second occurs when B exits after the normal report scan but before automatic queue dispatch. Both left ownership unchanged.

The shared AgentStore start boundary now confirms that the old process is stopped, finalizes its run, and durably records its eligible report before `start!` can replace `last_run` or clear the result. It uses the existing report ID, generation, and connection rules. A ledger write failure prevents the successor from starting. No ownership rule changes are part of this fix.

## Repeatable check

Run from the repository root:

```sh
bundle exec ruby -r ./test/support/push_safety.rb test/delegation_runner_test.rb
```

The test uses temporary config and log roots, a fake Codex executable, and actual CLI commands and detached runners. It does not dispatch production agents. The push safety helper blocks real push transport.

The added scenario creates A → B → C with explicit recorded parent declarations. C completes, its callback starts B, and B's completion starts A. It checks both edges for parent ownership and generation 1, one resumed report per edge, B's upstream run stamp, agent message authorship, and the protected `delegation_callback` queue source at both hops.

The test then sends a direct user prompt to B. This causes user ownership at generation 2. Another C report starts B with that user stamp and produces no new report to A. Only a later prompt from recorded parent A restores parent ownership at generation 3. It does not replay the user-owned runs.

The expanded detached-runner test also holds B running while C completes. It verifies automatic callback enqueue and dispatch, both alone and mixed with a real user prompt. The RemoteService test discovers C through polling and checks the same two cases. These cases pass. They do not cover every process-exit boundary.

## Hypotheses and source checks

1. Callback acceptance changes B's edge owner. Prediction: the A → B relation becomes user-owned after C completes. The isolated test rejects this prediction for the tested path. `DelegationCoordinator#deliver_reports!` enqueues the callback directly with B's current upstream ownership stamp. It does not pass the report through ordinary user prompt acceptance.
2. Queue dispatch loses B's upstream stamp. Prediction: B's resumed run has no parent stamp, so the root report is absent. The test rejects this prediction for the tested path. `AgentStore#dispatch_prompt_queue!` uses the newest entry's authority. The callback entry contains B's own upstream stamp, not C's identity.
3. A manual start or send causes Takeover. Prediction: an operation without the recorded parent declaration changes B to user ownership. The test confirms this documented behavior. It does not establish that such an operation caused the reported incident.

CLI `--parent-agent` and Remote API `parent_agent_key` remain trusted declarations. Neither path infers a parent from `TYCHO_AGENT_KEY`. Callback delivery does not need a fabricated parent key and must not restore a user-owned edge.

Existing tests cover stale generations, queued mixed-authority batches, disconnect/reconnect, callback-only archive, dispatch failures, and queue recovery. The full suite must remain green before signoff.

## Historical evidence

The read-only local ledger snapshot contains 1,016 relationships and 1,594 reports. Twelve intermediate agents have both a parent and children. Eleven retain parent ownership at generation 1. Their callback journals include both older individual reports and newer consolidated Read queue batches. Callback entries retain agent authorship in these eleven chains.

The remaining intermediate agent changed to user ownership at generation 2 on September 9. Its journal has a plain user message and a user-stamped run at 04:28:51 UTC. Its first child relationship starts at 04:30:59. Its first child callback arrives at 04:32:12. Thus the first child callback cannot have caused that earlier ownership change. The plain message has no author metadata. It does not identify a human, a CLI caller, or a Remote API caller. Prompt contents were not copied into this report.

That older journal has 61 typed callback events without `message_author`. This legacy representation alone does not prove user control: callback memory uses a user role for model input, while ownership acceptance is a separate operation.

Three other stored parent-owned runs have no matching report in the current ledger: two successful runs on September 15–16 and one stopped run on October 6. Their relationships remain parent-owned at generation 1 and have no recorded disconnect marker. Each missing run is followed closely by a queued successor. This supports a report-ordering hypothesis, but does not prove the cause of those historical omissions. An additional unstamped run started before its relationship was attached and is not eligible for a callback.

The persisted Remote server cache reports version 0.13.0 for two peers. It contains no nested chain to inspect. No live API request was made, since an agent read can poll and persist runtime state.

## Runtime observations

The shell command `tycho` resolves to the installed Homebrew 0.13.0 package. The checkout version is 0.14.0. The local server process started on October 16 through an Alpha bootstrap that requires the Alpha library directory. The scheduler process started on October 15 through the Alpha executable. Neither persisted daemon metadata nor the archived run records provide a loaded source commit. Process paths and start times cannot certify the exact code held in those processes.

The installed 0.13.0 active callback enqueue path matches the checkout. The coordinator difference concerns archived arrivals. The actor and delegation-store files match exactly. The isolated nested RemoteService polling test also passes when loaded against the installed 0.13.0 source under the working Bundler environment.

A separate detached test against that installed source could not finalize its first root run. A direct finalization command in that retained isolated fixture failed with a native OpenSSL `LoadError`: a user gem extension links a different Ruby library. This demonstrates a local loader failure, not Takeover. It does not establish that a historical agent encountered the same failure. No installed files or service state were changed.

## Reproduced report omissions

A deterministic Stop fixture uses real AgentStore and DelegationCoordinator behavior with fake model starts:

1. A delegates B; B delegates C. Both relationships are parent-owned at generation 1.
2. B remains running while C completes. Store polling queues C's callback behind B.
3. `AgentStore#stop_agent!` stops B, then starts its queued callback.
4. The stopped run remains in B's run history, but has no report to A. Ownership remains parent/generation 1.

A controlled process-exit fixture shows the same report gap without Stop. It changes only the point at which B becomes terminal:

| Exit point | Stored previous status | Reports for previous B run | Owner/generation |
| --- | --- | --- | --- |
| Finalized before the coordinator report scan | success | 1 | parent / 1 |
| Exit after the report scan, before automatic queue dispatch | partial, due to undelivered queued work | 0 | parent / 1 |

The fixture uses a fake spawn method that calls the real `finalize_previous_run!` first, as the real `start!` does. The injected exit writes a synthetic successful result and exit status to temporary fixture files. It does not dispatch a real model.

The source sequence explains these two omissions. `DelegationStore#record_report!` reads only `child.last_run`. Normal load scans reports before queue dispatch. If B is finalized and replaced after that scan, the next scan sees the successor. The previous terminal run is no longer the report candidate. The Stop path has an explicit stop-then-dispatch sequence without another report scan between those actions.

These are the pre-fix results. They do not reproduce the card's claimed ownership change. The later fix preserves these reports at the shared start boundary.

## Updated hypotheses

1. Ordinary input caused the observed Takeover. Prediction: a plain input and new ownership generation precede the first child callback. The September 9 chain matches this sequence; the initiating caller is unknown.
2. Terminal replacement causes the missing upstream report. Prediction: moving B's exit from before the report scan to after the scan removes the old run's report without changing ownership. The controlled fixture confirms this prediction. Its connection to the operator's incident is unproven.
3. Runtime or loader differences cause callback loss. Prediction: the same source path fails before callback processing in one runtime. The installed-source detached fixture has a loader failure; the in-process callback test passes. The loaded commit for a historical incident remains unknown.
4. Ordinary callback batching changes ownership. Prediction: running-B callbacks or mixed batches use the wrong upstream generation. The new automatic detached-runner and RemoteService tests reject this prediction for the tested paths.

## Fix verification and limits

The new assertions require one report for B's prior eligible terminal run. Both Stop and the exit boundary failed on the old code with zero reports. They pass after the fix. The deterministic exit injection occurs after the real coordinator scan and before the real queue dispatcher; native process creation alone is faked.

The regression matrix also covers direct user takeover, parent reclaim with a new generation, disconnect/reconnect, archived roots, and repeated polling. Ineligible old runs remain absent. Eligible runs keep their own status and generation and produce one report. A simulated ledger write failure retains the old run and queued work; retry produces one report and then starts the successor. Existing actual CLI/detached-runner coverage checks A → B → C propagation and direct takeover/reclaim with a fake model.

The fix does not scan old histories or revive reports from superseded runs. It does not change message authorship, queue batch selection, ownership generations, callback delivery gating, or archive policy. It records the current terminal run while its full result is still available and uses the existing ledger for later delivery.

The takeover-specific missing evidence remains the operator's affected chain and time, the caller or entry origin at its ownership transition, and the loaded source version for that runtime. The parent handles that input. These unknowns do not block the proven report-loss fix.

Only local files and process metadata were read for historical evidence. Prompt, result, tool, and credential contents were not copied into the report. All synthetic writes and dispatches used isolated fixture state. No production agent, running service, schedule, or identity was changed. No real push notification was sent.

The PR remains draft for independent review. Screenshots do not apply because the fix changes backend lifecycle behavior and has no UI change.

## Resumed ownership investigation

PR 247 was rechecked at the previously approved head `323403b52053c297ccbe142051d7302666b159d6`. It was open and published, with successful required signoff and no live review comments or review bodies to address. The existing independent Standards and Spec report approved that exact head. This continuation preserves the production fix and the published PR state. Any new head needs a separate independent review.

The worker could not fetch the current Fizzy card or comments because it has no Fizzy token. The cached authoritative card text contains no affected chain or time. The parent handles Fizzy access; this is not a request for credentials.

The new read-only local ledger snapshot contains 1,032 relationships and 1,665 reports. It has the same twelve nested intermediates as the earlier snapshot. The same single intermediate is user-owned at generation 2, with the same September 9 transition. No additional nested Takeover example was found. Historical prompt and tool contents were not copied into this evidence.

### Three ranked, falsifiable hypotheses

1. **An ordinary input path accepted a manual child report.** Prediction: `agent send B ...` without a parent declaration changes B to user ownership, including when `TYCHO_AGENT_KEY=C`; an automatic C callback does not. The isolated loop confirms this mechanism in Local and Remote modes. This is the documented input contract, not evidence that the historical incident used this path.
2. **A valid parent declaration is lost in CLI routing.** Prediction: A's `--parent-agent A` send or run reaches B as user input, changing its owner or generation. Both real CLI transports preserve the declaration in the tested cases. Parent-declared run also restores Delegation after user input, advancing the generation. This hypothesis was not reproduced.
3. **Automatic callback resume uses user-control acceptance.** Prediction: C's callback changes B's parent-owned edge or enters a user-owned run stamp. The automatic path retains the protected callback source and the existing upstream stamp. When the edge is already user-owned, it retains that stamp and does not resume upstream reporting. This hypothesis was not reproduced.

### Minimal comparison loop and observed trace

`test/delegation_runner_test.rb` now runs the same A → B → C contract through local CLI and a throwaway localhost Remote server. Both use temporary config, logs, identities, empty schedules, and a fake Codex executable. The loop uses the actual CLI parser, Remote request serialization, automatic callback enqueue, detached finalization, and queue dispatch. It does not call a production server.

The following trace is identical for both transports. Each row checks the persisted relationship, actual native run stamp, and durable upstream ledger count:

| Operation | B owner / generation | B run stamp | New queue source / stamp | Total B reports to A |
| --- | --- | --- | --- | --- |
| C completes; automatic callback starts B | parent / 1 | parent / 1 | delegation_callback / parent 1 | 1 |
| A sends with recorded parent declaration | parent / 1 | parent / 1 | No queued input | 2 |
| A runs B with recorded parent declaration | parent / 1 | parent / 1 | No queued input | 3 |
| Ordinary direct user prompt | user / 2 | user / 2 | No queued input | 3 |
| A reclaims B with parent-declared run | parent / 3 | parent / 3 | No queued input | 4 |
| Ordinary send from a process with C's environment key | user / 4 | user / 4 | No queued input | 4 |
| C completes again; automatic callback starts B | user / 4 | user / 4 | delegation_callback / user 4 | 4 |

A separate upward prompt declaring C as B's parent is rejected and leaves B's ownership unchanged. The loop never declares A on C's behalf. It does not grant authority from environment data or report text.

The automatic messages retain agent authorship and protected queue sources. Upstream reporting stops only after the ordinary input transition in this loop. This reproduces the ownership-change and missing-root-report pattern under ordinary input, but does not reproduce an automatic callback incorrectly causing Takeover.

Run from the repository root to capture only synthetic ownership and queue metadata outside the checkout:

```sh
TYCHO_TEST_CONTRACT_TRACE=/tmp/tycho-nested-contract.jsonl bundle exec ruby -r ./test/support/push_safety.rb test/delegation_runner_test.rb
```

### Parent contract and remaining evidence

The callback path calls `DelegationCoordinator#deliver_reports!`, which enqueues directly with `source: delegation_callback` and B's current upstream ownership stamp. It does not pass through ordinary user acceptance. Local CLI send/run builds its actor from the explicit parent option. Remote CLI includes that option as `parent_agent_key`; RemoteService builds the same actor. Ordinary input without that field reaches `accept_prompt_from!` as a user actor and advances ownership generation. `TYCHO_AGENT_KEY` is informational, except for the documented delayed self-continuation rule.

The original automatic Takeover observation remains unproven. To distinguish a callback fault from contract-defined user control, the missing evidence is the affected A/B/C keys, the ownership-change time, the entry origin, redacted CLI flags or HTTP route and parent-field presence, and the runtime executable/version for that entry. The approved two-path report-loss fix is not used as a substitute for this missing reproduction. No new production change is proposed by this continuation.
