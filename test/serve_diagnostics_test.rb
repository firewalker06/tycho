# frozen_string_literal: true

require_relative "support/push_safety"
require_relative "../lib/hq/domain/request_timing"
require_relative "../lib/hq/domain/serve_diagnostics"

diagnostics = HQ::ServeDiagnostics.new
request = Struct.new(:method, :path).new("SECRET", "/private-token/prompt")
timing = HQ::RequestTiming.new
timing.record("store_lock_wait", 123)
timing.record("store_lock_hold", 456)
timing.response_bytes = 789
4.times.map do
  Thread.new do
    300.times do
      diagnostics.accept
      diagnostics.reject_connection
      diagnostics.record(request, timing)
    end
  end
end.each(&:join)
snapshot = diagnostics.snapshot
raise "counts" unless snapshot[:accepted_sockets] == 1200 && snapshot[:rejected_connections] == 1200 && snapshot[:samples].size == 1024
raise "labels" unless snapshot[:samples].all? { |sample| sample[:route] == "OTHER /other" }
raise "measurements" unless snapshot[:samples].first.values_at(:store_lock_wait_ms, :store_lock_hold_ms, :response_bytes) == [123, 456, 789]
snapshot[:samples].first[:route] = "changed"
raise "snapshot mutation" if diagnostics.snapshot[:samples].first[:route] == "changed"
puts "serve_diagnostics_test: ok"
