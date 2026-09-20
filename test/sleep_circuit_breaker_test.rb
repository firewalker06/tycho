# frozen_string_literal: true

require "json"
require "rbconfig"
require "tmpdir"

require_relative "../lib/hq/domain/agent_stream_recorder"
require_relative "../lib/hq/domain/sleep_circuit_breaker"

module SleepCircuitBreakerTest
  module_function

  def run!
    assert_supported_harness_shapes_trip_on_third_unique_wait
    assert_false_positives_and_completed_events_do_not_count
    assert_opencode_remains_capability_gated
    assert_recorder_terminates_harness_process_group_and_persists_incident
    puts "sleep_circuit_breaker_test: ok"
  end

  def assert_supported_harness_shapes_trip_on_third_unique_wait
    fixtures = {
      "codex" => lambda do |id|
        { "type" => "item.started", "item" => {
          "id" => id, "type" => "command_execution", "command" => "/bin/zsh -lc 'sleep 30'"
        } }
      end,
      "claude" => lambda do |id|
        { "type" => "assistant", "message" => { "content" => [{
          "type" => "tool_use", "id" => id, "name" => "Bash", "input" => { "command" => "sleep 30" }
        }] } }
      end,
      "pi" => lambda do |id|
        { "type" => "tool_execution_start", "toolCallId" => id, "toolName" => "bash",
          "args" => { "command" => "sleep 30" } }
      end
    }

    fixtures.each do |adapter, event|
      breaker = HQ::SleepCircuitBreaker.new(agent_type: adapter)
      assert(breaker.observe(JSON.generate(event.call("one"))).nil?, "expected #{adapter} wait one")
      assert(breaker.observe(JSON.generate(event.call("one"))).nil?, "expected #{adapter} duplicate to be ignored")
      assert(breaker.observe(JSON.generate(event.call("two"))).nil?, "expected #{adapter} wait two")
      incident = breaker.observe(JSON.generate(event.call("three")))
      assert(incident&.fetch("reason") == "sleep_circuit_breaker" &&
             incident.fetch("blocking_call_count") == 3 && incident.fetch("trigger_call_id") == "three",
             "expected #{adapter} to trip on the third unique wait")
    end
  end

  def assert_false_positives_and_completed_events_do_not_count
    breaker = HQ::SleepCircuitBreaker.new(agent_type: "codex")
    commands = [
      "rg -n sleep docs/",
      "ruby -e 'puts \\\"sleep 10\\\"'",
      "cat sleep-notes.md"
    ]
    commands.each_with_index do |command, index|
      event = { "type" => "item.started", "item" => {
        "id" => "false-#{index}", "type" => "command_execution", "command" => command
      } }
      assert(breaker.observe(JSON.generate(event)).nil?, "expected prose/search command not to count")
    end
    completed = { "type" => "item.completed", "item" => {
      "id" => "completed", "type" => "command_execution", "command" => "sleep 30"
    } }
    assert(breaker.observe(JSON.generate(completed)).nil?, "expected completed commands not to count")
  end

  def assert_opencode_remains_capability_gated
    breaker = HQ::SleepCircuitBreaker.new(agent_type: "opencode")
    event = { "type" => "tool_use", "part" => {
      "tool" => "bash", "callID" => "open-1",
      "state" => { "status" => "completed", "input" => { "command" => "sleep 30" } }
    } }
    assert(!breaker.supported? && breaker.observe(JSON.generate(event)).nil?,
           "expected OpenCode completed-only evidence to remain unsupported")
  end

  def assert_recorder_terminates_harness_process_group_and_persists_incident
    Dir.mktmpdir("tycho-sleep-breaker") do |dir|
      raw_path = File.join(dir, "raw.log")
      memory_path = File.join(dir, "memory.jsonl")
      incident_path = File.join(dir, "incident.json")
      child_path = File.join(dir, "child.pid")
      script = <<~RUBY
        child = Process.spawn(#{RbConfig.ruby.inspect}, "-e", "sleep 60")
        File.write(ARGV.fetch(0), child.to_s)
        STDOUT.sync = true
        3.times do |index|
          puts JSON.generate("type" => "item.started", "item" => {
            "id" => "wait-\#{index}", "type" => "command_execution", "command" => "sleep 60"
          })
        end
        sleep 60
      RUBY
      status = HQ::AgentStreamRecorder.run(
        command: [RbConfig.ruby, "-rjson", "-e", script, child_path],
        raw_log_path: raw_path,
        memory_path:,
        agent_type: "codex",
        run_id: "breaker-run",
        incident_path:
      )
      child_pid = Integer(File.read(child_path))
      wait_until { !process_alive?(child_pid) }
      incident = JSON.parse(File.read(incident_path))
      assert(status == 143 && incident["reason"] == "sleep_circuit_breaker",
             "expected recorder to return SIGTERM status with a durable incident")
    ensure
      Process.kill("KILL", child_pid) if defined?(child_pid) && process_alive?(child_pid)
    end
  end

  def process_alive?(pid)
    Process.kill(0, pid)
    true
  rescue Errno::ESRCH
    false
  end

  def wait_until(timeout: 2)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    until yield
      raise "timed out waiting for process termination" if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

      sleep 0.02
    end
  end

  def assert(condition, message)
    raise message unless condition
  end
end

SleepCircuitBreakerTest.run! if $PROGRAM_NAME == __FILE__
