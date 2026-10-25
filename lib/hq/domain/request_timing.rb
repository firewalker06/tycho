# frozen_string_literal: true

module HQ
  # Per-request stage timing for the Remote server. Each request runs on its own
  # thread, so the active timing lives in a thread variable and no lock is
  # needed. Stages report exclusive time: when stages nest, the inner stage is
  # not counted again in the outer one. Outside a request every call is a no-op.
  class RequestTiming
    THREAD_KEY = :tycho_remote_request_timing

    def self.start
      timing = new
      Thread.current.thread_variable_set(THREAD_KEY, timing)
      timing
    end

    def self.current
      Thread.current.thread_variable_get(THREAD_KEY)
    end

    def self.clear
      Thread.current.thread_variable_set(THREAD_KEY, nil)
    end

    def self.measure(stage, &block)
      timing = current
      timing ? timing.measure(stage, &block) : yield
    end

    def initialize
      @started_at = now
      @durations = Hash.new(0.0)
      @open = []
    end

    def measure(stage)
      enter(stage)
      yield
    ensure
      leave
    end

    def total_ms
      (now - @started_at) * 1000
    end

    # Exclusive stage durations in milliseconds, in first-use order.
    def stages_ms
      @durations.transform_values { |seconds| seconds * 1000 }
    end

    def server_timing_header
      metrics = stages_ms.map { |stage, ms| "#{stage};dur=#{ms.round(1)}" }
      metrics << "total;dur=#{total_ms.round(1)}"
      metrics.join(", ")
    end

    def stage_summary
      stages_ms.map { |stage, ms| "#{stage}=#{ms.round(1)}ms" }.join(" ")
    end

    private

    def enter(stage)
      current = now
      pause_parent(current)
      @open << [stage.to_s, current]
    end

    def leave
      stage, since = @open.pop
      return unless stage

      current = now
      @durations[stage] += current - since
      @open.last[1] = current if @open.any?
    end

    def pause_parent(current)
      parent = @open.last
      return unless parent

      @durations[parent[0]] += current - parent[1]
    end

    def now
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
  end
end
