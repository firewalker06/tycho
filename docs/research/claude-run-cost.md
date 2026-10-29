# Claude run cost

Card: [#753 - Claude estimation cost is off](https://fizzy.startkit.tech/1/cards/753).

## Verified documentation

[Claude cost tracking](https://code.claude.com/docs/en/agent-sdk/cost-tracking#accumulate-costs-across-multiple-calls) states that Claude Code v2.1.277 and later restore session totals on resume. Earlier versions start each call at zero. Current resumed `total_cost_usd` values must not be added together.

[Cost scope and errors](https://code.claude.com/docs/en/agent-sdk/cost-tracking#get-the-total-cost-of-a-query) explains that total cost includes subagents. Result `usage` excludes them. A crash result can contain a zeroed cost. [Caching guidance](https://code.claude.com/docs/en/agent-sdk/cost-tracking#track-cache-tokens) distinguishes input, cache writes, and cache reads. Repricing the top-level token counts cannot reproduce whole-session spend.

[Claude cost estimates](https://code.claude.com/docs/en/costs#using-the-usage-command) are local estimates. They are not invoices. Installed pricing tables, model recognition, and configured rates affect accuracy.

## Confirmed Tycho fault

Read-only inspection of the archived agent named in the card image found Claude Code v2.1.310/v2.1.311 init events. Its last two result totals were $28.0997596 and $30.201749 in the same native session. The image shows $30.20 on the result and $458.58+ on Summary. Tycho added each restored session total again. It also displayed that accumulated value as the selected run's cost.

The last run's inferred estimate is $2.1019894, subject to consecutive session accounting. The $30.20 result is the session estimate. Neither is an exact bill. No paid Claude call was made for this investigation. Private prompts and transcripts are not copied into fixtures or PR evidence.

## New snapshot behavior

- The parser records the init event's Claude version on each result.
- For v2.1.277 and later, the latest reported total becomes the session estimate. A run estimate uses the difference from a consecutive, compatible snapshot in the same session.
- A missing baseline, missing result, crash-zeroed result, lower total, or unknown session prevents a run estimate. A later valid result can establish a new baseline. An old Tycho accumulated value is never used as that baseline.
- Earlier versions retain per-call cost handling. A compatible wrapper without a version shows **Reported est. cost**, because its scope cannot be verified.
- Summary shows **Run est. cost** for new known-scope snapshots. Old saved snapshots show **Saved est. cost** with the original amount and partial marker. No saved Summary or audit record is rewritten.
- New managed-run metrics use the same run estimate. Cumulative model attribution declares `scope: session`; it is not repriced or treated as run attribution. A historical metrics normalization without a matching run snapshot leaves the cost unpriced.

## Retained proof

`test/fixtures/claude_cost/` contains synthetic structured-output streams with realistic cache and model fields. Three native resumed runs report $1.25, $2.00, and $2.50. Before the fix, Tycho stored $1.25, $3.25, and $5.75. After the fix, the session totals are $1.25, $2.00, and $2.50, and run estimates are $1.25, $0.75, and $0.50.

`test/claude_cost_test.rb` checks parser-to-snapshot behavior, real managed-agent memory capture, reload, metrics, duplicate finalization, retries, gaps, crash results, older versions, and incompatible baselines. The browser fixture checks selected historical runs, cold reload, polling, missing cost, desktop/mobile layout, and preserved saved estimates.

Run from the repository root:

```sh
TYCHO_REMOTE_UI_CLAUDE_COST_ONLY=1 TYCHO_REMOTE_UI_CAPTURE_DIR=/tmp/tycho-claude-cost bin/remote-ui-smoke
```

Scope limit: existing saved estimates and metrics are not repaired. This task adds no live migration or startup transcript scan. Custom wrappers that omit the native version retain their prior accounting behavior with an explicit reported-cost label.
