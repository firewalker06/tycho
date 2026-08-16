# frozen_string_literal: true

require "fileutils"

require_relative "agent_stream_projector"

module HQ
  class AgentStreamRecorder
    def self.run(command:, raw_log_path:, memory_path:, agent_type:, run_id:)
      new(raw_log_path:, memory_path:, agent_type:, run_id:).run(command)
    end

    def initialize(raw_log_path:, memory_path:, agent_type:, run_id:)
      @raw_log_path = raw_log_path
      @projector = AgentStreamProjector.new(memory_path:, agent_type:, run_id:)
    end

    def run(command)
      FileUtils.mkdir_p(File.dirname(@raw_log_path))
      stream = nil
      child_output = nil
      pid = nil
      status = nil

      File.open(@raw_log_path, "ab") do |raw|
        stream, child_output = IO.pipe
        pid = Process.spawn(*command, in: File::NULL, out: child_output, err: [:child, :out])
        child_output.close
        child_output = nil

        source_sequence = 0
        stream.each_line do |line|
          raw_offset = raw.pos
          raw.write(line)
          raw.flush
          @projector.project_line(line, source_sequence:, raw_offset:, occurred_at: Time.now)
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

    def process_exit_code(status)
      return 1 unless status
      return 128 + status.termsig.to_i if status.signaled?

      status.exitstatus.to_i
    end
  end
end
