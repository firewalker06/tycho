# Card 868 delegation verification

[Card 868](https://fizzy.startkit.tech/1/cards/868) and
[draft PR 351](https://github.com/firewalker06/tycho/pull/351) track this work.
This report covers test setup. No production renderer, CSS, or delegation
lifecycle code changed.

## Controlled comparison

The comparison used source exports of base `545c9a5` and the initial PR head
`cdee4235f9804ddceca9e5643081c702902149df`. Both ran with a minimal environment:
PATH, a new empty HOME, TMPDIR, and LANG. The fixture server had its own config,
home, logs, fake harness, and two generated agents per scenario. The probes
used the real API and Chrome. They did not inject a STARTED event.

Runtime tools remained available: Ruby 4.0.9, Node.js 26.0.0, npm 11.12.1,
Chrome 157.0.8103.52, and installed gems. The first differential probe used
Playwright 1.64.1. Browser commands also need npm registry and pinned
application CDN libraries. This was not an offline dependency test.

The production `lib` tree is identical between these two commits. The
`app.js` SHA-256 is
`e412e9fdf804400bf6cb831aea8d880210a737d6b766939b8341aba241fafd95`
in both exports. The same input still had to be run against each version;
source equality alone was not treated as a passing browser check.

## Case 1: missing STARTED

The old full-smoke assertion reported a header of `SENT` instead of `STARTED`.
The minimal probe created an idle parent and a child, accepted a parent-declared
message, then started the child. Both versions recorded only
`agent_message_sent`. They correctly did not attribute the start to an active
parent run, because there was no such run.

A second probe held a fake parent harness at a file gate while the child
started. Both versions then recorded `agent_message_sent` and `agent_started`.
The first header was still SENT, so selecting the first generic event header
was also wrong. The corrected fixture waits for the child's real native-start
acknowledgement on its running parent, then releases the parent gate. The
assertion selects the STARTED event and still checks its label and position
before the callback. It does not fabricate the expected event.

## Case 2: mobile callback behind the header

The old check called `scrollIntoView({block: "start"})`, then subtracted 12
pixels from the conversation pane's scroll position. At mobile size, that pane
has `overflow: visible`; the document owns scrolling. The pane adjustment had
no effect. Both exports reproduced the same failure:

| Idle-parent probe at 390 by 844 | Base | Initial head |
| --- | ---: | ---: |
| Document scroll after start alignment | 334 | 334 |
| Pane scroll | 0 | 0 |
| Callback top | 0.375 | 0.375 |
| Callback bottom | 141.063 | 141.063 |
| Header bottom | 71.391 | 71.391 |
| Composer top | 633 | 633 |
| Original clearance assertion | Fail | Fail |

Center alignment places the callback inside the visible viewport. With the
active-parent fixture, both versions measured callback bounds 351.641 to
492.328, header bottom 71.391, and composer top 633. The original horizontal,
header, and composer clearance conditions pass. No tolerance or CSS changed.
These are fixture/setup defects, not evidence of a product layout regression.
Repeated independent idle and active runs confirmed both observations.

## Small regression fixture

Run from the repository root:

```sh
TYCHO_REMOTE_UI_DELEGATION_FIXTURE_ONLY=1 bin/remote-ui-smoke
```

This uses two small agent pairs. The idle pair proves that accepted sends do
not falsely claim an active-run start. The active pair proves native start
attribution, the correct child identity, event order, callback content and
alignment, and mobile header/composer clearance. Output also records the old
start-alignment geometry. A recorded bad setup is not a skipped assertion:
the corrected checks still fail if the event is absent or the visible card
crosses the header or composer.

For a product comparison, create temporary source exports with `git archive`,
then copy the same current `bin/remote-ui-smoke`,
`test/support/test_environment.rb`, and
`test/browser/delegation_fixture_smoke.js` into each export. Run the command
above in each with the same clean environment. This shares only fixture
tooling; production files stay at their named revisions. No clone, worktree,
registered project, or existing Tycho data is needed.

## Broader smoke setup

The corrected scenarios allowed the broader checks to reach later fixture
assumptions. Summary attention checks now target the message article rather
than a navigation control that shares its summary ID, and their synthetic
conversation is marked loaded. Fixture input and measurement run in one browser
turn so a real poll cannot replace the client-only data between them. Agents ordering is checked against the expanded
quick-switch DOM, with an independent completeness/uniqueness check for all
agents. Search checks explicitly expand delegated groups before counting rows.
Avatar/title alignment is checked within each row so intentional tree indents
do not appear as column drift. The original suppression, search highlighting,
ordering, avatar-size, and gap checks remain.

The latest full-command results and exact-head signoff are recorded on the PR
and card. The small mode does not claim coverage of every other browser mode.

## Remaining full-smoke limit

With identical corrected fixture tooling, both base and initial head pass the
full delegation-only smoke. Both default full-smoke runs then stop at the
existing grouped Agents geometry assertion. The rows are 59 pixels high,
including a 1-pixel bottom border; the final row is 58 pixels without that
border. The assertion requires every row to be at most 58.5 pixels. All other
reported fields satisfy that assertion's limits. No threshold was changed.

Run the small reproduction with four generated agents:

```sh
TYCHO_REMOTE_UI_DELEGATION_FIXTURE_ONLY=1 TYCHO_REMOTE_UI_GROUP_GEOMETRY_PROBE=1 bin/remote-ui-smoke
```

The two delegation cases run first. The probe then uses the real grouped
Agents renderer at mobile size and applies the same 58.5-pixel bound. It exits
nonzero when that existing geometry contract fails. It needs no long smoke
history or empty-project fixture. Apply the same fixture tooling to both
product exports to compare them.

Decision needed: should the product reduce the complete row box, or should a
separate change revise the measurement contract for the separator? This task
does neither. The full-smoke assertion and the small probe retain the existing
bound. Later full-smoke stages remain unverified because execution stops here.
