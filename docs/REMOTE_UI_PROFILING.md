# Remote UI profiling

`bin/remote-ui-profile` is an opt-in browser performance suite for every Remote UI route. It is intentionally outside `bin/test` and normal CI because it installs Playwright in a temporary directory, launches local Chrome, and profiles a throwaway `tycho serve` fixture.

The fixture contains an 800-event conversation, a Markdown attachment, a changed Git workspace, a schedule, and two unavailable peer servers. That combination covers ordinary page cost and the degraded-peer condition that previously blocked the single-threaded local HTTP loop.

## Run the profiler

```sh
bin/remote-ui-profile
```

The command prints one row per route and writes `/tmp/tycho-remote-ui-profile.json`. It does not touch real Tycho config, agents, logs, schedules, or workspaces.

Capture browser evidence when investigating a regression:

```sh
bin/remote-ui-profile \
  --output /tmp/tycho-remote-ui-profile.json \
  --trace /tmp/tycho-remote-ui-trace.zip \
  --screenshots /tmp/tycho-remote-ui-screenshots
```

To reproduce a problem with an existing archived agent without serving the real Tycho data root, pass its archive directory. The profiler copies the archive into its temporary fixture:

```sh
bin/remote-ui-profile \
  --archive ~/.tycho/logs/agents/archive/20260930-055309-example-agent \
  --output /tmp/example-agent-profile.json
```

Set `CHROME_PATH` when Chrome, Chromium, or Edge is not installed in a standard macOS location. Set `TYCHO_PLAYWRIGHT_PATH` to reuse an existing Playwright package instead of installing a temporary copy.

`--fail-over MILLISECONDS` makes the optional run fail when any route exceeds a wall-time budget. Use this only on a stable profiling host; wall time includes local API and filesystem work and is not deterministic enough for normal CI.

## Interpret the report

- `duration_ms`: wall time from hash navigation until the route has rendered and completed two animation frames. This is the primary responsiveness number.
- `total_blocking_ms`: time above the 50 ms long-task allowance. A high value points to JavaScript/rendering work on the browser main thread.
- `script_ms`, `layout_ms`, and `style_ms`: Chrome performance-counter deltas for the route.
- `dom_nodes` and `body_bytes`: rendered-page size. Large increases often explain layout or memory regressions.
- `request_count` and `transferred_bytes`: route-specific network activity after resource timings are reset.
- `js_heap_bytes`: a point-in-time heap reading. Compare route patterns and repeated runs; do not treat one reading as a leak proof.

Use the trace for request ordering, screenshots, and browser timing details. A slow route with low blocking time usually points to server or network wait. A slow route with high blocking, script, layout, or style time points to browser work. Compare the same fixture, Chrome build, and host before and after a change.

The suite covers Now, Agents, Settings, hidden settings, project detail/edit/workspace/diff, agent create/conversation/summary/PR/attachment/edit/clone/archive/loop, standalone attachment, and schedule create/edit/message routes. `--archive` adds the copied archived-agent conversation as a final route.
