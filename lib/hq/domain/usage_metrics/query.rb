# frozen_string_literal: true

require "date"
require "time"

require_relative "session_aggregate"
require_relative "values"

module HQ
  module UsageMetrics
    class Query
      include Values

      TIMEZONE_MUTEX = Mutex.new
      FILTERS = %w[group project agent harness model status].freeze

      def initialize(metrics_store:)
        @metrics_store = metrics_store
      end

      def call(filters = {})
        options = stringify(filters || {})
        timezone = options.fetch("timezone", "UTC")
        from = parse_boundary(options["from"], timezone:, end_boundary: false)
        to = parse_boundary(options["to"], timezone:, end_boundary: true)
        raise ArgumentError, "--to must be after --from" if from && to && to <= from

        document = @metrics_store.snapshot
        runs = document.fetch("runs").values.select { |run| selected?(run, options, from:, to:) }
        runs.sort_by! { |run| [run["started_at"].to_s, run["run_id"].to_s] }
        session_rows = sessions_for(runs)
        priced_runs = runs.select { |run| !numeric(run.dig("estimated_cost", "amount_usd")).nil? }
        priced_session_costs = session_rows.filter_map { |session| numeric(session["estimated_cost_usd"]) }.sort
        native_sessions = runs.filter_map { |run| present(run["session_key"]) }.uniq
        session_run_count = runs.count { |run| present(run["session_key"]) }

        {
          "schema_version" => document.fetch("schema_version"),
          "query" => {
            "from" => from&.utc&.iso8601(6),
            "to" => to&.utc&.iso8601(6),
            "range_semantics" => "from_inclusive_to_exclusive",
            "timezone" => timezone,
            "filters" => FILTERS.to_h { |key| [key, split_filter(options[key])] }.reject { |_key, value| value.empty? }
          },
          "summary" => {
            "run_starts" => runs.length,
            "managed_agents" => runs.map { |run| run["agent_key"] }.uniq.length,
            "distinct_native_sessions" => native_sessions.length,
            "runs_without_native_session" => runs.count { |run| run["native_session_id"].to_s.empty? },
            "average_runs_per_session" => native_sessions.empty? ? nil : session_run_count.to_f / native_sessions.length,
            "known_estimated_cost_usd" => priced_runs.empty? ? nil : priced_runs.sum { |run| numeric(run.dig("estimated_cost", "amount_usd")) },
            "median_priced_session_cost_usd" => median(priced_session_costs),
            "max_priced_session_cost_usd" => priced_session_costs.max,
            "priced_run_count" => priced_runs.length,
            "unpriced_run_count" => runs.length - priced_runs.length,
            "priced_run_coverage" => runs.empty? ? nil : priced_runs.length.to_f / runs.length,
            "priced_session_count" => priced_session_costs.length,
            "unpriced_or_partially_priced_session_count" => session_rows.length - priced_session_costs.length,
            "cost_semantics" => "estimate_not_invoice"
          },
          "runs" => runs.map { |run| public_run(run) },
          "sessions" => session_rows,
          "recovery" => document["recovery"]
        }
      end

      def self.parse_boundary(value, timezone:, end_boundary: false)
        new(metrics_store: nil).send(:parse_boundary, value, timezone:, end_boundary:)
      end

      private

      def selected?(run, options, from:, to:)
        started = Time.iso8601(run.fetch("started_at"))
        return false if from && started < from
        return false if to && started >= to

        FILTERS.all? do |filter|
          accepted = split_filter(options[filter])
          accepted.empty? || values_for_filter(run, filter).any? { |value| accepted.include?(value) }
        end
      rescue ArgumentError
        false
      end

      def values_for_filter(run, filter)
        values = case filter
                 when "project" then [run["project_key"]]
                 when "agent" then [run["agent_key"]]
                 when "harness" then [run["harness"], run["harness_adapter"]]
                 when "model" then [run["configured_model"], *Array(run["observed_models"])]
                 else [run[filter]]
                 end
        values.filter_map { |value| present(value)&.downcase }.uniq
      end

      def sessions_for(runs)
        runs.reject { |run| run["native_session_id"].to_s.empty? }.group_by { |run| run.fetch("session_key") }
            .values.map { |group| SessionAggregate.build(group) }.sort_by { |session| session["first_activity_at"] }
      end

      def public_run(run)
        run.reject { |key, _value| key == "provenance" }.merge(
          "provenance" => {
            "source" => run.dig("provenance", "source"),
            "event_count" => run.dig("provenance", "event_count"),
            "events" => Array(run.dig("provenance", "events"))
          }.compact
        )
      end

      def parse_boundary(value, timezone:, end_boundary:)
        text = value.to_s.strip
        return nil if text.empty?
        validate_timezone!(timezone)
        return Time.iso8601(text) if text.match?(/[zZ]\z|[+-]\d{2}:?\d{2}\z/)

        parts = Date._parse(text, false)
        raise ArgumentError, "Invalid time boundary #{text.inspect}" unless parts[:year] && parts[:mon] && parts[:mday]

        local_time(timezone) do
          Time.local(parts[:year], parts[:mon], parts[:mday], parts[:hour] || 0, parts[:min] || 0,
                     (parts[:sec] || 0) + Rational(parts[:sec_fraction] || 0))
        end
      rescue Date::Error, ArgumentError => error
        raise ArgumentError, "Invalid #{end_boundary ? "to" : "from"} boundary #{text.inspect}: #{error.message}"
      end

      def validate_timezone!(timezone)
        zone = timezone.to_s
        raise ArgumentError, "Timezone is required" if zone.empty?
        return if %w[UTC Etc/UTC GMT].include?(zone)

        root = "/usr/share/zoneinfo/"
        candidate = File.expand_path(zone, root)
        raise ArgumentError, "Unknown timezone #{zone.inspect}" unless candidate.start_with?(root) && File.file?(candidate)
      end

      def local_time(timezone)
        TIMEZONE_MUTEX.synchronize do
          previous = ENV["TZ"]
          ENV["TZ"] = timezone
          yield
        ensure
          previous.nil? ? ENV.delete("TZ") : ENV["TZ"] = previous
        end
      end

      def split_filter(value)
        Array(value).flat_map { |entry| entry.to_s.split(",") }.map { |entry| entry.strip.downcase }.reject(&:empty?).uniq
      end

      def median(values)
        return nil if values.empty?

        middle = values.length / 2
        values.length.odd? ? values[middle] : (values[middle - 1] + values[middle]) / 2.0
      end

    end
  end
end
