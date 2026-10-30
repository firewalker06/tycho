# Card 770: Quick Agent opening

[Card 770](https://fizzy.startkit.tech/1/cards/770) covers the Quick form fix and a
separate completed inventory. The inventory and its original fixtures are in
[the inventory report](/Users/didik/Code/personal/pull-request-reviews/firewalker06/tycho/agent-create-archive-inventory-770.md).
This change covers Quick opening, options, and the two footer create actions. Clone, archive, schedules,
TUI, CLI, and creation receipt/store transitions keep their existing behavior.

## Cause and change

The measured old path awaited local detailed setup, Quick settings, and selected
project detail before drawing the form. A selected peer added its detail read.
Background peer refresh did not block a local open in these fixtures. These
controlled tests do not prove the cause or delay size in the live app.

The form now opens synchronously. `GET /quick-agent/options` returns local
eligibility, saved default, project/template defaults, and shared offline
harness/model/effort catalogs. It does not run executable, skill, tool, provider,
or peer discovery. Server create validation remains authoritative. Create stays
disabled until the selected project's required options are known. A local create
never waits for peer detail. Failures keep the editable form and offer retry.

Host projects come first in the existing selector. Labels include the server
name, so equal project names remain distinct. Peer availability comes from the
existing catalog; refresh retries use the allowed broker route and read the
catalog without reopening Settings. Only selecting a peer reads its detail.
An unavailable explicit peer remains selected and disables Create.

The dialog uses an in-memory draft, session generation, project request sequence,
and coalesced local/project reads. Async updates keep the prompt, name, focus,
selection and composition nodes. Only untouched options receive late defaults.
Close retains the draft for this page. Submission clears it. The footer has
Create (idle) and Create and run actions. Both use the shared creation snapshot
and receipt path with an explicit `start: false` or `start: true`. Enter in the
prompt or name keeps the run default; activating Create never runs. Both buttons
wait for the same option readiness and pending gates.
Reload starts a new opening draft; PR 281's existing pending-create persistence
continues to handle submitted requests. Drafts contain no provider credentials.

The creation record still freezes the server descriptor, raw project key, API
path, request body and `client_request_id`. Its fingerprint, receipt lookup,
uncertain retry and atomic launch behavior are unchanged.

## Matched Chrome measurements

Before source: `55440cf0d0fddc195c0815e1436a260514b927bf`. The existing research
fixture was rerun against that clean Charlie checkout before edits. The after
fixture uses the same delays and 1440x900 Chrome, three samples per case. It adds
the new options response and measures first editable prompt separately from
selected option readiness. Times start at the real opening handler and include
one animation frame. They exclude human click latency and provider startup.

| Condition | Before editable (ms) | After editable (ms) | After options settle (ms) |
|---|---:|---:|---:|
| local-fast-cold | 15.1-24.4 | 7.7-12.2 | 7.7-17.7 |
| local-setup-600-cold | 611.7-614.7 | 8.1-14.8 | 8.1-18.0 |
| local-setup-600-warm | 10.8-14.9 | 7.0-15.8 | 7.0-15.8 |
| local-settings-600-warm | 606.0-608.4 | 10.5-16.2 | 10.5-16.3 |
| local-project-600-cold | 612.5-614.6 | 11.9-17.1 | 12.0-17.1 |
| local-all-three-delayed | 763.1-766.8 | 12.5-15.0 | 12.6-15.0 |
| one-remote-1600-local-selected | 18.3-28.9 | 10.6-13.7 | 10.6-13.7 |
| failed-remote-local-selected | 15.3-32.7 | 6.1-14.5 | 6.1-14.5 |
| three-remotes-1600-local-selected | 24.5-31.1 | 7.9-17.0 | 8.0-17.1 |
| selected-remote-project-800 | 815.9-817.5 | 8.4-14.1 | 813.0-818.1 |
| selected-remote-project-fails | 817.2-823.2 | 3.5-10.2 | 810.8-823.5 |
| settings-failure-blocks-form | 207.7-216.6 | 9.1-16.8 | 9.1-18.2 |

For the failed selected peer, “settle” means an inline error, with Create still
disabled. The old settings-failure case produced no form; the new path does not
request that endpoint. Fast options in this matched HTTP fixture are synthetic,
not a claim about live service speed. Old setup/settings/local-detail delays no
longer affect opening because Quick no longer requests those paths.

The separate real-service smoke uses temporary config, workspace, home and logs,
a fake local harness, and browser-controlled peer replies. Both 1440 px and
390 px viewports must show an editable prompt in under 100 ms while local options
wait 600 ms. It records actual options-ready time separately. It checks cold and
warm opens, permission/error retry, revoked and empty eligibility, delayed/failed
peers, three peers, equal project names, contextual peer opening, late Host
defaults, explicit harness/model/effort edits, explicit Default selection, field
and composition retention, close/reopen/double open, A/B/A switching, stale
replies, peer retry and responsive overflow. With all three peer detail reads
held, a local create must finish with one local request and one fake-harness run. A fixture-only peer submission also verifies the
raw project key, custom default harness, broker path and uncertain Create-only record.
The create-actions checks also count actual fake-harness invocations: Create
makes one request, leaves the agent idle with zero runs and zero harness launches;
Create and run and Enter make one request and one launch. Both actions retain
their exact body through lost-response, reload, and receipt retry. Rejection
allows correction with a new request ID. Both buttons share readiness and pending
disabled states. X, Escape, and overlay close preserve the page draft.

Run from the repository root:

```sh
TYCHO_REMOTE_UI_QUICK_OPTIONS_ONLY=1 TYCHO_REMOTE_UI_CAPTURE_DIR=/tmp/tycho-770-options bin/remote-ui-smoke
TYCHO_REMOTE_UI_AUTO_NAME_ONLY=1 bin/remote-ui-smoke
TYCHO_REMOTE_UI_OPTIMISTIC_CREATE_ONLY=1 bin/remote-ui-smoke
bundle exec ruby test/remote_server_test.rb
bin/test
```

The API regression checks real eligibility and template defaults, configured
custom harnesses, shared offline catalogs, and absence of provider auth metadata.
The existing optimistic-create browser suite checks definite rejection,
lost-response retry, hidden/unavailable accepted targets and archive receipt
failure at both widths. No real agents, stores, peer hosts or paid providers are
used. Screenshots are temporary files outside the checkout and go into the published
PR as native GitHub attachments. Independent review belongs to the parent.
