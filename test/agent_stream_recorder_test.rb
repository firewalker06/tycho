# frozen_string_literal: true

require "json"
require "rbconfig"
require "tmpdir"

require_relative "../lib/hq/domain/agent_event_journal"
require_relative "../lib/hq/domain/agent_chat_log"
require_relative "../lib/hq/domain/agent_stream_recorder"

module AgentStreamRecorderTest
  module_function

  def run!
    assert_messages_persist_before_process_exit
    assert_replay_deduplicates_events
    assert_claude_and_opencode_shapes_project
    puts "agent_stream_recorder_test: ok"
  end

  def assert_messages_persist_before_process_exit
    Dir.mktmpdir("tycho-stream-recorder") do |dir|
      raw_path = File.join(dir, "agent.raw.log")
      memory_path = File.join(dir, "agent.memory.jsonl")
      first = codex_message("first")
      second = codex_message("second")
      script = "STDOUT.sync=true; puts(ARGV[0]); sleep 0.6; puts(ARGV[1])"
      command = [RbConfig.ruby, "-e", script, first, second]

      runner = Thread.new do
        HQ::AgentStreamRecorder.run(
          command:,
          raw_log_path: raw_path,
          memory_path:,
          agent_type: "codex",
          run_id: "run-1"
        )
      end

      wait_until { File.exist?(memory_path) && journal(memory_path).events.any? }
      events = journal(memory_path).events
      assert(events.map { |event| event["content"] } == ["first"], "expected first message before process exit")

      journal(memory_path).append(
        { "type" => "delegation_event", "content" => "child started", "created_at" => Time.now.iso8601 },
        event_id: "delegation-1"
      )
      assert(runner.value == 0, "expected recorder command to succeed")

      events = journal(memory_path).events
      assert(events.map { |event| event["content"] } == ["first", "child started", "second"],
             "expected one shared durable order")
      assert(events.map { |event| event["sequence"] } == [1, 2, 3], "expected monotonic sequence")

      fake_agent = Struct.new(:memory_path, :pid, :finished_at, :raw_log_path, :agent, :runs)
                         .new(memory_path, nil, Time.now, raw_path, "codex", [])
      blocks = HQ::AgentChatLog.new(fake_agent).chat_blocks
      assert(blocks.map(&:content) == ["first", "child started", "second"],
             "expected conversation projection to preserve durable sequence")
    end
  end

  def assert_replay_deduplicates_events
    Dir.mktmpdir("tycho-stream-replay") do |dir|
      memory_path = File.join(dir, "agent.memory.jsonl")
      projector = HQ::AgentStreamProjector.new(memory_path:, agent_type: "codex", run_id: "run-2")
      line = codex_message("once")
      projector.project_line(line, source_sequence: 4)
      projector.project_line(line, source_sequence: 4)

      assert(journal(memory_path).events.length == 1, "expected deterministic replay deduplication")
    end
  end

  def assert_claude_and_opencode_shapes_project
    Dir.mktmpdir("tycho-stream-harnesses") do |dir|
      claude_path = File.join(dir, "claude.memory.jsonl")
      claude = HQ::AgentStreamProjector.new(memory_path: claude_path, agent_type: "claude", run_id: "claude-run")
      claude.project_line(JSON.generate(
                            "type" => "assistant",
                            "message" => { "content" => [{ "type" => "text", "text" => "Claude progress" }] }
                          ), source_sequence: 0)

      opencode_path = File.join(dir, "opencode.memory.jsonl")
      opencode = HQ::AgentStreamProjector.new(memory_path: opencode_path, agent_type: "opencode", run_id: "open-run")
      opencode.project_line(JSON.generate(
                              "type" => "text",
                              "part" => { "type" => "text", "text" => "OpenCode progress" }
                            ), source_sequence: 0)

      assert(journal(claude_path).events.first["content"] == "Claude progress", "expected Claude projection")
      assert(journal(opencode_path).events.first["content"] == "OpenCode progress", "expected OpenCode projection")
    end
  end

  def codex_message(content)
    JSON.generate("type" => "item.completed", "item" => { "type" => "agent_message", "text" => content })
  end

  def journal(path)
    HQ::AgentEventJournal.new(path)
  end

  def wait_until(timeout: 3)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    until yield
      raise "timed out waiting for stream event" if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

      sleep 0.02
    end
  end

  def assert(condition, message)
    raise message unless condition
  end
end

AgentStreamRecorderTest.run! if $PROGRAM_NAME == __FILE__
