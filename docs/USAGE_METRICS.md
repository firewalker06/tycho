---
name: USAGE_METRICS
description: Normalized managed-run and native-session usage metrics
type: reference
---

# Usage metrics

Tycho writes one normalized record when a managed run finalizes. The public entry point is `HQ::UsageMetrics`; callers do not parse raw harness logs or inspect active and archived agent trees themselves.

## Storage and identity

The owner-readable store is `~/.tycho/logs/usage_metrics.json`. Its root schema is versioned:

```json
{
  "schema_version": 1,
  "generated_at": "2026-08-08T00:00:00.000000Z",
  "runs": { "<stable-run-id>": {} },
  "sessions": { "<provider-scoped-session-key>": {} },
  "recovery": { "discarded_run_count": 0, "warnings": [] }
}
```

New runs persist a UUID in the managed-agent manifest. Legacy runs use a deterministic v1 identity derived from the durable agent identity, start time, log offset, and a hashed source reference. Upserts replace the same identity and rebuild affected derived values, so finalization, retrying a backfill, or resuming a native session cannot duplicate a run.

Each run keeps project/group/agent attribution, exact harness plus adapter, configured model, observed models, per-model attribution, native session ID when reported, UTC start/finish, duration, status, token counters, estimated cost, price source/version, completeness, inference, unknown reasons, and sanitized provenance hashes. Provenance never stores prompts, credentials, tool inputs, tool outputs, or raw paths. Query output follows the same rule.

Writes take an exclusive file lock and use a mode-`0600`, fsynced atomic rename with a backup. Reads take a shared lock. Schema 0 records migrate to schema 1 in memory; unsupported future versions fail explicitly. If the primary JSON is truncated, Tycho reads the last atomic backup and reports recovery. Invalid records inside an otherwise valid document are discarded and counted rather than silently converted.

## Provider and cost semantics

Codex `turn.completed.usage` is cumulative inside a native session. Tycho stores the raw cumulative counters, sorts runs by stable start/identity, and derives each run from the preceding snapshot. A missing baseline, incomplete snapshot, decreasing counter, or trimmed manifest history makes that run's token delta and price unknown; Tycho does not clamp or substitute zero.

Claude-compatible `result` events are per-run. Tycho stores `total_cost_usd`, usage counters, and every exact `modelUsage` entry independently of the configured model. A session may therefore retain a configured alias and multiple observed models. OpenCode step costs are summed per run.

All stored monetary values use `semantics: estimate_not_invoice`. Harness-reported costs remain harness estimates. Codex uses the versioned OpenAI list-price table in `OpenAIModelPricing`. Missing models, prices, token counters, session IDs, or telemetry remain `null` with a reason. `known_estimated_cost_usd` sums priced runs, while median and maximum session cost include sessions only when every run has a known cost. Missing non-cost metadata does not hide an otherwise fully priced session.

## Query and backfill

Query a local or configured remote Tycho server:

```bash
tycho metrics query \
  --from 2026-07-06 \
  --to 2026-08-07 \
  --timezone Asia/Jakarta \
  --project tycho \
  --harness codex,claude \
  --json

tycho metrics query --server vps --from 2026-07-06 --to 2026-08-07 --timezone UTC
```

`from` is inclusive and `to` is exclusive. Offset-free dates/times require the named IANA timezone; values with `Z` or an explicit numeric offset are absolute. Filters accept comma-separated values for group, project, agent, harness, configured/observed model, and status.

The Remote API equivalents are `GET /metrics` with the same query parameters and `POST /metrics/backfill`.

Backfill is best effort and idempotent:

```bash
tycho metrics backfill --timezone Asia/Jakarta --json
tycho metrics backfill --durable-only --json
```

Backfill reads active and archived manifests first. Legacy raw telemetry is an optional fallback and requires an explicit timezone for offset-free historical headers. It preserves exact emitted IDs/models/prices, labels fields inferred from deterministic filenames or event shapes, assigns a stable anonymous identity when no agent manifest exists, and never guesses a model, price, or session ID. Repeating the command should report every prior record as unchanged.

## Archive and recovery

Agent and project archive operations keep global metrics in place and mark matching records `archived: true`, so active and archived runs use one query path and totals do not move. Each agent archive also receives `agent_manifest.json` and a v1 `usage_metrics.json` snapshot beside its logs. The manifest preserves the exact harness/model/run attribution present at archive time.

If a write is interrupted, rerun the query and inspect the top-level `recovery` object. A backup-recovery warning means the last atomic primary was invalid; rerun `metrics backfill` to restore any missing finalized records. For an unsupported schema version, preserve the primary and backup, upgrade Tycho, and do not hand-edit unknown monetary or model fields into place.
