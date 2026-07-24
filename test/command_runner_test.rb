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
      [RbConfig.ruby, "-e", "trap('TERM') {}; sleep 30"],
      timeout: 0.2,
      terminate_timeout: 0.05
    )
    assert(timed_out.timed_out? && timed_out.exit_code == 137,
           "expected timeout to preserve SIGKILL status")
    puts "command_runner_test: ok"
  end

  def assert(condition, message)
    raise message unless condition
  end
end

CommandRunnerTest.run! if $PROGRAM_NAME == __FILE__
