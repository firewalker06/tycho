# frozen_string_literal: true

require "json"
require "tmpdir"

require_relative "../lib/hq/domain/usage_metrics"
require_relative "../lib/hq/domain/managed_agent"
require_relative "../lib/hq/parser"

module UsageMetricsTest
  module_function

  FixtureAgent = Struct.new(
    :key, :project_key, :project_group, :agent, :model, :session_id, :runs,
    keyword_init: true
  )

  def run!
    assert_codex_cumulative_usage_is_normalized_and_idempotent
    assert_managed_run_finalization_persists_once
    assert_claude_model_usage_preserves_mixed_model_attribution
    assert_unknown_ids_models_and_prices_stay_unknown
    assert_retries_resumes_filters_and_report_statistics
    assert_start_failure_is_ingested_immediately
    assert_archive_transition_preserves_metrics_and_manifest
    assert_timezone_boundaries_are_inclusive_exclusive
    assert_backfill_prefers_manifests_and_is_idempotent
    assert_backfill_identity_survives_archive_move
    assert_missing_manifest_telemetry_is_preserved
    assert_trimmed_codex_history_has_unknown_baseline
    assert_schema_migration_and_corruption_recovery
    puts "usage_metrics_test: ok"
  end

  def assert_codex_cumulative_usage_is_normalized_and_idempotent
    with_store do |store|
      segments = fixture_segments("codex_cumulative.jsonl")
      first = run("run-1", 10, session_id: "codex-session-1")
      second = run("run-2", 11, session_id: "codex-session-1")
      agent = agent("codex", "gpt-5.5", [first], session_id: "codex-session-1")

      first_record = normalize(agent, first, usage_entries(segments[0], "codex"))
      agent.runs << second
      second_record = normalize(agent, second, usage_entries(segments[1], "codex"))
      assert(store.upsert(first_record) == :created, "expected first ingestion to create a run")
      assert(store.upsert(second_record) == :created, "expected resumed run ingestion to create a run")
      assert(store.upsert(second_record) == :unchanged, "expected repeated ingestion to be idempotent")

      runs = store.runs.sort_by { |record| record["started_at"] }
      assert(runs[0].dig("tokens", "input_tokens") == 100, "expected first Codex cumulative snapshot as its delta")
      assert(runs[1].dig("tokens", "input_tokens") == 75, "expected resumed Codex input delta")
      assert(runs[1].dig("tokens", "cached_input_tokens") == 50, "expected resumed Codex cached delta")
      assert_close(runs[0].dig("estimated_cost", "amount_usd"), 0.00092)
      assert_close(runs[1].dig("estimated_cost", "amount_usd"), 0.00051)
      assert(runs[1].dig("estimated_cost", "pricing", "version") == HQ::OpenAIModelPricing::PRICE_DATE,
             "expected versioned Codex pricing provenance")
      session = store.sessions.fetch(0)
      assert(session["run_count"] == 2, "expected distinct runs inside one native session")
      assert_close(session["known_estimated_cost_usd"], 0.00143)
      assert_close(session["estimated_cost_usd"], 0.00143)
      assert(session.dig("completeness", "overall") == "partial",
             "expected pricing completeness to remain distinct from missing model metadata")
    end
  end

  def assert_claude_model_usage_preserves_mixed_model_attribution
    with_store do |store|
      current = run("claude-run", 12, session_id: "claude-session-1", model: "configured-alias")
      fixture_agent = agent("claude", "configured-alias", [current], session_id: "claude-session-1")
      record = normalize(fixture_agent, current, usage_entries(fixture("claude_model_usage.jsonl"), "claude"))
      store.upsert(record)

      stored = store.runs.fetch(0)
      assert(stored["configured_model"] == "configured-alias", "expected configured model to remain distinct")
      assert(stored["observed_models"] == %w[claude-haiku-4-5 claude-sonnet-4-5],
             "expected both observed models")
      assert(stored["model_attribution"].map { |item| item["estimated_cost_usd"] }.sum == 1.5,
             "expected modelUsage cost attribution")
      assert(stored.dig("estimated_cost", "pricing", "version").nil? &&
             stored.dig("estimated_cost", "pricing", "version_unknown_reason").include?("did not report"),
             "expected an explicit unknown Claude pricing version")
      assert(store.sessions.fetch(0)["mixed_model"] == true, "expected mixed-model session marker")
    end
  end

  def assert_managed_run_finalization_persists_once
    Dir.mktmpdir("usage-metrics-finalization") do |dir|
      store = HQ::UsageMetrics::Store.new(path: File.join(dir, "metrics.json"))
      started = Time.utc(2026, 7, 6, 9)
      marker = "=== [#{started.strftime("%Y-%m-%d %H:%M:%S")}] start ===\n"
      raw = File.join(dir, "managed.raw.log")
      File.write(raw, marker + fixture("claude_model_usage.jsonl").join("\n") + "\n")
      current = HQ::ManagedAgent::AgentRun.new(
        run_id: "finalized-run", started_at: started, finished_at: started + 60,
        status: "succeeded", session_id: "claude-session-1", agent: "claude",
        model: "configured-model", log_path: raw, log_start_offset: marker.bytesize
      )
      managed = HQ::ManagedAgent.new(
        key: "demo-agent-finalized", name: "Finalized", project_key: "demo", project_group: "work",
        template_key: "custom", workspace: dir, prompt: "prompt", log_path: raw,
        started_at: started, finished_at: started + 60, agent: "claude", model: "configured-model",
        runs: [current]
      )
      managed.usage_metrics_store = store

      managed.send(:capture_run_memory!, current)
      managed.send(:capture_run_memory!, current)
      assert(store.runs.length == 1, "expected repeated finalization capture not to double-count")
      assert(store.runs.fetch(0)["run_id"] == "finalized-run", "expected persisted lifecycle run identity")
    end
  end

  def assert_unknown_ids_models_and_prices_stay_unknown
    with_store do |store|
      current = run("unknown-run", 13, session_id: nil, model: nil)
      fixture_agent = agent("claude", nil, [current])
      record = normalize(fixture_agent, current, usage_entries(fixture("missing_telemetry.jsonl"), "claude"))
      store.upsert(record)
      result = HQ::UsageMetrics::Query.new(metrics_store: store).call
      stored = result.fetch("runs").fetch(0)

      assert(stored["native_session_id"].nil?, "expected absent native ID to remain nil")
      assert(stored["configured_model"].nil?, "expected absent model to remain nil")
      assert(stored.dig("estimated_cost", "amount_usd").nil?, "expected absent price to remain nil")
      assert(result.dig("summary", "known_estimated_cost_usd").nil?, "expected no fabricated zero total")
      assert(result.dig("summary", "unpriced_run_count") == 1, "expected explicit unpriced coverage")
      assert(stored.dig("completeness", "unknown_reasons").any? { |reason| reason.include?("session ID") },
             "expected session unknown reason")
    end
  end

  def assert_retries_resumes_filters_and_report_statistics
    with_store do |store|
      records = [
        priced_record("failed-retry", "session-a", 1.0, status: "failed", harness: "claude", hour: 10),
        priced_record("successful-resume", "session-a", 2.0, status: "succeeded", harness: "claude", hour: 11),
        priced_record("other-session", "session-b", 5.0, status: "succeeded", harness: "claude", hour: 12),
        priced_record("unpriced-session", "session-c", nil, status: "succeeded", harness: "codex", hour: 13),
        priced_record("orphan-run", nil, nil, status: "failed", harness: "claude", hour: 14)
      ]
      records[2]["completeness"] = {
        "overall" => "partial", "unknown_reasons" => ["Observed model was not reported"]
      }
      records.each { |record| store.upsert(record) }
      result = HQ::UsageMetrics::Query.new(metrics_store: store).call(
        "project" => "demo", "group" => "work", "harness" => "claude,codex"
      )

      assert(result.dig("summary", "run_starts") == 5, "expected retry, resume, and orphan as distinct run starts")
      assert(result.dig("summary", "distinct_native_sessions") == 3, "expected three native sessions")
      assert_close(result.dig("summary", "average_runs_per_session"), 4.0 / 3)
      assert_close(result.dig("summary", "known_estimated_cost_usd"), 8.0)
      assert_close(result.dig("summary", "median_priced_session_cost_usd"), 4.0)
      assert_close(result.dig("summary", "max_priced_session_cost_usd"), 5.0)
      assert(result.dig("summary", "priced_run_count") == 3, "expected priced run coverage")
      assert(result.dig("summary", "unpriced_run_count") == 2, "expected unpriced run coverage")

      failed = HQ::UsageMetrics::Query.new(metrics_store: store).call("status" => "failed")
      assert(failed.dig("summary", "run_starts") == 2, "expected status filter")
      model = HQ::UsageMetrics::Query.new(metrics_store: store).call("model" => "observed-model")
      assert(model.dig("summary", "run_starts") == 5, "expected observed-model filter")
    end
  end

  def assert_start_failure_is_ingested_immediately
    Dir.mktmpdir("usage-metrics-start-failure") do |dir|
      store = HQ::UsageMetrics::Store.new(path: File.join(dir, "metrics.json"))
      managed = HQ::ManagedAgent.new(
        key: "demo-agent-launch-failure", name: "Launch failure", project_key: "demo", project_group: "work",
        template_key: "custom", workspace: dir, prompt: "prompt", log_path: File.join(dir, "agent.raw.log"),
        agent: "claude", model: "configured-model"
      )
      managed.usage_metrics_store = store
      managed.send(:record_start_failure!, "executable unavailable", ["missing-command"])

      metric = store.runs.fetch(0)
      assert(metric["status"] == "failed" && !metric["run_id"].to_s.empty?,
             "expected launch failure lifecycle ingestion with a persisted identity")
      assert(metric.dig("estimated_cost", "amount_usd").nil?, "expected launch failure cost to remain unknown")
    end
  end

  def assert_archive_transition_preserves_metrics_and_manifest
    Dir.mktmpdir("usage-metrics-archive") do |dir|
      store = HQ::UsageMetrics::Store.new(path: File.join(dir, "usage_metrics.json"))
      raw = File.join(dir, "agent.raw.log")
      File.write(raw, "telemetry")
      current = run("archive-run", 14, session_id: "archive-session")
      fixture_agent = HQ::ManagedAgent.new(
        key: "demo-agent-archive", name: "Archive", project_key: "demo", project_group: "work",
        template_key: "custom", workspace: dir, prompt: "sensitive prompt", log_path: raw,
        agent: "claude", model: "configured-model", runs: [current]
      )
      fixture_agent.usage_metrics_store = store
      metric = priced_record("archive-run", "archive-session", 2.5, hour: 14)
      metric["agent_key"] = "demo-agent-archive"
      store.upsert(metric)
      before = HQ::UsageMetrics::Query.new(metrics_store: store).call.fetch("summary")
      destination = fixture_agent.archive_logs!(File.join(dir, "archive"))
      after = HQ::UsageMetrics::Query.new(metrics_store: store).call.fetch("summary")

      assert(before == after, "expected archive transition not to change totals")
      assert(store.runs.fetch(0)["archived"] == true, "expected global query path to mark archive state")
      manifest = JSON.parse(File.read(File.join(destination, "agent_manifest.json")))
      snapshot = JSON.parse(File.read(File.join(destination, "usage_metrics.json")))
      assert(manifest["agent"] == "claude", "expected exact harness in archived manifest")
      assert(manifest["model"] == "configured-model", "expected exact model in archived manifest")
      assert(snapshot.fetch("runs").fetch(0).dig("estimated_cost", "amount_usd") == 2.5,
             "expected archived metric snapshot")
      public_metrics = JSON.generate(HQ::UsageMetrics::Query.new(metrics_store: store).call)
      assert(!public_metrics.include?("sensitive prompt") && !public_metrics.include?(dir),
             "expected metric output to exclude prompts and internal paths")
    end
  end

  def assert_timezone_boundaries_are_inclusive_exclusive
    with_store do |store|
      store.upsert(priced_record("at-start", "tz-a", 1.0, hour: 17, day: 5)) # midnight Jakarta on July 6
      store.upsert(priced_record("at-end", "tz-b", 2.0, hour: 17, day: 6))   # midnight Jakarta on July 7
      result = HQ::UsageMetrics::Query.new(metrics_store: store).call(
        "from" => "2026-07-06", "to" => "2026-07-07", "timezone" => "Asia/Jakarta"
      )

      assert(result.dig("summary", "run_starts") == 1, "expected inclusive start and exclusive end")
      assert(result.fetch("runs").fetch(0)["run_id"] == "at-start", "expected Jakarta boundary conversion")
      assert(result.dig("query", "range_semantics") == "from_inclusive_to_exclusive", "expected explicit semantics")
    end
  end

  def assert_schema_migration_and_corruption_recovery
    Dir.mktmpdir("usage-metrics-recovery") do |dir|
      path = File.join(dir, "usage_metrics.json")
      legacy = priced_record("legacy", "legacy-session", 1.0)
      File.write(path, JSON.generate("records" => [legacy]))
      store = HQ::UsageMetrics::Store.new(path: path)
      assert(store.snapshot.fetch("schema_version") == 1, "expected schema migration")
      assert(store.runs.length == 1, "expected migrated record")

      HQ::FileStore.write_json(path, store.snapshot)
      updated = store.snapshot
      updated["generated_at"] = "newer"
      HQ::FileStore.write_json(path, updated)
      File.write(path, "{partial")
      recovered = store.snapshot
      assert(recovered.fetch("runs").length == 1, "expected backup recovery after partial write corruption")
      assert(recovered.dig("recovery", "warnings").any? { |warning| warning.include?("backup") },
             "expected explicit recovery warning")

      partial = recovered.merge("runs" => recovered.fetch("runs").merge("bad" => { "run_id" => "bad" }))
      File.write(path, JSON.generate(partial))
      assert(store.snapshot.dig("recovery", "discarded_run_count") == 1, "expected invalid partial record handling")

      broken_session = priced_record("broken-session", "native-id", 1.0).tap { |record| record.delete("session_key") }
      File.write(path, JSON.generate(recovered.merge("runs" => { "broken-session" => broken_session })))
      structurally_recovered = store.snapshot
      assert(structurally_recovered.fetch("runs").empty? &&
             structurally_recovered.dig("recovery", "discarded_run_count") == 1,
             "expected structurally incomplete session records to be discarded without crashing")
    end
  end

  def assert_backfill_prefers_manifests_and_is_idempotent
    Dir.mktmpdir("usage-metrics-backfill") do |dir|
      path = File.join(dir, "legacy.raw.log")
      marker = "=== [2026-07-06 10:00:00] start ===\n"
      File.write(path, marker + fixture("claude_model_usage.jsonl").join("\n") + "\n")
      current = HQ::ManagedAgent::AgentRun.new(
        run_id: "manifest-run", started_at: Time.new(2026, 7, 6, 10, 0, 0, "+07:00"),
        finished_at: Time.new(2026, 7, 6, 10, 1, 0, "+07:00"), status: "succeeded",
        session_id: "claude-session-1", agent: "claude", model: "configured-exact",
        log_path: path, log_start_offset: marker.bytesize
      )
      fixture_agent = HQ::ManagedAgent.new(
        key: "demo-agent-backfill", name: "Backfill", project_key: "demo", project_group: "work",
        template_key: "custom", workspace: dir, prompt: "prompt", log_path: path,
        agent: "claude", model: "configured-exact", runs: [current]
      )
      store = HQ::UsageMetrics::Store.new(path: File.join(dir, "metrics.json"))
      registry = Struct.new(:projects).new([Struct.new(:key, :group).new("demo", "work")])
      options = {
        "registry" => registry,
        "manifests" => [{ "agent" => fixture_agent, "archived" => false, "directory" => nil }],
        "raw_paths" => [path],
        "timezone" => "Asia/Jakarta"
      }

      first = HQ::UsageMetrics.backfill(options, metrics_store: store)
      second = HQ::UsageMetrics.backfill(options, metrics_store: store)
      assert(first["created"] == 1 && first["raw_fallback_run_count"] == 0,
             "expected the durable manifest to claim its raw segment")
      assert(second["unchanged"] == 1 && store.runs.length == 1, "expected idempotent repeated backfill")
      assert(store.runs.fetch(0)["configured_model"] == "configured-exact",
             "expected durable model provenance to win")
    end
  end

  def assert_backfill_identity_survives_archive_move
    Dir.mktmpdir("usage-metrics-backfill-archive") do |dir|
      active_dir = File.join(dir, "active")
      archive_dir = File.join(dir, "archive", "20260706-100000-demo-agent-backfill")
      FileUtils.mkdir_p(active_dir)
      path = File.join(active_dir, "legacy.raw.log")
      marker = "=== [2026-07-06 10:00:00] start ===\n"
      File.write(path, marker + fixture("claude_model_usage.jsonl").join("\n") + "\n")
      current = HQ::ManagedAgent::AgentRun.new(
        started_at: Time.new(2026, 7, 6, 10, 0, 0, "+07:00"), status: "succeeded",
        session_id: "claude-session-1", agent: "claude", log_path: path, log_start_offset: marker.bytesize
      )
      fixture_agent = HQ::ManagedAgent.new(
        key: "demo-agent-backfill", name: "Backfill", project_key: "demo", project_group: "work",
        template_key: "custom", workspace: dir, prompt: "prompt", log_path: path,
        agent: "claude", model: "configured-exact", runs: [current]
      )
      store = HQ::UsageMetrics::Store.new(path: File.join(dir, "metrics.json"))
      registry = Struct.new(:projects).new([])
      active = { "registry" => registry, "manifests" => [{ "agent" => fixture_agent, "archived" => false }],
                 "raw_paths" => [], "timezone" => "Asia/Jakarta" }
      HQ::UsageMetrics.backfill(active, metrics_store: store)
      FileUtils.mkdir_p(archive_dir)
      FileUtils.mv(path, File.join(archive_dir, File.basename(path)))
      archived = active.merge("manifests" => [{ "agent" => fixture_agent, "archived" => true,
                                                 "directory" => archive_dir }])
      outcome = HQ::UsageMetrics.backfill(archived, metrics_store: store)

      assert(store.runs.length == 1 && outcome["created"].zero?,
             "expected location-independent backfill identity across archive move")
      assert(store.runs.fetch(0)["archived"] == true, "expected the existing metric to transition to archived")
    end
  end

  def assert_missing_manifest_telemetry_is_preserved
    Dir.mktmpdir("usage-metrics-missing-telemetry") do |dir|
      missing = File.join(dir, "missing.raw.log")
      current = HQ::ManagedAgent::AgentRun.new(
        run_id: "missing-log-run", started_at: Time.utc(2026, 7, 6, 10), status: "failed",
        agent: "claude", log_path: missing
      )
      fixture_agent = agent("claude", nil, [current])
      store = HQ::UsageMetrics::Store.new(path: File.join(dir, "metrics.json"))
      options = { "registry" => Struct.new(:projects).new([]),
                  "manifests" => [{ "agent" => fixture_agent, "archived" => false }], "raw_paths" => [] }
      HQ::UsageMetrics.backfill(options, metrics_store: store)

      metric = store.runs.fetch(0)
      assert(metric.dig("completeness", "unknown_reasons").include?("Raw telemetry for the durable run was unavailable"),
             "expected durable run with missing telemetry and an explicit unknown reason")
    end
  end

  def assert_trimmed_codex_history_has_unknown_baseline
    Dir.mktmpdir("usage-metrics-trimmed-codex") do |dir|
      path = File.join(dir, "codex.raw.log")
      marker = "=== [2026-07-06 10:00:00] start ===\n"
      File.write(path, marker + fixture_segments("codex_cumulative.jsonl").first.join("\n") + "\n")
      current = HQ::ManagedAgent::AgentRun.new(
        started_at: Time.new(2026, 7, 6, 10, 0, 0, "+07:00"), status: "succeeded",
        session_id: "codex-session-1", agent: "codex", model: "gpt-5.5",
        log_path: path, log_start_offset: marker.bytesize
      )
      fixture_agent = HQ::ManagedAgent.new(
        key: "demo-agent-codex", name: "Codex", project_key: "demo", project_group: "work",
        template_key: "custom", workspace: dir, prompt: "prompt", log_path: path,
        agent: "codex", model: "gpt-5.5", runs: [current], total_run_count: 2
      )
      store = HQ::UsageMetrics::Store.new(path: File.join(dir, "metrics.json"))
      options = { "registry" => Struct.new(:projects).new([]),
                  "manifests" => [{ "agent" => fixture_agent, "archived" => false }], "raw_paths" => [] }
      HQ::UsageMetrics.backfill(options, metrics_store: store)

      metric = store.runs.fetch(0)
      assert(metric["tokens"].nil? && metric["codex_baseline_known"] == false,
             "expected retained cumulative telemetry not to become a false zero-baseline delta")
    end
  end

  def priced_record(id, session_id, cost, status: "succeeded", harness: "claude", hour: 10, day: 6)
    {
      "schema_version" => 1,
      "run_id" => id,
      "agent_key" => id.start_with?("other") ? "demo-agent-2" : "demo-agent-1",
      "project_key" => "demo",
      "group" => "work",
      "harness" => harness,
      "harness_adapter" => harness,
      "configured_model" => "configured-model",
      "observed_models" => ["observed-model"],
      "model_attribution" => [],
      "native_session_id" => session_id,
      "session_key" => session_id ? "#{harness}:#{session_id}" : nil,
      "started_at" => Time.utc(2026, 7, day, hour).iso8601(6),
      "finished_at" => Time.utc(2026, 7, day, hour, 1).iso8601(6),
      "duration_ms" => 60_000,
      "status" => status,
      "tokens" => { "input_tokens" => 10, "cached_input_tokens" => 0, "output_tokens" => 2 },
      "estimated_cost" => {
        "amount_usd" => cost,
        "currency" => cost.nil? ? nil : "USD",
        "semantics" => "estimate_not_invoice",
        "source" => cost.nil? ? "unpriced" : "claude_reported_estimate",
        "reason_unavailable" => cost.nil? ? "Price unavailable" : nil
      }.compact,
      "completeness" => {
        "overall" => cost.nil? ? "partial" : "complete",
        "unknown_reasons" => cost.nil? ? ["Price unavailable"] : []
      },
      "provenance" => { "source" => "fixture", "event_count" => 0 },
      "archived" => false
    }
  end

  def normalize(fixture_agent, current_run, entries)
    HQ::UsageMetrics::Normalizer.new(
      agent: fixture_agent, run: current_run, usage_entries: entries, source: "fixture"
    ).record
  end

  def agent(harness, model, runs, session_id: nil)
    FixtureAgent.new(
      key: "demo-agent-1", project_key: "demo", project_group: "work", agent: harness,
      model: model, session_id: session_id, runs: runs
    )
  end

  def run(id, hour, session_id:, model: nil)
    HQ::ManagedAgent::AgentRun.new(
      run_id: id,
      started_at: Time.utc(2026, 7, 6, hour),
      finished_at: Time.utc(2026, 7, 6, hour, 1),
      status: "succeeded",
      exit_code: 0,
      session_id: session_id,
      model: model
    )
  end

  def usage_entries(lines, harness)
    _conversation, system = HQ::Parser.parse_stream(lines, agent_type: harness)
    system.select { |entry| entry.type == :usage }
  end

  def fixture_segments(name)
    fixture(name).slice_before { |line| line == "---RUN---" }.map { |lines| lines.reject { |line| line == "---RUN---" } }
  end

  def fixture(name)
    File.readlines(File.join(__dir__, "fixtures", "metrics", name), chomp: true)
  end

  def with_store
    Dir.mktmpdir("usage-metrics") do |dir|
      yield HQ::UsageMetrics::Store.new(path: File.join(dir, "usage_metrics.json"))
    end
  end

  def assert_close(actual, expected)
    assert(!actual.nil? && (actual - expected).abs < 0.000_000_001, "expected #{actual.inspect} to equal #{expected}")
  end

  def assert(condition, message)
    raise message unless condition
  end
end

UsageMetricsTest.run! if $PROGRAM_NAME == __FILE__
