# frozen_string_literal: true

require "timeout"
require_relative "prompt_queue_test"

module WorkspaceConcurrencyTest
  module_function

  def assert(condition, message)
    raise message unless condition
  end

  def agent(workspace, key)
    now = Time.now
    HQ::ManagedAgent.new(
      key:, name: key, project_key: "web", template_key: "default", workspace:,
      prompt: "Synthetic work", agent: "codex", log_path: File.join(workspace, "#{key}.raw.log"),
      started_at: now, finished_at: now, last_exit_code: 0,
      runs: [HQ::ManagedAgent::AgentRun.new(started_at: now, finished_at: now, exit_code: 0,
                                           status: "success", log_path: File.join(workspace, "#{key}.raw.log"))]
    )
  end

  def fixture
    PromptQueueTest.with_queue_store do |registry, workspace|
      original = ENV["TYCHO_CODEX_BIN"]
      harness = File.join(workspace, "gated-codex")
      File.write(harness, <<~'CODE')
        #!/usr/bin/env ruby
        require "json"
        key = ENV.fetch("TYCHO_AGENT_KEY")
        STDIN.read
        File.open("#{key}.starts", "a") { |file| file.puts(Process.pid) }
        File.write("#{key}.ready", "ready")
        sleep 0.01 until File.exist?("release")
        result = { "status" => "success", "summary" => "Synthetic work complete" }
        output = ARGV.index("-o")
        File.write(ARGV[output + 1], JSON.generate(result)) if output
        puts JSON.generate("type" => "turn.completed")
      CODE
      File.chmod(0o755, harness)
      ENV["TYCHO_CODEX_BIN"] = harness
      store = HQ::AgentStore.new(registry.projects)
      store.save([agent(workspace, "first"), agent(workspace, "second")])
      yield store, registry, workspace
    ensure
      File.write(File.join(workspace, "release"), "finish")
      store&.load_with_poll_events(process_delegations: false, dispatch_prompt_queues: false)&.first&.each do |item|
        item.stop! if item.running?
      end
      ENV["TYCHO_CODEX_BIN"] = original
    end
  end

  def wait_ready(workspace, *keys)
    Timeout.timeout(10) do
      sleep 0.01 until keys.all? { |key| File.exist?(File.join(workspace, "#{key}.ready")) }
    end
  end

  def assert_distinct_agents_progress
    %w[queue manual send schedule].each do |path|
      fixture do |store, registry, workspace|
        store.start_agent!("first")
        wait_ready(workspace, "first")
        case path
        when "queue"
          records = store.load_with_poll_events(process_delegations: false, dispatch_prompt_queues: false).first
          records.last.enqueue_prompt!(id: "due-work", prompt: "Do queued work")
          store.save(records)
          service = HQ::RemoteService.new(registry:)
          payload = service.send(:prompt_queue_payload, records.last)
          assert(payload.dig("processing", "state") == "ready", "running sibling must not block API queue status")
          2.times.map { Thread.new { HQ::AgentStore.new(registry.projects).load } }.each(&:value)
        when "manual"
          store.start_agent!("second")
        when "send"
          store.accept_or_abort_prompt!("second", prompt: "Do sent work", actor: nil, event_id: "synthetic-send", start: true)
        when "schedule"
          store.dispatch_scheduled_message!("second", schedule_key: "synthetic", message: "Do scheduled work")
        end
        wait_ready(workspace, "first", "second")
        loaded = store.load_with_poll_events(process_delegations: false, dispatch_prompt_queues: false).first
        assert(loaded.all?(&:running?), "#{path}: both native harnesses must remain running")
        loaded.each do |item|
          assert(File.readlines(File.join(workspace, "#{item.key}.starts")).length == 1,
                 "#{path}: duplicate native start for #{item.key}")
        end
        puts "workspace-concurrency: #{path}: two distinct native harnesses made progress together"
      end
    end
  end

  def assert_cross_process_start_exclusion
    %w[manual queue].each do |path|
      fixture do |store, registry, workspace|
        if path == "queue"
          records = store.load_with_poll_events(process_delegations: false, dispatch_prompt_queues: false).first
          records.first.enqueue_prompt!(id: "raced-work", prompt: "One queued delivery")
          store.save(records)
        end
        readers = []
        children = 4.times.map do
          reader, writer = IO.pipe
          readers << writer
          fork do
            writer.close
            reader.read(1)
            client = HQ::AgentStore.new(registry.projects)
            path == "queue" ? client.load : client.start_agent!("first")
            exit! 0
          rescue StandardError
            exit! 1
          end
        end
        readers.each { |writer| writer.write("go"); writer.close }
        children.each do |pid|
          _, status = Process.wait2(pid)
          assert(status.success?, "racing start failed")
        end
        wait_ready(workspace, "first")
        loaded = store.load_with_poll_events(process_delegations: false, dispatch_prompt_queues: false).first
        assert(loaded.find { |item| item.key == "first" }.run_count == 2, "racing starts added multiple runs")
        assert(File.readlines(File.join(workspace, "first.starts")).length == 1, "racing starts launched the same agent twice")
        first = loaded.find { |item| item.key == "first" }
        if path == "queue"
          assert(first.active_queue_work["entries"].map { |entry| entry["id"] } == ["raced-work"],
                 "racing queue dispatch lost the claimed entry")
          reads = HQ::AgentMemory.new(first).events.count { |event| event.dig("metadata", "queue_read") }
          assert(reads == 1, "racing queue dispatch duplicated the receipt")
        end
        puts "workspace-concurrency: #{path}: four processes raced; one native harness started"
      end
    end
  end

  def run!
    assert_distinct_agents_progress
    assert_cross_process_start_exclusion
    puts "workspace_concurrency_test: ok"
  end
end

WorkspaceConcurrencyTest.run! if $PROGRAM_NAME == __FILE__
