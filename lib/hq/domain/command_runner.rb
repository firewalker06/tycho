# frozen_string_literal: true

require "tempfile"

module HQ
  module CommandRunner
    Result = Struct.new(:stdout, :stderr, :status, :timed_out, keyword_init: true) do
      def success?
        status&.success? && !timed_out?
      end

      def timed_out?
        timed_out == true
      end

      def exit_code
        return nil unless status
        return 128 + status.termsig.to_i if status.signaled?

        status.exitstatus
      end
    end

    module_function

    def capture(command, timeout:, terminate_timeout: 0.5)
      stdout = Tempfile.new("tycho-command-out")
      stderr = Tempfile.new("tycho-command-err")
      pid = Process.spawn(*Array(command), out: stdout.path, err: stderr.path, pgroup: true)
      status = wait_for(pid, timeout)
      timed_out = status.nil?
      status ||= terminate(pid, timeout: terminate_timeout)
      status ||= Process.waitpid2(pid).last
      stdout.rewind
      stderr.rewind
      Result.new(stdout: stdout.read, stderr: stderr.read, status:, timed_out:)
    ensure
      stdout&.close!
      stderr&.close!
    end

    def wait_for(pid, timeout)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout.to_f
      loop do
        _done, status = Process.waitpid2(pid, Process::WNOHANG)
        return status if status
        return nil if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

        sleep 0.01
      end
    end
    private_class_method :wait_for

    def terminate(pid, timeout:)
      Process.kill("TERM", -pid)
      status = wait_for(pid, timeout)
      return status if status

      Process.kill("KILL", -pid)
      nil
    rescue Errno::ESRCH, Errno::ECHILD
      nil
    end
    private_class_method :terminate
  end
end
