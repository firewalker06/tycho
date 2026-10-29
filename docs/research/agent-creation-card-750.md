# Agent creation: Card 750

Related: [Fizzy Card 750](https://fizzy.startkit.tech/1/cards/750).

## Result

Quick Agent and Project → New agent open an empty Conversation before the
create request returns. The pending view has a loading message. It has no
Conversation heading or request disclosure, as the owner requested. A failure
shows the server error. Uncertain acceptance offers retry; a definite validation
rejection offers Edit request and Discard. Corrections use a new request ID.
The client keeps the pending prompt, options, project, fixed destination, a
minimal server descriptor, and request ID in tab session storage. A reload can
retry the same uncertain request or restore a rejected correction. Completed
entries retain at most 20 small ID/agent-key route records; they retain no agent
snapshot, server catalog, or completed prompt. Old drafts are compacted on read.

A pending request is separate from catalog agents. It has no native session,
ownership edge, run, or persisted agent key. Only the server response binds the
real agent. Success replaces the pending history entry. If the user leaves,
success updates the catalog without changing the selected page. A catalog
response started before the mutation cannot remove the new agent.

## Profile method and limits

Measurements used a throwaway `bin/tycho serve` process, temporary config,
schedules, skills home, and logs. They used the real HTTP routes, AgentStore
file lock, persistence, response projection, native wrapper launch, and Chrome.
The harness and GitHub CLI were synthetic executables. The harness emitted a
native-session event and a structured result. No live agent or user config was
changed. No real provider/authentication/network latency was measured.

The first baseline had zero initial agents. The scale fixture had 100 synthetic
idle agents. Six sequential POST requests alternated Create only and Create and
Run. Ruby TracePoint recorded inclusive method time; it adds overhead. The
existing HTTP Server-Timing header supplied total, load, and JSON times.
These small samples establish fixture costs, not production percentiles.

| Fixture | Create only API | Create and Run API |
| --- | ---: | ---: |
| Initial baseline, 0 agents | 9.25–22.63 ms | 139.24–219.86 ms |
| Scale fixture, 100 agents | 146.02–364.71 ms | 415.37–628.41 ms |

The initial baseline ran before implementation. The scale fixture ran after the
change, using callers without request IDs. No server speed gain is claimed.

Measured causes in the fixture:

- The old browser code awaited the complete create response before navigation.
- Create and Run waits for the native wrapper start acknowledgement while the
  store transaction holds its exclusive lock. Initial `ManagedAgent#start!`
  took 121.58–157.70 ms. At 100 agents, native acknowledgement alone took
  88.11–123.92 ms; the complete `start_agent!` transaction took 191.96–274.21 ms.
- Store read/poll/save work and response construction grow with agent count.
  At 100 agents, creation/persistence took 59.95–178.18 ms. `agent_payload`
  took 57.68–240.96 ms, including further store/context reads. These inclusive
  ranges overlap other recorded timings and must not be added as percentiles.
- JSON encoding was 0.0–0.1 ms. The observed wait was not JSON encoding.
- There was no separate provider auth CLI call in these create requests.
  Real harness startup, lock contention, disk, and provider behavior can add
  more time. This fixture does not identify the live server's exact cause.

The patch keeps the existing synchronous server start/ownership boundary.
Moving native launch or store work outside that boundary would expand the scope
and require separate lifecycle work. The causal change here removes the API
wait from visible navigation.

## Matched Chrome before/after

Chrome loaded the original `app.js` from base commit `0175d86` through a test
response override, then the current code. Both used the same 100-agent fixture
and a one-second held POST response. The repository was not switched or reset.
Times include the click and browser automation observation.

| Width | Flow | Before: Conversation visible | After: pending Conversation visible | After: real agent bound |
| --- | --- | ---: | ---: | ---: |
| 1440 | Quick Agent | 1449 ms | 51 ms | 1431 ms |
| 1440 | Project Create | 1192 ms | 46 ms | 1187 ms |
| 390 | Quick Agent | 1423 ms | 44 ms | 1490 ms |
| 390 | Project Create | 1206 ms | 46 ms | 1310 ms |

The actual agent still needs the server response. The improvement is immediate
feedback and navigation, not a claim of faster native execution.

## Retry and lifecycle contract

The browser creates a stable `client_request_id` and fixes the destination at
submission. The store records an optional `creation_request` containing the ID
and a SHA-256 fingerprint of the submitted options and actor. This field is
internal persistence data; it adds no config or structured-result schema.
The exclusive store transaction finds an active or archived receipt before it
creates anything. A matching retry returns the same agent and does not start it
again. A conflicting reuse returns HTTP 409. Invalid IDs return HTTP 400.

If creation was saved but startup raised, retry returns that saved agent;
users can inspect and start it through the usual controls. If the server stops
between creation and start, retry also returns the saved idle agent. It does
not silently launch a second run. This is the deliberate at-most-once startup
tradeoff. Archive manifests retain the receipt so an archived agent cannot be
recreated by a late retry. Before returning an archived receipt target, the
service applies the same immutable hidden-at-archive visibility rule as normal
archive reads. An unreadable target returns a generic unavailable response and
creates no replacement. Clones use a new ManagedAgent and do not inherit it.

The existing no-ID API behavior remains supported. Create only stays idle;
Quick Agent starts once. Optional names and scoped project defaults remain.
No queue policy, ownership generation, native-session rule, Summary control,
or Project form field was redesigned.

## Checks and reproduction

Run the new Chrome checks from the repository root:

```sh
TYCHO_REMOTE_UI_OPTIMISTIC_CREATE_ONLY=1 \
TYCHO_REMOTE_UI_CAPTURE_DIR=/tmp/tycho-card-750-browser bin/remote-ui-smoke
```

They use desktop (1440 px) and mobile (390 px), a held create request, immediate
loading without the rejected heading/disclosure, focus, polling, browser Back, Create only/Run,
server error, keyboard retry, actual whitespace rejection and correction,
discard, minimal storage, duplicate retry protection, lost response plus
reload, preserved prompt/project, navigation away, and overflow checks.
The existing auto-name smoke also checks optional names, scoped project
selection, persisted defaults, and mobile/desktop creation.

Server regressions cover hidden-at-archive receipt visibility through the real
service sequence and HTTP, pre-save versus post-save rejection classification,
a new service instance retry, one run only, conflicting
options, archived receipts, concurrent requests, and failure after persistence.

Local profiling evidence is retained outside the checkout in
`/tmp/tycho-card-750/`: `baseline.json`, `stages.jsonl`, `scaled.json`,
`scaled-stages.jsonl`, `comparison.json`, and the fixture/profiling scripts.
Chrome receipts and screenshots are in its `browser/` directory. The tables
above retain the main measurements even after temporary files are removed.

## Integration scope

A read-only check of Beta branch `fix/partial-queue-755` at `477d9f7` found
only `test/prompt_queue_test.rb` changed from its merge base. There is no current
file overlap. Charlie adds create-specific handlers and helpers; it does not
edit queue controls or queue transitions. Parent coordination through
`agent send` was rejected by Tycho's ancestor protection. The parent must check
for later overlap before integration and arrange the independent review.
