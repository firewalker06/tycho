# Interaction Profiler

The **Interaction Profiler** is an optional verification process for adding or changing a UI interaction. It runs a chosen sequence of actions, measures the time to an expected state, and saves an HTML report with screenshots. The screenshots provide evidence of the visible states.

Run it when you need evidence for an interaction change, such as immediate button feedback, a panel opening, or a form state change. It is not a compulsory test for every change or CI run. Profiler runs and the Chrome smoke check are outside `bin/test`, normal CI, and the required local CI signoff. Lightweight configuration and report-code checks remain in the normal suite. Those checks do not launch Chrome or profile a feature.

## Tools and setup

Run commands from the repository root. The runner is `bin/remote-ui-interaction-report`. It needs Node.js, Google Chrome, and Playwright. Use the [profiler reference](REMOTE_UI_INTERACTION_PROBE.md) for installation, all configuration fields, authentication, and the Console probe.

The existing [route performance profiler](REMOTE_UI_PROFILING.md) measures page loading across Remote UI routes. Use the Interaction Profiler to measure a selected action and its expected state.

## Verification process

### 1. Define the interaction

Write down the initial state, user action, expected result, and time limit before the run. For example:

| Item | Schedule example |
| --- | --- |
| Initial state | The schedule shows Resume. |
| Action | Click Resume once. |
| Expected state | The same control shows Pause. |
| Timing limit | 100 ms for this diagnostic check. |
| Screenshot area | The selected schedule row. |

Choose a limit for the feature under review. The runner's 100 ms default is a diagnostic value, not a global product requirement or CI gate.

### 2. Prepare the target

Use a local fixture for feature development and repeated runs. For a temporary Tycho server, prepare separate configuration, system prompts, schedules, home, and logs. Set `TYCHO_CONFIG_PATH`, `TYCHO_SYSTEM_PROMPTS_PATH`, `TYCHO_SCHEDULES_PATH`, `TYCHO_HOME`, and `TYCHO_LOGS_ROOT` to those temporary paths before starting `bin/tycho serve` on a spare localhost port.

Prepare the initial state before each run. Actions stay in effect after a run; the profiler does not restore the fixture. For example, a Resume measurement leaves its schedule resumed. Reset the fixture before another sample. Use a live target only when the intended action is authorized.

### 3. Create the scenario

Copy the [schedule example](../config/interaction-tests/schedule-resume.json) to a file for the feature:

```sh
cp config/interaction-tests/schedule-resume.json /path/to/temp/interaction-scenario.json
```

Edit the URL and steps. Supported actions are `open`, `click`, `fill`, `expand`, `wait`, and `measure`. Preparation actions establish the initial state. A `measure` step defines its trigger click and expectation together, so the probe starts before the click and can capture synchronous changes.

For a page with panel controls, a measurement can be:

```json
{
  "action": "measure",
  "name": "Panel becomes visible",
  "trigger": { "action": "click", "selector": "#show-panel" },
  "expect": { "selector": "#panel", "visible": true },
  "screenshot": "#panel-container",
  "withinMs": 100
}
```

Replace these selectors with selectors from the target page. Expectations can check exact text, visibility, or an attribute. Use a unique selector for each control and target. The screenshot container must remain visible before and after the action. The expectation must be false before the measured click. See the [JSON format](REMOTE_UI_INTERACTION_PROBE.md) for a complete scenario and condition rules.

### 4. Run the profile

Set `TYCHO_PLAYWRIGHT_PATH` if Playwright is outside the local module path. If the target requires authentication, set `TYCHO_REMOTE_TOKEN` in the shell. Keep tokens out of scenario files, URLs, and command arguments.

```sh
bin/remote-ui-interaction-report \
  --config /path/to/temp/interaction-scenario.json \
  --output /path/to/temp/interaction-report.html
```

Add `--headed` to show Chrome. The runner uses a fresh browser context. It writes one HTML file with a step log and a separate section for each measurement. Each section includes timing data, completed request timings, and three embedded screenshots: before the trigger, after the trigger, and at the final state or timeout.

| Exit code | Meaning |
| --- | --- |
| `0` | Every measurement met its limit. |
| `1` | A measurement failed or was late; the report was saved. Later actions were skipped. |
| `2` | Configuration, setup, or execution failed. An execution error saves a partial report when possible. |

If an error occurs after a click, inspect the target before retrying. The action may have completed.

### 5. Review the evidence

Open the HTML report locally. Confirm that the expected state appeared, the time met the chosen limit, and the screenshots show the intended interaction. Check timeout and failure scenarios when the feature has those paths. A failed measurement stops later actions; split independent cases into separate scenarios when needed.

The measured time ends at the first observed DOM state. A frame callback is not proof that pixels reached the display. Screenshot capture adds overhead, and an after-trigger screenshot can already show the final state. Completed request timings can include polling and do not establish the cause of a UI delay. Navigation to a new document is not a supported measurement trigger.

Use repeated samples to assess repeatability. For a before/after comparison, use the same scenario, fixture state, Chrome version, and viewport. Restore the fixture between samples and keep reports for both versions. Compare results only when the expected state and fixture are the same.

### 6. Keep the result with the feature review

Keep the scenario JSON and HTML report with the verification notes or PR evidence. State the initial condition, expectation, timing limit, result, and relevant limits. Reports embed their screenshots and can be read offline. Review screenshot content and target values before sharing; a screenshot can show a filled value.

The profiling result supports the feature review. It does not replace regression tests or change the required [local CI signoff](LOCAL_CI.md).

## Inquiry Dismiss fixture

Run `bin/remote-ui-inquiry-dismiss-fixture` from the repository root. It creates a
fresh temporary Tycho home, config, schedules, logs, workspace, and 600 synthetic
inquiry agents. It clears inherited managed-run variables and server credentials,
then runs `tycho serve` in the foreground on a free localhost port. No harness is
started. Stop that server with Ctrl-C; its temporary files remain for inspection.

Copy the printed profile command to a second terminal. The generated config is a
copy of `config/interaction-tests/inquiry-dismiss.json` with the actual fixture
port. The committed URL is an example; use the generated config, not that URL.
Set `TYCHO_PLAYWRIGHT_PATH` if Playwright is outside the local module path.

The initial state is agent `web-inquiry-0` with a visible inquiry and an open
actions menu. The measured action clicks **Dismiss inquiry**. The expected state
is that the inquiry form is hidden. The 1500 ms diagnostic limit allows the
remaining background fleet-poll lock wait at 600 agents, including cold startup;
it is not a 100 ms responsiveness claim or a CI timing gate. Use the regression
tests to detect fleet polling on the lifecycle request itself.

Before each repeat, open the printed fixture URL and use **Restore inquiry**.
Alternatively, stop the server and start a fresh fixture. Use the same viewport,
fleet size, cache condition, and background work for before/after comparisons.
For a stale-cache sample, replace or touch only this fixture's
`logs/managed_agents.json` immediately before dispatching the measured POST.
Record this extra preparation with the results. Keep all screenshots and reports
outside the repository.

## Check the profiler itself

Run the optional Chrome smoke check when changing the profiler or checking its setup:

```sh
TYCHO_REMOTE_UI_CAPTURE_DIR=/path/to/temp/tycho-interaction-profiler-check \
  node test/browser/interaction_report_smoke.js
```

It starts a temporary local page, checks the supported actions and failure cases, and saves sample reports. It does not use real Tycho schedules. This command is separate from verification of a feature and is also optional in CI.
