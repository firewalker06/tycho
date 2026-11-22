# frozen_string_literal: true

require_relative "../../lib/hq/domain/managed_agent"

module SummaryAttachmentLayoutFixture
  module_function

  def build(root, workspace)
    FileUtils.mkdir_p(File.join(workspace, "exports", "updated", "review", "final"))
    names = [
      "Quarterly access review — final presentation with approved speaker notes.pptx",
      "Quarterly access review — supporting report with complete findings.pdf"
    ]
    paths = names.map { |name| File.join(workspace, "exports", "updated", "review", "final", name) }
    paths.each { |path| File.write(path, "Synthetic attachment content\n") }
    attachments = names.zip(paths).map { |name, path| { "type" => "file", "title" => name, "path" => path } }
    agent = HQ::ManagedAgent.new(
      key: "web-agent-summary-layout", name: "Summary attachment layout", project_key: "web", template_key: "custom",
      workspace:, prompt: "Synthetic long attachment fixture", agent: "codex", model: "gpt-6.1-sol",
      log_path: File.join(root, "agents", "summary-layout.raw.log")
    )
    result = HQ::AgentResultNormalizer.new(workspace:).normalize_structured_result(
      "status" => "success", "summary" => "Long attachment layout fixture.", "attachments" => attachments,
      "summary_sections" => [
        { "type" => "text", "text" => "Delayed update layout fixture." },
        *attachments.map { |attachment| { "type" => "attachment", "attachment" => attachment } }
      ]
    )
    2.times do |index|
      time = Time.utc(2026, 11, 22, 4, index)
      agent.runs << HQ::ManagedAgent::AgentRun.new(run_id: "layout-#{index + 1}", started_at: time,
                                                finished_at: time + 10, status: "success", exit_code: 0)
      HQ::AgentMemory.new(agent).append_run_summary!(
        summary: result.fetch("summary"), status: "success", created_at: time + 10,
        metadata: result.slice("attachments", "summary_sections").merge("summary_id" => "layout-#{index + 1}", "run_id" => "layout-#{index + 1}", "run_number" => index + 1)
      )
    end
    agent.structured_result = result
    agent.summary = result.fetch("summary")
    File.write(File.join(root, "managed_agents.json"), JSON.generate([agent.to_hash]))
  end
end

SummaryAttachmentLayoutFixture.build(ENV.fetch("TYCHO_LOGS_ROOT"), ARGV.fetch(0)) if $PROGRAM_NAME == __FILE__
