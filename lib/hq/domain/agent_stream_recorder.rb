# frozen_string_literal: true

require "fileutils"
require "json"

require_relative "agent_stream_projector"
require_relative "sleep_circuit_breaker"

module HQ
  class AgentStreamRecorder
    def self.run(command:, raw_log_path:, memory_path:, agent_type:, run_id:, incident_path: nil)
      new(raw_log_path:, memory_path:, agent_type:, run_id:, incident_path:).run(command)
    end

    def initialize(raw_log_path:, memory_path:, agent_type:, run_id:, incident_path: nil)
      @raw_log_path = raw_log_path
      @projector = AgentStreamProjector.new(memory_path:, agent_type:, run_id:)
      @breaker = SleepCircuitBreaker.new(agent_type:)
      @incident_path = incident_path.to_s
    end

    def run(command)
      FileUtils.mkdir_p(File.dirname(@raw_log_path))
      stream = nil
      child_output = nil
      pid = nil
      status = nil

      File.open(@raw_log_path, "ab") do |raw|
        stream, child_output = IO.pipe
        pid = Process.spawn(*command, in: File::NULL, out: child_output, err: [:child, :out], pgroup: true)
        child_output.close
        child_output = nil
        install_signal_relay(pid)

        source_sequence = 0
        stream.each_line do |line|
          raw_offset = raw.pos
          raw.write(line)
          raw.flush
          @projector.project_line(line, source_sequence:, raw_offset:, occurred_at: Time.now)
          if (incident = @breaker.observe(line))
            persist_incident!(incident)
            raw.write("Tycho opened the sleep circuit breaker after #{incident.fetch("blocking_call_count")} blocking waits.\n")
            raw.flush
            terminate_child_group(pid)
            break
          end
        rescue StandardError => e
          diagnostic = "Tycho stream projection failed at line #{source_sequence}: #{e.class}: #{e.message}\n"
          raw.write(diagnostic)
          raw.flush
          source_sequence += 1
        ensure
          source_sequence += 1
        end
        _waited_pid, status = Process.wait2(pid)
      end

      process_exit_code(status)
    rescue SystemCallError => e
      warn "failed to execute #{Array(command).first.inspect} (exit 127): #{e.message}"
      127
    ensure
      stream&.close unless stream&.closed?
      child_output&.close unless child_output&.closed?
      begin
        Process.wait(pid) if pid && !status
      rescue Errno::ECHILD
        nil
      end
    end

    private

    def install_signal_relay(pid)
      %w[TERM INT].each do |signal|
        Signal.trap(signal) do
          begin
            @relayed_signal = signal
            Process.kill(signal, -pid)
            Process.kill("KILL", -pid) if signal == "TERM"
          rescue Errno::ESRCH, Errno::EPERM
            nil
          end
        end
      end
    rescue ArgumentError
      nil
    end

    def persist_incident!(incident)
      return if @incident_path.empty?

      FileUtils.mkdir_p(File.dirname(@incident_path))
      temporary = "#{@incident_path}.tmp-#{Process.pid}"
      File.write(temporary, JSON.generate(incident))
      File.rename(temporary, @incident_path)
    ensure
      FileUtils.rm_f(temporary) if defined?(temporary) && temporary
    end

    def terminate_child_group(pid, term_timeout: 0.5, kill_timeout: 0.5)
      signal_child_group(pid, "TERM")
      return unless wait_for_child_group(pid, term_timeout)

      signal_child_group(pid, "KILL")
      wait_for_child_group(pid, kill_timeout)
    end

    def signal_child_group(pid, signal)
      Process.kill(signal, -pid)
    rescue Errno::ESRCH, Errno::EPERM
      nil
    end

    def wait_for_child_group(pid, timeout)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
      loop do
        Process.kill(0, -pid)
        return true if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

        sleep 0.01
      rescue Errno::ESRCH, Errno::EPERM
        return false
      end
    end

    def process_exit_code(status)
      return 143 if @relayed_signal == "TERM"
      return 1 unless status
      return 128 + status.termsig.to_i if status.signaled?

      status.exitstatus.to_i
    end
  end
end
