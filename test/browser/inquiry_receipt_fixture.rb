# frozen_string_literal: true

require_relative "../../lib/hq/domain/agent_store"
require_relative "../../lib/hq/registry"

registry = HQ::Registry.new(path: ENV.fetch("TYCHO_CONFIG_PATH"), system_prompts_path: ENV.fetch("TYCHO_SYSTEM_PROMPTS_PATH"))
store = HQ::AgentStore.new(registry.projects)
raise "Temporary smoke store required" unless HQ::AGENTS_FILE.include?("tycho-remote-ui-smoke")

if ARGV.first == "--wait"
  deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 15
  observed = []
  loop do
    agents, = store.read_snapshot
    pids = agents.flat_map do |agent|
      agent.runs.filter_map do |run|
        next if run.run_id.to_s.empty?

        path = agent.send(:run_pid_file_path, run.run_id)
        Integer(File.read(path).strip) if File.exist?(path)
      rescue Errno::ENOENT
        nil
      end
    end.select { |pid| pid > 1 }.uniq
    observed |= pids
    alive = pids.select do |pid|
      Process.kill(0, pid)
      true
    rescue Errno::ESRCH
      false
    end
    break if alive.empty?
    raise "Synthetic inquiry runners did not exit before teardown" if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

    sleep 0.05
  end
  puts "Synthetic inquiry runners settled (#{observed.length} recorded PIDs)"
  exit
end

if ARGV.first == "--advance"
  key = ARGV.fetch(1)
  raise "Synthetic inquiry key required" unless key.start_with?("web-inquiry-recovery-")

  id = store.mutate(dispatch_prompt_queues: false) do |agents, _events|
    agent = agents.find { |candidate| candidate.key == key } || raise("Synthetic agent missing")
    run = HQ::ManagedAgent::AgentRun.new(started_at: Time.now - 2, finished_at: Time.now - 1, status: "input_required", log_path: agent.raw_log_path)
    agent.runs << run
    question = { "message" => "Newer inquiry B", "fields" => [{ "key" => "choice", "label" => "Your answer", "input_type" => "text", "required" => true }] }
    agent.structured_result = { "status" => "input_required", "summary" => "Synthetic newer inquiry", "inquiry" => question }
    inquiry_id = agent.send(:inquiry_identity, question, run:)
    HQ::AgentMemory.new(agent).append_inquiry_request!(question, created_at: run.finished_at, inquiry_id:)
    inquiry_id
  end
  puts id
  exit
end

review_fields = if ENV["TYCHO_REMOTE_UI_INQUIRY_BLOCKER_CASE"] == "blocker-multiselect-comma"
                  [{ "key" => "regions", "label" => "Regions", "input_type" => "multi_select", "options" => ["Jakarta, Indonesia", "Tokyo"], "required" => true }]
                elsif ["blocker-schema-correction", "blocker-attachment-correction"].include?(ENV["TYCHO_REMOTE_UI_INQUIRY_BLOCKER_CASE"])
                  [
                    { "key" => "choice", "label" => "Your answer", "input_type" => "text", "required" => true },
                    { "key" => "regions", "label" => "Regions", "input_type" => "multi_select", "options" => ["Jakarta, Indonesia", "Tokyo"], "required" => true }
                  ]
                elsif ENV["TYCHO_REMOTE_UI_INQUIRY_BLOCKER_CASE"] == "blocker-complete-draft"
                  [
                    { "key" => "choice", "label" => "Your answer", "input_type" => "text", "required" => true },
                    { "key" => "regions", "label" => "Regions", "input_type" => "multi_select", "options" => ["Jakarta, Indonesia", "Tokyo"], "required" => true },
                    { "key" => "response", "label" => "Response", "input_type" => "multiline", "required" => true },
                    { "key" => "count", "label" => "Count", "input_type" => "integer", "required" => false },
                    { "key" => "city", "label" => "City", "input_type" => "select", "options" => ["Jakarta", "Tokyo"], "required" => false },
                    { "key" => "allowed", "label" => "Allowed", "input_type" => "boolean", "required" => false },
                    { "key" => "ratio", "label" => "Ratio", "input_type" => "number", "required" => false }
                  ]
                elsif ["blocker-remove-rejected", "blocker-file-add", "blocker-rejected-remove-race"].include?(ENV["TYCHO_REMOTE_UI_INQUIRY_BLOCKER_CASE"])
                  [
                    { "key" => "choice", "label" => "Your answer", "input_type" => "text", "required" => true },
                    { "key" => "regions", "label" => "Regions", "input_type" => "multi_select", "options" => ["Jakarta, Indonesia", "Tokyo"], "required" => true }
                  ]
                elsif ENV["TYCHO_REMOTE_UI_INQUIRY_BLOCKER_CASE"] == "blocker-durable-rejection-correction"
                  [
                    { "key" => "choice", "label" => "Your answer", "input_type" => "text", "required" => true },
                    { "key" => "regions", "label" => "Regions", "input_type" => "multi_select", "options" => ["Jakarta, Indonesia", "Tokyo"], "required" => true }
                  ]
                else
                  [{ "key" => "choice", "label" => "Your answer", "input_type" => "text", "required" => true }]
                end

agents = 64.times.map do |index|
  key = "web-inquiry-recovery-#{index}"
  agent = HQ::ManagedAgent.new(key:, name: "Answer recovery", project_key: "web", template_key: "custom",
                               workspace: ARGV.fetch(0), prompt: "Synthetic inquiry fixture", agent: "codex",
                               log_path: File.join(HQ::AGENT_LOGS_DIR, "#{key}.raw.log"))
  run = HQ::ManagedAgent::AgentRun.new(started_at: Time.now - 2, finished_at: Time.now - 1, status: "input_required", log_path: agent.raw_log_path)
  agent.runs << run
  question = { "message" => "Which synthetic option?", "fields" => review_fields }
  agent.structured_result = { "status" => "input_required", "summary" => "Synthetic inquiry", "inquiry" => question }
  id = agent.send(:inquiry_identity, question, run:)
  HQ::AgentMemory.new(agent).append_inquiry_request!(question, created_at: run.finished_at, inquiry_id: id)
  agent
end
store.save(agents)
