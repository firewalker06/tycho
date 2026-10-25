# frozen_string_literal: true

require "tmpdir"
require "open3"
require "json"
require_relative "../lib/hq/domain/managed_agent"
require_relative "../lib/hq/remote_server"

module SummaryIdleStopTest
  module_function

  MARKER = "Tycho stopped this run after no structured agent output stayed idle for 300 seconds."

  def run!
    Dir.mktmpdir("summary-idle-stop-test") do |dir|
      at = Time.utc(2026, 10, 21, 6, 12, 59)
      log = File.join(dir, "wrapper.raw.log")
      output, status = Open3.capture2e("/bin/sh", "-c", "printf '%s\\n' 'Synthetic wrapper needs login' 'https://example.test/sso?callback=SYNTHETIC_CALLBACK_SECRET' 'token=SYNTHETIC_LOGIN_SECRET' >&2")
      raise "fake wrapper failed" unless status.success?

      run = HQ::ManagedAgent::AgentRun.new(started_at: at, status: "running", log_path: log, run_id: "idle-run", log_start_offset: 0, metadata: {})
      agent = HQ::ManagedAgent.new(key: "idle-fixture", name: "Idle fixture", project_key: "demo", template_key: "custom", workspace: dir,
                                   prompt: "Synthetic only", agent: "codex", response_style: false, log_path: log, runs: [run], started_at: at)
      File.write(log, "=== [#{at.iso8601}] start ===\n=== process output ===\n#{output}")
      File.utime(at, at, log)
      # Keep the production idle detector and stop record; do not signal a process.
      def agent.terminate_process_group!(term_timeout:)
      end
      raise "idle detector did not stop" unless agent.send(:stop_stale_direct_output_wait!, now: at + 304)
      raise "stop reason not recorded on this run" unless run.metadata["operator_stop_reason"] == "no_structured_output_idle"

      run.finished_at = at + 304
      run.status = "stopped"
      run.exit_code = 143
      agent.instance_variable_set(:@finished_at, at + 304)
      agent.instance_variable_set(:@last_exit_code, 143)
      raise "backend lost reason" unless agent.build_summary!.include?(MARKER)
      agent.send(:capture_run_memory!, run)
      events = HQ::AgentMemory.new(agent).events
      raise "plain wrapper text became a stream error" if events.any? { |event| event["type"] == "stream_status" }
      summary = events.find { |event| event["type"] == "run_summary" }
      raise "memory lost reason metadata" unless summary.dig("metadata", "operator_stop_reason") == "no_structured_output_idle"
      raise "summary copied wrapper secrets" if summary["content"].include?("SYNTHETIC_")

      service = HQ::RemoteService.allocate
      def service.delegation_reference_context
        { active: {}, archived: {}, visible_keys: {} }
      end
      blocks = service.send(:project_conversation_blocks, agent, service.send(:chat_blocks_for_agent, agent))
      block = blocks.find { |item| item[:kind] == "run_summary" }
      raise "API lost reason" unless block.dig(:metadata, "operator_stop_reason") == "no_structured_output_idle" && block[:content].include?(MARKER)
      fixture_path = File.join(dir, "fixture.json")
      File.write(fixture_path, JSON.generate(key: agent.key, status: "stopped", run_count: 1, running: false, summary: agent.last_summary, blocks:))
      script = File.join(__dir__, "support", "summary_idle_stop_assertions.js")
      out, err, status = Open3.capture3("node", script, fixture_path, chdir: File.expand_path("..", __dir__))
      raise "Summary selection failed:\n#{out}#{err}" unless status.success?

      # Metadata also preserves the known reason if the raw log is no longer present.
      File.delete(log)
      raise "explicit stop reason requires raw log" unless agent.build_summary!.include?(MARKER)
      manual = HQ::ManagedAgent::AgentRun.new(started_at: at + 600, finished_at: at + 601, exit_code: 143, status: "stopped", run_id: "manual-run", metadata: {})
      agent.runs << manual
      raise "manual stop inherited previous reason" if agent.build_summary!.include?(MARKER)
      raise "manual stop inherited previous metadata" if agent.send(:run_summary_metadata, manual).key?("operator_stop_reason")
    end
    puts "summary_idle_stop_test: ok"
  end
end

SummaryIdleStopTest.run! if $PROGRAM_NAME == __FILE__
