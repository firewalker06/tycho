# frozen_string_literal: true

require_relative "../../lib/hq/domain/agent_store"
require_relative "../../lib/hq/registry"

registry = HQ::Registry.new(path: ENV.fetch("TYCHO_CONFIG_PATH"), system_prompts_path: ENV.fetch("TYCHO_SYSTEM_PROMPTS_PATH"))
store = HQ::AgentStore.new(registry.projects)
agents = 32.times.map do |index|
  key = "web-inquiry-recovery-#{index}"
  agent = HQ::ManagedAgent.new(key:, name: "Answer recovery", project_key: "web", template_key: "custom",
                               workspace: ARGV.fetch(0), prompt: "Synthetic inquiry fixture", agent: "codex",
                               log_path: File.join(HQ::AGENT_LOGS_DIR, "#{key}.raw.log"))
  run = HQ::ManagedAgent::AgentRun.new(started_at: Time.now - 2, finished_at: Time.now - 1, status: "input_required", log_path: agent.raw_log_path)
  agent.runs << run
  question = { "message" => "Which synthetic option?", "fields" => [{ "key" => "choice", "label" => "Your answer", "input_type" => "text", "required" => true }] }
  agent.structured_result = { "status" => "input_required", "summary" => "Synthetic inquiry", "inquiry" => question }
  id = agent.send(:inquiry_identity, question, run:)
  HQ::AgentMemory.new(agent).append_inquiry_request!(question, created_at: run.finished_at, inquiry_id: id)
  agent
end
store.save(agents)
