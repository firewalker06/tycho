# frozen_string_literal: true

require_relative "support/push_safety"
require_relative "../lib/hq/remote_server"
require "yaml"

module NotificationDebuggerTest
  module_function

  def assert(value, message)
    raise message unless value
  end

  def assert_error(status)
    yield
    raise "expected request rejection"
  rescue HQ::RemoteServer::Error => error
    assert(error.status == status, "expected #{status}, got #{error.status}")
  end

  def run!
    Dir.mktmpdir("notification-debugger-") do |dir|
      workspace = File.join(dir, "workspace")
      FileUtils.mkdir_p(workspace)
      config = File.join(dir, "hq.yml")
      File.write(config, YAML.dump("projects" => [{ "key" => "fixture", "name" => "Fixture", "path" => workspace }]))
      service = HQ::RemoteService.new(registry: HQ::Registry.new(path: config))
      agent = HQ::ManagedAgent.from_hash(
        "key" => "debug-agent", "name" => "Synthetic agent", "project_key" => "fixture",
        "workspace" => workspace, "prompt" => "Retained fixture", "agent" => "codex",
        "session_id" => "native-session", "started_at" => "2026-10-15T00:00:00Z",
        "last_exit_code" => 0, "summary" => "Retained result",
        "runs" => [{ "session_id" => "historical-session", "status" => "succeeded" }]
      )
      HQ::FileStore.write_json(HQ::AGENTS_FILE, [agent.to_hash])
      before = File.binread(HQ::AGENTS_FILE)
      attrs = { "session_id" => "native-session", "type" => "failed" }
      preview = service.preview_agent_notification(attrs)
      assert(preview[:agent][:key] == agent.key && preview[:payload][:title] == "Failed", "resolve native ID and selected outcome")
      assert(service.instance_variable_get(:@push_notification_store).all.empty?, "preview must not retain or send a record")
      assert(File.binread(HQ::AGENTS_FILE) == before, "preview must not poll or mutate the agent")
      assert(service.preview_agent_notification("session_id" => "historical-session", "type" => "succeeded")[:agent][:key] == agent.key, "resolve native ID in retained runs")
      assert(preview[:server]["id"] == HQ::ServerIdentity.load["id"], "target belongs to this server identity")
      assert_error(404) { service.preview_agent_notification(attrs.merge("agent_key" => "peer/agent")) }
      assert(service.preview_agent_notification("session_id" => agent.key, "type" => "succeeded")[:payload][:title] == "Done", "resolve Tycho key")
      assert_error(404) { service.preview_agent_notification("session_id" => "absent", "type" => "failed") }
      assert_error(400) { service.preview_agent_notification(attrs.merge("type" => "arbitrary")) }
      assert_error(400) { service.preview_agent_notification(attrs.merge("session_id" => "")) }
      assert_error(409) { service.send_agent_notification(attrs) }
      assert_error(409) { service.send_agent_notification(attrs.merge("endpoint" => "https://unregistered.invalid/secret")) }
      second = HQ::ManagedAgent.from_hash(agent.to_hash.merge("key" => "another-agent"))
      HQ::FileStore.write_json(HQ::AGENTS_FILE, [agent.to_hash, second.to_hash])
      choices = service.preview_agent_notification(attrs)[:choices]
      assert(choices.map { |row| row[:key] }.sort == [agent.key, second.key].sort, "shared native identity must show both choices")
      assert_error(409) { service.send_agent_notification(attrs) }
      chosen = attrs.merge("agent_key" => agent.key)
      assert(service.preview_agent_notification(chosen)[:agent][:key] == agent.key, "explicit ambiguity selection")
      HQ::FileStore.write_json(HQ::AGENTS_FILE, [agent.to_hash])
      endpoint = "https://push.example.test/current-browser"
      [endpoint, "https://push.example.test/other-browser"].each do |value|
        service.save_push_subscription({ "endpoint" => value, "keys" => { "p256dh" => "synthetic-key", "auth" => "synthetic-auth" } })
      end
      captured = []
      original = WebPush.method(:payload_send)
      WebPush.define_singleton_method(:payload_send) do |**options|
        captured << options
        Struct.new(:code).new("201")
      end
      begin
        HQ::AgentNotification::TYPES.each do |type, definition|
          result = service.send_agent_notification(attrs.merge("type" => type, "endpoint" => endpoint, "url" => "https://untrusted.invalid"))
          assert(result[:delivery] == { sent: 1, failed: 0, attempted: 1, disabled: 0 }, "fake provider accepted only current browser")
          assert(captured.last[:endpoint] == endpoint, "must not broadcast the debugger event")
          record = service.instance_variable_get(:@push_notification_store).find(result[:record_id])
          assert(record["agent_key"] == agent.key && record["debug"] == true, "retained production agent target")
          assert(record["title"] == definition[:title] && record["event"] == definition[:event], "actual production types")
          payload = JSON.parse(captured.last[:message])
          shared = HQ::AgentNotification.build(agent, status: type, unread_count: 1, id: result[:record_id])
          assert(payload == JSON.parse(JSON.generate(shared[:payload])), "debug transport must use the production builder unchanged")
          assert(result[:payload][:url].start_with?("/#notification/") && result[:target_url] == "/#agent/debug-agent", "same retained-record click route; ignore arbitrary URL")
          assert(!JSON.generate(result).include?(endpoint) && !JSON.generate(result).include?("synthetic-auth"), "redact subscription capabilities")
        end
        before_count = captured.length
        service.send(:dispatch_agent_push_events, [Struct.new(:agent_key).new(agent.key)], agents: [agent])
        assert(captured.length == before_count + 2, "automatic production event still sends through the shared transport to enabled browsers")
        automatic = JSON.parse(captured.last[:message])
        expected = HQ::AgentNotification.build(agent, status: agent.status, unread_count: 0,
          id: service.send(:agent_push_notification_id, agent, "finished"))
        assert(automatic == JSON.parse(JSON.generate(expected[:payload])), "automatic and debugger use same builder and dispatch")
        WebPush.define_singleton_method(:payload_send) { |**_options| raise IOError, "synthetic provider failure" }
        failed = service.send_agent_notification(attrs.merge("endpoint" => endpoint))
        assert(failed[:delivery][:failed] == 1 && failed[:subscription][:last_error_class] == "IOError", "retain redacted delivery failure")
      ensure
        WebPush.define_singleton_method(:payload_send, original)
      end
      assert(File.binread(HQ::AGENTS_FILE) == before, "all sends leave agent status, runs and commands unchanged")
      service.disable_push_subscription("endpoint" => endpoint)
      assert_error(409) { service.send_agent_notification(attrs.merge("endpoint" => endpoint)) }
      assert_error(409) { service.send_test_push({}) }
      archive_dir = File.join(HQ::AGENT_ARCHIVE_DIR, "synthetic-debug-agent")
      FileUtils.mkdir_p(archive_dir)
      HQ::FileStore.write_json(File.join(archive_dir, "agent_manifest.json"), agent.to_hash)
      HQ::FileStore.write_json(HQ::AGENTS_FILE, [])
      archived = service.preview_agent_notification(attrs)
      assert(archived[:agent][:target_state] == "archived" && archived[:target_url] == "/#agent/debug-agent", "same retained archived Conversation target")
    end
    puts "notification_debugger_test: ok"
  end
end

NotificationDebuggerTest.run!
