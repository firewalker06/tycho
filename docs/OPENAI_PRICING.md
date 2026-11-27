# OpenAI pricing verification for card 926

Verified on 2026-11-27. This is the effective date of the added local rate
records, not a claim about the provider's release date. The public IDs and
Standard short-context USD rates per million tokens are:

| Public model and source | Input | Cached input | Output | 30-minute write | 12-hour write |
| --- | ---: | ---: | ---: | ---: | ---: |
| [gpt-6.2-sol](https://developers.openai.com/api/docs/models/gpt-6.2-sol) | 2.00 | 0.10 | 10.00 | 2.50 | 5.00 |
| [gpt-6.2-astra](https://developers.openai.com/api/docs/models/gpt-6.2-astra) | 8.00 | 0.40 | 40.00 | 10.00 | 20.00 |
| [gpt-6.1-terra](https://developers.openai.com/api/docs/models/gpt-6.1-terra) | 1.00 | 0.05 | 5.00 | 1.25 | 2.50 |

Each model page confirms its public ID. The catalog check found Terra in
addition to the two requested GPT-6.2 models. The GPT-6.1 Astra model URL
returned HTTP 404. No rate is inferred for it, `gpt-reserve`, private models,
or unverified spellings such as `gpt-6.2`.

## Tier selection

The [OpenAI pricing page](https://developers.openai.com/api/docs/pricing)
and the model pages give these factors:

- Batch: 0.5 times Standard for the three new models.
- Fast (`fast` or API `priority`): 2 times Standard.
- Flex: 0.5 times Standard for Terra. GPT-6.2 has no listed Flex rate.
- GPT-6.2 Ultrafast: 3 times Standard through 2027-02-28, then 6 times
  Standard from 2027-03-01 Pacific time. Selection uses the run finish time;
  the boundary is 2027-03-01 at 08:00 UTC. Without that time it stays unpriced.

Explicit `service_tier` and `prompt_cache_retention` values survive Codex
parser and native metrics ingestion. Values can be on the event or in its
usage object; the event value takes precedence. The estimator uses the
reported tier for the run's token delta. This requires one tier and retention
policy for that delta; aggregate usage cannot split mixed-tier requests.
An absent tier, `default`, or `auto` uses Standard. The saved pricing records
state the assumption when the tier is absent or automatic. An absent cache
retention uses 30 minutes; explicit `12h` doubles the cache-write rate.
Unsupported explicit tiers or retention policies stay unpriced, with a reason.
Nonstandard rates for older models remain unavailable in this local table.

The three models apply higher rates above 272,000 input tokens per request:
2 times input/cache rates and 1.5 times output rates. Aggregate run counters
cannot identify this request boundary. Tycho therefore records its short-context
assumption instead of treating a cumulative count as one request. Regional
uplifts, background-window discounts, and tool fees are also excluded and
recorded as assumptions. These estimates are API list-price equivalents.

## History and checks

The update does not migrate stored agent or run-summary cost snapshots.
A resumed run adds its new delta to the saved amount. Existing rates keep their
original source and verification dates. An explicit memory rebuild retains
its existing backfill behavior; it can calculate costs with the current table.

Tests cover all four token rates, cached and uncached input, cache retention,
qualified and dated IDs, unknown IDs, missing legacy write rates, tier factors,
the Ultrafast date boundary, parser-to-snapshot and parser-to-metrics flow,
resumed deltas, and unchanged prior snapshots. The existing managed-agent tests
also check saved summary snapshots and reload.
