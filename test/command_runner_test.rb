# frozen_string_literal: true

require "rbconfig"

require_relative "../lib/hq/domain/command_runner"

module CommandRunnerTest
  module_function

  def run!
    result = HQ::CommandRunner.capture(
      [RbConfig.ruby, "-e", "$stdout.write(\"out\"); $stderr.write(\"err\"); exit 7"],
      timeout: 2
    )
    assert(result.stdout == "out" && result.stderr == "err" && result.exit_code == 7,
           "expected output and exit status capture")

    timed_out = HQ::CommandRunner.capture(
      [RbConfig.ruby, "-e", "sleep 30"],
      timeout: 0.2,
      terminate_timeout: 0.05
    )
    assert(timed_out.timed_out? && !timed_out.success? && timed_out.status,
           "expected timeout to preserve the child status")

    escalation_status = terminate_process_that_ignores_term
    assert(escalation_status.signaled? && escalation_status.termsig == Signal.list.fetch("KILL"),
           "expected TERM timeout to escalate to SIGKILL")
    puts "command_runner_test: ok"
  end

  def terminate_process_that_ignores_term
    reader, writer = IO.pipe
    pid = fork do
      reader.close
      Process.setpgid(0, 0)
      Signal.trap("TERM", "IGNORE")
      writer.write("1")
      writer.close
      sleep 30
    end
    writer.close
    raise "child did not become ready" unless reader.read(1) == "1"

    HQ::CommandRunner.send(:terminate, pid, timeout: 0.05) || Process.waitpid2(pid).last
  ensure
    reader&.close
    writer&.close
    if pid
      begin
        Process.kill("KILL", -pid)
      rescue Errno::ESRCH
        nil
      end
      begin
        Process.waitpid(pid)
      rescue Errno::ECHILD
        nil
      end
    end
  end

  def assert(condition, message)
    raise message unless condition
  end
end

CommandRunnerTest.run! if $PROGRAM_NAME == __FILE__
