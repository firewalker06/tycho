# Card 867: PR diff loading

[Card 867](https://fizzy.startkit.tech/1/cards/867) reports a wait of more than
one minute when loading all PR diffs.

## Finding and scope

**Fetch all diffs** used one bulk POST. The server fetched each PR in sequence,
with one metadata request and one patch request per PR. It returned all full
snapshots in one response. The browser could not display a newly fetched
selected diff until every PR completed. Fifteen PRs with 4.2 seconds of combined
provider delay per PR reproduced a wait of more than one minute.

This confirms a slow path, not the exact historical trigger. The example
agent is now archived. Its live PR endpoints reject archived agents. It was
not restored, refreshed, or changed. No original request trace is available.
The initial list, explicit Fetch all action, and saved diff read must not be
reported as the same operation.

## Measurements

Chrome used the same synthetic 15-PR fixture with baseline app code from
`6e46e34` and the changed code. The baseline asset was explicitly served and
asserted. Desktop provider delay was 4.2 seconds per PR. Mobile delay was
160 ms per PR. These are controlled delays, not production network estimates.

| Route or action | Baseline desktop | Changed desktop | Baseline mobile | Changed mobile |
| --- | ---: | ---: | ---: | ---: |
| Initial list visible | 210 ms | 168 ms | 184 ms | 151 ms |
| Selected diff visible after Fetch all | 63,258 ms | 4,402 ms | 2,846 ms | 393 ms |
| All results complete | 63,323 ms | 21,325 ms | 2,882 ms | 1,048 ms |

A separate short-delay run measured 157 ms on desktop and 76 ms on mobile
from synthetic response release to a visible selected viewer. This includes
response handling, scheduled rendering, and browser observation; it is not a
pure CPU profile. The synthetic patches contain one textual change, so these
figures do not claim a bound for rendering maximum-size patches.

The changed desktop selected diff appeared about 93% sooner. Full batch time
fell about 66%. Twelve queued or active PR requests remained when the selected
diff appeared. At most three per-PR browser requests were active.

The isolated Ruby service probe used 20 ms of delay for each provider call:

| Operation | Service time | Provider calls | JSON bytes | Serialization |
| --- | ---: | ---: | ---: | ---: |
| Initial list | 8.88 ms | 0 | 3,508 | 0.01 ms |
| Selected remote fetch | 55.09 ms | 2 | 954 | 0.01 ms |
| Selected saved read | 4.96 ms | 0 | 954 | 0.01 ms |
| Existing bulk remote fetch | 883.18 ms | 30 | 14,358 | 0.06 ms |
| Warm list | 11.29 ms | 0 | 11,822 | 0.03 ms |

Read-only probes of the source event journal measured attachment discovery at
179–236 ms and PR reference extraction at 5–9 ms. The shared snapshot document
loaded in 190.52 ms cold and 0.01–0.02 ms warm. A sample snapshot serialized in
0.13–0.19 ms. Source text, attachment targets, and credentials are excluded.
These probes do not establish the complete historical page-load time.

The service probe recorded zero spawned subprocesses for every measured
operation. PR list and snapshot fetch code uses direct provider HTTP calls. There is no
per-PR git subprocess or remote git fetch in these paths. The existing GitHub
credential helper has a separate 30-second credential cache and five-second
probe timeout. The project/conversation shell can make other requests; those
were not proven to cause the reported delay. Synthetic browser endpoints
isolate PR orchestration from shell and provider latency. No new central index
is justified by these measurements: a persistent catalog already exists.

## Change

Fetch all now enters the existing bounded per-PR request queue. It orders the
selected PR first, renders each completed request, and reconciles list metadata
once after completion. New saved diff content can render before the final list
response. The visible selected diff stays in the bounded browser cache as later results
arrive. Duplicate batch starts coalesce. Individual failures retain previous
saved data and contribute to the final failure count.

The server still checks membership for each per-PR request. The change does
not alter hidden references, catalog revisions, authorization, provider
credentials, snapshot identity, freshness rules, or explicit refresh behavior.
The legacy bulk API remains available to existing API callers.

## Reproduction and checks

```sh
bundle exec ruby -r ./test/support/push_safety.rb test/support/pr_diff_performance.rb
bundle exec ruby -r ./test/support/push_safety.rb test/remote_ui_pr_diff_loading_test.rb
TYCHO_REMOTE_UI_PR_DIFF_LOADING_ONLY=1 TYCHO_REMOTE_UI_PR_DIFF_DELAY_MS=4200 TYCHO_REMOTE_UI_CAPTURE_DIR=path/to/temp/evidence bin/remote-ui-smoke
```

The browser runner uses a throwaway server and synthetic intercepted PR
responses. Its checks cover selected-first ordering, progressive visible
content, request limits, all 15 results, browser exceptions, and viewport
width on desktop and mobile, with Dark, Light, and System appearance. A second
batch injects denied requests and checks that the selected saved diff survives. The queue regression covers duplicate starts,
individual failure, saved-data preservation, and final failure reporting.
The existing Remote Server suite covers membership, cache behavior, metadata,
manual catalog operations, and fetch coalescing.

An exact incident attribution needs a trace that distinguishes initial route
loading from an explicit refresh. This fix removes the reproduced batch wait
without changing live agent state to obtain that trace.
