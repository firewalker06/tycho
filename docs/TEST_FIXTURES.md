# Test fixtures and prerequisites

Normal checks must not need operator files, saved Tycho agents, provider
credentials, or another checkout. Run all commands from the repository root.

## Normal checks

Install Ruby 4.0.9 or later and the gems with `bundle install`. Install Git
and Node.js as well. `bin/test` uses Git to list tracked Markdown and Node.js
for JavaScript contract checks. Some process tests also use POSIX process
and shell tools. These are runtime prerequisites, not private fixtures.

Run `bin/test`. Each command gets a temporary HOME, Tycho home, skills home,
and logs root. The runner clears managed-agent launch variables, config
path overrides, and the credentials listed in
`test/support/test_environment.rb`. Ruby tests preload the Web Push guard.
This is process isolation, not a filesystem or network sandbox. Installed
runtime tools and gems remain available through PATH and Ruby's gem paths.

The parser, cost, metrics, inquiry, and structured-output fixtures are small
tracked files in `test/fixtures`. Paths inside parsed events are synthetic
text. They do not require matching files on disk. Archive, attachment,
workspace, Git, and queue tests create their own data in temporary roots.
The damaged archive queue coverage in `test/remote_server_test.rb` generates
its input; no copied agent archive is required.

## Optional browser checks

`bin/remote-ui-smoke` needs Node.js, npm, Chrome/Chromium, and access to the
npm registry to install Playwright in its temporary directory. Set
`CHROME_PATH` if the browser is outside the default macOS locations. It
starts a loopback server with generated config, agents, attachments, fake
harness output, and a fake GitHub API. It needs no running Tycho service or
operator credentials. Its fixture server gets an isolated HOME and clears
managed-agent launch variables and the shared credential list.

Run the full smoke with `bin/remote-ui-smoke`, or select a focused mode from
[the repository commands](../AGENTS.md). Focused modes do not prove every
other mode. The same browser prerequisites apply to
`bin/remote-ui-profile` and the two `bin/capture-site-*` commands. The
capture commands write website images in the checkout; use a disposable
copy when checking them. The profiler's `--archive DIR` mode is an explicit
optional integration with a supplied archive. Its default route fixtures
are synthetic.

The queue-read and inquiry-dismiss fixture commands start foreground local
servers. Stop them when done and remove their printed temporary root after
inspection. They are manual acceptance tools, not prerequisites for
`bin/test`.

`node test/browser/interaction_report_smoke.js` starts its own local page.
Install Playwright separately and set `TYCHO_PLAYWRIGHT_PATH` as shown in
[the profiler reference](REMOTE_UI_INTERACTION_PROBE.md). The schedule
report example uses a loopback placeholder and the key `smoke`; it needs a
prepared temporary server with that schedule paused. It does not connect to
an operator host by default. Reports against live URLs are separate
integration work and change the selected control.

## Optional installed harness checks

The ordinary suite uses fake harness processes and tracked event streams.
To test an installed Pi with offline handled input, run:

```sh
TYCHO_TEST_INSTALLED_PI=1 bundle exec ruby -r ./test/support/push_safety.rb test/pi_rpc_transport_test.rb
```

This requires Pi on PATH. It uses temporary home/session state and a local
extension that handles input without a provider call. The same assertions
remain available, but a machine's installed Pi no longer changes the normal
suite. Real provider checks require separately installed, authenticated
harnesses and explicit integration setup; see [agy verification](AGY.md)
and [harness inventory](HARNESS_INVENTORY.md).
