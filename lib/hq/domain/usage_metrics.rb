# frozen_string_literal: true

require_relative "usage_metrics/store"
require_relative "usage_metrics/normalizer"
require_relative "usage_metrics/query"

module HQ
  module UsageMetrics
    module_function

    def store(path: USAGE_METRICS_FILE, lock_path: nil)
      Store.new(path:, lock_path:)
    end

    def record_run(agent:, run:, usage_entries:, source: "managed_run_finalization", inference: {})
      record = Normalizer.new(agent:, run:, usage_entries:, source:, inference:).record
      store.upsert(record)
      record
    end

    def query(filters = {}, metrics_store: store)
      Query.new(metrics_store:).call(filters)
    end

    def backfill(options = {}, metrics_store: store)
      require_relative "usage_metrics/backfill"
      Backfill.new(metrics_store:).call(options)
    end
  end
end
