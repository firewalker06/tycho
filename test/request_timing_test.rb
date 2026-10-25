# frozen_string_literal: true

require_relative "support/push_safety"

require_relative "../lib/hq/domain/request_timing"

module RequestTimingTest
  module_function

  def run!
    assert_measure_is_a_no_op_outside_a_request
    assert_nested_stages_report_exclusive_time
    assert_repeated_stages_accumulate
    assert_stage_is_recorded_when_the_block_raises
    assert_header_lists_stages_and_total
    assert_parallel_requests_keep_separate_timings
    puts "request_timing_test: ok"
  end

  def assert_measure_is_a_no_op_outside_a_request
    HQ::RequestTiming.clear
    assert(HQ::RequestTiming.current.nil?, "expected no active timing")
    assert(HQ::RequestTiming.measure("agent_load") { :value } == :value, "expected the block value to pass through")
  end

  def assert_nested_stages_report_exclusive_time
    timing = HQ::RequestTiming.start
    HQ::RequestTiming.measure("block_build") do
      sleep 0.05
      HQ::RequestTiming.measure("agent_load") { sleep 0.1 }
      sleep 0.05
    end
    stages = timing.stages_ms
    assert(stages["agent_load"].between?(90, 160), "expected agent_load near 100ms, got #{stages["agent_load"]}")
    assert(stages["block_build"].between?(90, 160), "expected block_build near 100ms, got #{stages["block_build"]}")
    assert(timing.total_ms >= stages.values.sum - 1, "expected total to cover every stage")
  ensure
    HQ::RequestTiming.clear
  end

  def assert_repeated_stages_accumulate
    timing = HQ::RequestTiming.start
    2.times { HQ::RequestTiming.measure("agent_load") { sleep 0.03 } }
    assert(timing.stages_ms["agent_load"] >= 55, "expected repeated stage calls to add up")
    assert(timing.stages_ms.keys == ["agent_load"], "expected a single agent_load entry")
  ensure
    HQ::RequestTiming.clear
  end

  def assert_stage_is_recorded_when_the_block_raises
    timing = HQ::RequestTiming.start
    begin
      HQ::RequestTiming.measure("json_encode") { raise ArgumentError, "boom" }
    rescue ArgumentError
      nil
    end
    HQ::RequestTiming.measure("agent_load") { nil }
    assert(timing.stages_ms.key?("json_encode"), "expected the failing stage to be recorded")
    assert(timing.stages_ms.key?("agent_load"), "expected later stages to work after a raise")
  ensure
    HQ::RequestTiming.clear
  end

  def assert_header_lists_stages_and_total
    timing = HQ::RequestTiming.start
    HQ::RequestTiming.measure("agent_load") { nil }
    HQ::RequestTiming.measure("json_encode") { nil }
    header = timing.server_timing_header
    pattern = /\Aagent_load;dur=\d+(\.\d+)?, json_encode;dur=\d+(\.\d+)?, total;dur=\d+(\.\d+)?\z/
    assert(header.match?(pattern), "unexpected Server-Timing header: #{header}")
    assert(timing.stage_summary.match?(/\Aagent_load=\d+(\.\d+)?ms json_encode=\d+(\.\d+)?ms\z/),
           "unexpected stage summary: #{timing.stage_summary}")
  ensure
    HQ::RequestTiming.clear
  end

  def assert_parallel_requests_keep_separate_timings
    results = Queue.new
    threads = [["agent_load", 0.08], ["block_build", 0.01]].map do |stage, delay|
      Thread.new do
        timing = HQ::RequestTiming.start
        HQ::RequestTiming.measure(stage) { sleep delay }
        results << [stage, timing.stages_ms.keys, timing.stages_ms[stage]]
        HQ::RequestTiming.clear
      end
    end
    threads.each(&:join)
    2.times do
      stage, keys, ms = results.pop
      assert(keys == [stage], "expected #{stage} request to see only its own stage, got #{keys}")
      assert(ms >= (stage == "agent_load" ? 70 : 8), "expected #{stage} duration to be its own, got #{ms}")
    end
  end

  def assert(condition, message)
    raise message unless condition
  end
end

RequestTimingTest.run! if $PROGRAM_NAME == __FILE__
