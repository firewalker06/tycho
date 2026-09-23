# frozen_string_literal: true

require "time"

require_relative "../lib/hq/domain/harness_auth_check"

module HarnessAuthCheckTest
  module_function

  Capture = Struct.new(:stdout, :stderr, :successful, :timed_out) do
    def success? = successful
    def timed_out? = timed_out
  end

  def run!
    assert_status_check_persists_no_command_output
    assert_opencode_check_requires_provider
    assert_pi_check_requires_model
    assert_unknown_command_stays_unknown
    puts "harness_auth_check_test: ok"
  end

  def assert_status_check_persists_no_command_output
    runner = FakeRunner.new(Capture.new("secret account output", "", true, false))
    check = HQ::HarnessAuthCheck.new(runner:, clock: -> { Time.utc(2026, 9, 22, 8, 0, 0) })

    snapshot = check.check(adapter: "codex", command: ["codex"])

    assert(snapshot.to_h == {
      state: "authenticated", detail: "Authentication check succeeded", checked_at: "2026-09-22T08:00:00Z"
    }, "expected a sanitized successful Codex snapshot")
    assert(runner.command == %w[codex auth status], "expected Codex auth status command")
  end

  def assert_opencode_check_requires_provider
    runner = FakeRunner.new(Capture.new("┌ Credentials\n└ 0 credentials\n", "", true, false))
    snapshot = HQ::HarnessAuthCheck.new(runner:).check(adapter: "opencode", command: ["opencode"])

    assert(snapshot.state == "unauthenticated" && snapshot.detail == "No authenticated providers found",
           "expected empty OpenCode provider list to be unauthenticated")
  end

  def assert_pi_check_requires_model
    runner = FakeRunner.new(Capture.new("No models available. Authenticate a provider first.\n", "", true, false))
    snapshot = HQ::HarnessAuthCheck.new(runner:).check(adapter: "pi", command: ["pi"])

    assert(snapshot.state == "unauthenticated", "expected Pi without models to be unauthenticated")
  end

  def assert_unknown_command_stays_unknown
    runner = FakeRunner.new(Capture.new("", "error: unknown command auth", false, false))
    snapshot = HQ::HarnessAuthCheck.new(runner:).check(adapter: "claude", command: ["wrapper"])

    assert(snapshot.state == "unknown", "expected unsupported custom auth command to stay unknown")
  end

  def assert(condition, message)
    raise message unless condition
  end

  class FakeRunner
    attr_reader :command, :environment

    def initialize(capture)
      @capture = capture
    end

    def capture(command, timeout:, environment:)
      @command = command
      @environment = environment
      @capture
    end
  end
end

HarnessAuthCheckTest.run! if $PROGRAM_NAME == __FILE__
