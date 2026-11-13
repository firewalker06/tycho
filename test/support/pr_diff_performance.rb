# frozen_string_literal: true

require_relative "../remote_server_test"

module PRDiffPerformance
  module_function

  class DelayedClient < RemoteServerTest::FakeGitHubDiffClient
    def get_json(...)
      sleep 0.02
      super
    end

    def get_text(...)
      sleep 0.02
      super
    end
  end

  module SpawnCounter
    def spawn(...)
      Thread.current[:pr_diff_spawn_count] += 1 if Thread.current[:pr_diff_spawn_count]
      super
    end
  end

  def run!
    Process.singleton_class.prepend(SpawnCounter)
    RemoteServerTest.with_remote_temp_store do |dir|
      workspace = File.join(dir, "workspace")
      RemoteServerTest.write_project_workspace(workspace)
      registry = RemoteServerTest.registry_for_project(dir, workspace)
      client = DelayedClient.new
      store = HQ::PullRequestDiff::Store.new(File.join(dir, "diffs.json"))
      service = HQ::RemoteService.new(registry:, github_client: client, pull_request_diff_store: store)
      created = service.create_agent("project_key" => "web", "template_key" => "custom",
                                     "name" => "Synthetic performance fixture", "prompt" => "Inspect synthetic diffs.")
      agent = HQ::AgentStore.new(registry.projects).load.find { |item| item.key == created[:key] }
      memory = HQ::AgentMemory.new(agent)
      15.times do |index|
        memory.append_attachment!({ "type" => "link", "title" => "Synthetic PR #{index + 1}",
                                    "url" => "https://github.com/example/fixture/pull/#{index + 1}" })
      end
      records = []
      listing = measure("initial_list", client, records) { service.agent_pull_request_listing(agent.key) }
      id = listing.fetch(:pull_requests).last.fetch("id")
      measure("selected_remote_fetch", client, records) { service.refresh_agent_pull_request_diff(agent.key, id) }
      measure("selected_saved_read", client, records) { service.agent_pull_request_diff(agent.key, id) }
      measure("legacy_bulk_remote_fetch", client, records) { service.refresh_agent_pull_requests(agent.key) }
      measure("warm_list", client, records) { service.agent_pull_request_listing(agent.key) }
      puts JSON.pretty_generate(records)
    end
  end

  def measure(stage, client, records)
    Thread.current[:pr_diff_spawn_count] = 0
    before = client.requests.length
    start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    result = yield
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - start
    start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    bytes = JSON.generate(result).bytesize
    serialization = Process.clock_gettime(Process::CLOCK_MONOTONIC) - start
    records << { stage:, service_ms: (elapsed * 1000).round(2), serialization_ms: (serialization * 1000).round(2),
                 bytes:, provider_calls: client.requests.length - before, subprocesses: Thread.current[:pr_diff_spawn_count] }
    result
  ensure
    Thread.current[:pr_diff_spawn_count] = nil
  end
end

PRDiffPerformance.run! if $PROGRAM_NAME == __FILE__
