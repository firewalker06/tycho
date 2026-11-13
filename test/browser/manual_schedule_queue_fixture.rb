# frozen_string_literal: true

require_relative "../../lib/hq/domain/agent_store"
require_relative "../../lib/hq/registry"

raise "Temporary smoke store required" unless HQ::AGENTS_FILE.include?("tycho-remote-ui-smoke")
registry = HQ::Registry.new(path: ENV.fetch("TYCHO_CONFIG_PATH"), system_prompts_path: ENV.fetch("TYCHO_SYSTEM_PROMPTS_PATH"))
workspace = ARGV.fetch(0)
agents = []
states = {}
config = { "schedules" => [] }
%w[paused stopped].each do |status|
  [1440, 390].each do |width|
    %w[dark light].each do |theme|
      key = "manual-#{status}-#{width}-#{theme}"
      agent = HQ::ManagedAgent.new(key:, name: "#{status.capitalize} schedule queue", project_key: "web",
        template_key: "custom", workspace:, prompt: "Synthetic queue example", agent: "codex", schedule_key: key,
        log_path: File.join(HQ::AGENT_LOGS_DIR, "#{key}.raw.log"),
        runs: [HQ::ManagedAgent::AgentRun.new(run_id: "initial-#{key}", status: "stopped",
          started_at: Time.now - 60, finished_at: Time.now - 50, exit_code: 0)])
      agent.enqueue_prompt!(id: "first", prompt: "Prepare the report", source: "user")
      agent.enqueue_prompt!(id: "later", prompt: "Check the next report", source: "user")
      inquiry_agent = HQ::ManagedAgent.from_hash(agent.to_hash.merge("key" => "#{key}-inquiry",
        "name" => "Inquiry blocks queue", "log_path" => File.join(HQ::AGENT_LOGS_DIR, "#{key}-inquiry.raw.log")))
      inquiry = { "message" => "Which report must be checked?", "fields" => [
        { "key" => "report", "label" => "Report", "input_type" => "text", "required" => true }
      ] }
      inquiry_agent.structured_result = { "status" => "input_required", "summary" => "Choose a report", "inquiry" => inquiry }
      inquiry_agent.last_run.status = "input_required"
      HQ::AgentMemory.new(inquiry_agent).append_inquiry_request!(inquiry, inquiry_id: "#{key}-question")
      agents.concat([agent, inquiry_agent])
      states[key] = HQ::ScheduleState.new(key:, status:, enabled: status != "paused", last_target_key: key,
        last_target_kind: "agent", stopped_reason: "operator", stop_id: "stop-#{key}")
      config["schedules"] << { "key" => key, "name" => "#{status.capitalize} schedule", "cron" => "0 9 * * 1-5",
        "target" => { "type" => "agent", "project_key" => "web", "message" => "Synthetic scheduled work" } }
    end
  end
end
File.write(ENV.fetch("TYCHO_SCHEDULES_PATH"), YAML.dump(config))
HQ::AgentStore.new(registry.projects).save(agents)
HQ::ScheduleStore.new.save(states)
