# frozen_string_literal: true

require "securerandom"
require "thread"

module HQ
  # A deliberately small server-lifetime executor for FRED action proposals.
  # Durable proposal state is the queue; this thread only wakes, claims, and
  # runs one proposal at a time.
  class PersonalAssistantActionWorker
    DEFAULT_WAIT = 0.25
    DEFAULT_LEASE_SECONDS = 300

    attr_reader :actions, :worker_id

    def initialize(actions:, on_result: nil, logger: HQ.logger, wait: DEFAULT_WAIT, worker_id: nil,
                   lease_seconds: DEFAULT_LEASE_SECONDS)
      @actions = actions
      @worker_id = worker_id.to_s.strip
      @worker_id = "fred-worker-#{SecureRandom.uuid}" if @worker_id.empty?
      @on_result = on_result
      @logger = logger
      @wait = wait.to_f.positive? ? wait.to_f : DEFAULT_WAIT
      @lease_seconds = lease_seconds.to_f.positive? ? lease_seconds.to_f : DEFAULT_LEASE_SECONDS
      @lock = Mutex.new
      @condition = ConditionVariable.new
      @thread = nil
      @stopping = false
      @closed = false
    end

    def start!
      @lock.synchronize do
        return false if @closed || (@thread && @thread.alive?)

        @actions.recover_expired!(worker_id: @worker_id)
        @stopping = false
        @thread = Thread.new { run }
      end
      true
    end

    alias start start!

    def wake!
      @lock.synchronize { @condition.broadcast }
      true
    end

    alias wake wake!

    def shutdown
      thread = @lock.synchronize do
        @stopping = true
        @condition.broadcast
        @thread
      end
      thread.join if thread && thread != Thread.current
      @lock.synchronize do
        @thread = nil if @thread == thread
        @closed = true
      end
      true
    end

    def running?
      @lock.synchronize { @thread&.alive? == true }
    end

    private

    def run
      loop do
        break if stopping?

        begin
          @actions.recover_expired!(worker_id: @worker_id)
          receipt = @actions.process_next!(owner_id: @worker_id, lease_seconds: @lease_seconds)
          if receipt
            notify(receipt)
            next
          end
        rescue StandardError => e
          @logger.warn("PersonalAssistant") { "FRED action worker pass failed: #{e.class} - #{e.message}" }
        end

        @lock.synchronize do
          break if @stopping

          @condition.wait(@lock, @wait)
        end
      end
    rescue StandardError => e
      @logger.error("PersonalAssistant") { "FRED action worker stopped unexpectedly: #{e.class} - #{e.message}" }
    end

    def stopping?
      @lock.synchronize { @stopping }
    end

    def notify(receipt)
      return unless @on_result && receipt.is_a?(Hash)

      @on_result.call(receipt)
    rescue StandardError => e
      @logger.warn("PersonalAssistant") { "Could not record FRED action receipt: #{e.class} - #{e.message}" }
    end
  end
end
