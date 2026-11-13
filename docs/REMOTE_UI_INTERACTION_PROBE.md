# Interaction Profiler reference

The **Interaction Profiler** provides optional verification when adding or changing an interaction. Read the [verification process](REMOTE_UI_INTERACTION_PROFILER.md) for when to use it, how to review evidence, and what to keep with a feature review. Profiler runs and the Chrome smoke check are not compulsory CI tests. This page describes the commands, configuration, and timing limits.

## Configure the interaction

Use a JSON file to define the page, actions, expected state, screenshot area, and timing limit. Run it from the repository root:

```sh
bin/remote-ui-interaction-report \
  --config config/interaction-tests/schedule-resume.json \
  --output path/to/temp/tycho-schedule-report.html
```

The checked-in example uses a loopback URL and a synthetic schedule key, `smoke`. Start your own temporary fixture server, then set its URL and schedule selectors before you run the example. The example does not start a server. The schedule must show Resume. Actions change application state and are not undone.

For a page with your own controls, the structure is:

```json
{
  "name": "Open a panel",
  "url": "http://127.0.0.1:8080/",
  "timeoutMs": 30000,
  "steps": [
    { "action": "open", "url": "/" },
    { "action": "click", "selector": "#prepare" },
    {
      "action": "measure",
      "name": "Panel becomes visible",
      "trigger": { "action": "click", "selector": "#show-panel" },
      "expect": { "selector": "#panel", "visible": true },
      "screenshot": "#panel-container",
      "withinMs": 100
    }
  ]
}
```

Replace the example selectors with CSS selectors from your page. The preparation click is not timed. A `measure` step arms the probe, then clicks its trigger and waits for its expectation. This order captures synchronous changes. A separate click followed by a measurement could miss the change.

| Action | Fields | Behavior |
| --- | --- | --- |
| `open` | `url` | Navigate to a full URL or a path on the configured origin. Fragments are allowed; query strings and embedded credentials are rejected. |
| `click` | `selector`, optional `text` | Click one visible control. Optional text must match its trimmed text before the click. |
| `fill` | `selector`, `value` | Fill one visible input. Do not store secrets in scenario files. |
| `expand` | `selector` | Open one HTML `details` element if it is closed. |
| `wait` | `expect` | Wait for a state before the next step. This is not a timing measurement. |
| `measure` | `name`, `trigger`, `expect`, `screenshot`, optional `withinMs` and `timeoutMs` | Measure from the trigger click to the first expected state. Save three screenshots. |

An expectation needs a `selector` and exactly one condition:

```json
{ "selector": "#status", "text": "Done" }
{ "selector": "#panel", "visible": true }
{ "selector": "#panel", "visible": false }
{ "selector": "#form", "attribute": { "name": "aria-busy", "value": "false" } }
```

Text comparison is exact after trimming the element's `textContent`. Visibility uses layout boxes and computed visibility; it does not test occlusion or opacity. `visible: false` also accepts a removed element. An attribute value of `null` means the attribute must be absent on an existing element.

The trigger can differ from the expected element. The expected element can appear after the click or be replaced during rendering. A measurement rejects an expectation that is already true. It also rejects ambiguous selectors. `screenshot` must select one visible container that stays present before and after the action. A hidden or removed target can use its parent container for screenshots.

Measurements observe one document. Use `open` for navigation; a trigger that reloads the document is not a supported timing measurement. Multiple `measure` steps produce separate report sections. A failed or late measurement stops later actions. An execution error saves the report sections and images captured so far when report writing is possible. Unsupported actions and configuration fields are rejected before Chrome starts.

`withinMs` defaults to 100. A measurement can override the scenario timeout with `timeoutMs`. Timeouts must be 100–120000 ms and the timing limit must be below the timeout. The original `--url URL --schedule KEY` command remains available. Do not mix those options with `--config`.

## Check the configurable runner

The configuration and report checks run in `bin/test` through `test/remote_ui_interaction_report_test.rb`.

Run the optional Chrome checks with the Playwright module configured as described below:

```sh
TYCHO_REMOTE_UI_CAPTURE_DIR=path/to/temp/tycho-configured-interaction-check \
  node test/browser/interaction_report_smoke.js
```

The browser check starts a temporary local page. It checks all six actions, multiple measurements, separate trigger and target elements, synchronous replacement, new and removed elements, attribute changes, timeout, late completion, duplicate selectors, text guards, and an already satisfied expectation. It also checks embedded images and desktop/mobile report width. It saves a sample HTML report and preview. It does not use real Tycho schedules.

## Generate an HTML report

Run `bin/remote-ui-interaction-report` from the repository root. With `--config`, it executes your scenario. With `--url` and `--schedule`, it opens Schedules and clicks the selected Resume control once. It saves one HTML file with timings and three embedded PNG screenshots per measurement. It works offline after capture.

Install the tested Playwright version outside the repository if needed. Google Chrome and Node.js must be installed.

```sh
npm install --prefix path/to/temp/tycho-interaction-tools --no-audit --no-fund playwright@1.64.1
export TYCHO_PLAYWRIGHT_PATH=path/to/temp/tycho-interaction-tools/node_modules/playwright
```

