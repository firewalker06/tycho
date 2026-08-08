# frozen_string_literal: true

require "date"
require "time"

module HQ
  module UsageMetrics
    class Query
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
        complete_session_costs = session_rows.filter_map { |session| numeric(session["estimated_cost_usd"]) }.sort
        native_sessions = runs.filter_map { |run| present(run["session_key"]) }.uniq

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
            "average_runs_per_session" => native_sessions.empty? ? nil : runs.length.to_f / native_sessions.length,
            "known_estimated_cost_usd" => priced_runs.empty? ? nil : priced_runs.sum { |run| numeric(run.dig("estimated_cost", "amount_usd")) },
            "median_complete_session_cost_usd" => median(complete_session_costs),
            "max_complete_session_cost_usd" => complete_session_costs.max,
            "priced_run_count" => priced_runs.length,
            "unpriced_run_count" => runs.length - priced_runs.length,
            "priced_run_coverage" => runs.empty? ? nil : priced_runs.length.to_f / runs.length,
            "complete_priced_session_count" => complete_session_costs.length,
            "incomplete_or_unpriced_session_count" => session_rows.length - complete_session_costs.length,
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
            .values.map { |group| summarize_session(group) }.sort_by { |session| session["first_activity_at"] }
      end

      def summarize_session(runs)
        sorted = runs.sort_by { |run| run["started_at"] }
        costs = sorted.filter_map { |run| numeric(run.dig("estimated_cost", "amount_usd")) }
        all_priced = costs.length == sorted.length
        all_complete = sorted.all? { |run| run.dig("completeness", "overall") == "complete" }
        {
          "session_key" => sorted.first["session_key"],
          "native_session_id" => sorted.first["native_session_id"],
          "harness_adapter" => sorted.first["harness_adapter"],
          "first_activity_at" => sorted.first["started_at"],
          "last_activity_at" => sorted.map { |run| run["finished_at"] || run["started_at"] }.max,
          "run_count" => sorted.length,
          "agent_count" => sorted.map { |run| run["agent_key"] }.uniq.length,
          "configured_models" => sorted.filter_map { |run| present(run["configured_model"]) }.uniq.sort,
          "observed_models" => sorted.flat_map { |run| Array(run["observed_models"]) }.uniq.sort,
          "known_estimated_cost_usd" => costs.empty? ? nil : costs.sum,
          "estimated_cost_usd" => all_priced && all_complete ? costs.sum : nil,
          "currency" => costs.empty? ? nil : "USD",
          "pricing_coverage" => if all_priced && all_complete
                                  "complete"
                                elsif all_priced
                                  "priced_incomplete"
                                elsif costs.empty?
                                  "unpriced"
                                else
                                  "partial"
                                end
        }
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

      def numeric(value)
        number = Float(value)
        number if number.finite? && number >= 0
      rescue ArgumentError, TypeError
        nil
      end

      def present(value)
        text = value.to_s.strip
        text unless text.empty?
      end

      def stringify(value)
        value.each_with_object({}) { |(key, entry), result| result[key.to_s] = entry }
      end
    end
  end
end