Set `TYCHO_REMOTE_TOKEN` in the shell before the command if the server needs a token. Do not put the token in the URL or command arguments. The script uses a new browser context and removes it when Chrome closes. It does not read the Tycho credential store.

```sh
bin/remote-ui-interaction-report \
  --url http://127.0.0.1:7373/ \
  --schedule smoke \
  --output path/to/temp/tycho-schedule-report.html
```

The selected schedule must show Resume. If it already shows Pause, the script stops without clicking. The first live measurement below left this schedule resumed, so select a schedule that currently shows Resume for a new measurement. A successful click leaves the schedule resumed. Use a temporary server for repeated checks.

Use `--headed` to show Chrome, `--timeout-ms 60000` to extend the label timeout, or `--immediate-ms 100` to set the pass limit. `CHROME_PATH` can select a Chrome executable. Run `bin/remote-ui-interaction-report --help` for all options.

Exit codes: `0` means every measurement met its limit; `1` means a measurement failed or was late and a report was saved; `2` means configuration, setup, or execution failed. Execution errors save a partial report when possible. If capture fails after a click, check the target before retrying. Screenshots can add overhead. Their captions describe when they were requested; they are not exact frames from the recorded DOM event.

Reports exclude authentication tokens, headers, request bodies, and URL query strings. They include the configured name, server URL, step outcomes, expected target values, and selected screenshot content. Fill values and the full configuration are not copied into the report text. A screenshot can still show a filled value. Review selected content before sharing. The output file has mode `0600`.

The report script was checked against a temporary Tycho server with separate config, schedules, home, and logs. Chrome loaded all three embedded screenshots, and the report had no horizontal overflow at desktop or mobile widths. Pass, late-label, and blocked-request timeout reports were checked, including token authentication without token output. The saved fixture report is separate from the first live measurement below.

The configurable runner has focused configuration checks and a separate optional Chrome check. The sample browser reports use a local fixture; they do not replace the live measurement below.

The full `bin/test` suite passed on retry. The first attempt stopped with `Errno::ENOTEMPTY` during temporary-directory cleanup in `test/managed_agent_test.rb`. The retry passed that test and the new configuration checks.

## Use the Console probe

Load `bin/remote-ui-interaction-probe.js` in Chrome DevTools as a Snippet, or paste its contents into the Console. The script installs `window.tychoInteractionProbe`. It does not click controls or change application data. Reloading the page removes it.

Open the Schedules page. Inspect the desired Resume button to get its schedule key. Arm the probe with a selector that matches one control and stays valid when its action changes:

```js
tychoInteractionProbe.arm({
  selector: '.schedule-toggle-button[data-schedule-key="secondbrain-memory-reconciliation"]',
  expectedText: "Pause",
  immediateMs: 100,
  timeoutMs: 30000
});
```

Click Resume once. Then read the result:

```js
tychoInteractionProbe.read();
// Optional: stop before the observation period ends.
tychoInteractionProbe.stop();
```

`labelMs` measures from the captured click event to the first DOM observation of the expected text. `frameMs` records the next animation frame callback; it does not prove that pixels reached the display. The default immediate limit is 100 ms. This is a diagnostic threshold, not a product specification. The probe also records later label changes until the timeout, so a label rollback is visible in `events`.

The probe works when a render replaces the control. A selector must not include the old action, such as `[data-schedule-action="resume"]`. Each new `arm` stops the previous observation. `read` returns a copy. An unchanged label produces `outcome: "timeout"`.

Completed Fetch/XHR resource entries include start time, duration, and status when Chrome exposes it. Paths keep only the first segment; later segments become `:segment`. The probe does not read headers, bodies, storage, tokens, or query strings. Do not use it on a control whose text contains private data. Concurrent polling can appear in the request list. Resource timing alone does not establish which request caused a render. Requests still in flight at stop are absent.

## First live measurement

At [Tycho on MacBook Pro](https://macbookpro-gi041.tail952bf7.ts.net/), open Schedules and click Resume for **Daily Memory Reconciliation and Synthesis**.

| Event | Time after click |
| --- | ---: |
| Resume label captured | 0 ms |
| Schedule action request started | 0.6 ms |
| Schedule action request ended, HTTP 200 | 10,612.2 ms |
| Schedules read started | 10,624.1 ms |
| Schedules read ended, HTTP 200 | 10,932.1 ms |
| Setup read ended, HTTP 200 | 12,577.7 ms |
| First Pause label observed | 12,588.2 ms |
| Next animation frame callback | 12,589.1 ms |

The immediate expectation failed: the label took 12.59 seconds. It changed about 1.98 seconds after the action response. This is one sample. It does not isolate server processing time from network time. The schedule was left resumed, as requested. The application behavior was not changed.

The redacted timing data is saved in [schedule resume timing](research/schedule-resume-timing.json).

The current checkout's `runScheduleAction` waits for `apiPost` inside `mutate`. It does not change the label before that response. This agrees with the observed delay, but it does not establish the deployed source revision or explain all server latency.

Chrome checks on an isolated blank page passed for immediate label replacement, timeout with no label change, and rejection of a selector that matches more than one control.

`node --check bin/remote-ui-interaction-probe.js`, `git diff --check`, and the full `bin/test` suite passed.

Next: measure repeated samples in a safe fixture, then separate immediate label updates from server confirmation and test rollback on failure.
