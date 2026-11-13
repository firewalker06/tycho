# frozen_string_literal: true

require_relative "../../lib/hq/domain/managed_agent"

module SummaryLinksFixture
  module_function

  def build(root, workspace)
    FileUtils.mkdir_p(File.join(root, "agents"))
    notes = File.join(workspace, "summary-notes.md")
    image = File.join(workspace, "summary-image.svg")
    File.write(notes, "# Synthetic notes\n\nThe local file still opens.\n")
    File.write(image, '<svg xmlns="http://www.w3.org/2000/svg" width="160" height="80"><rect width="160" height="80" fill="#89b4fa"/></svg>')
    link = { "type" => "link", "title" => "Change #42", "url" => "https://example.test/review/42?view=full&tab=files#diff" }
    sections = [
      { "type" => "text", "text" => "## Review complete\n\nUse the links and supporting files below." },
      { "type" => "link", "text" => link["title"], "url" => link["url"] },
      { "type" => "attachment", "attachment" => { "type" => "link", "title" => "Review report", "url" => "https://example.test/report" } },
      { "type" => "attachment", "attachment" => { "type" => "file", "title" => "Local notes", "path" => notes } },
      { "type" => "attachment", "attachment" => { "type" => "file", "title" => "Local image", "path" => image } }
    ]
    agent = HQ::ManagedAgent.new(
      key: "web-agent-summary-links", name: "Summary link example", project_key: "web", template_key: "custom",
      workspace:, prompt: "Synthetic link fixture", agent: "codex", model: "gpt-6.1-sol",
      log_path: File.join(root, "agents", "summary-links.raw.log")
    )
    result = HQ::AgentResultNormalizer.new(workspace:).normalize_structured_result(
      "status" => "success", "summary" => "Review complete.", "attachments" => [link], "summary_sections" => sections
    )
    2.times do |index|
      time = Time.utc(2026, 11, 13, 8, index)
      agent.runs << HQ::ManagedAgent::AgentRun.new(run_id: "fixture-#{index + 1}", started_at: time,
                                                finished_at: time + 10, status: "success", exit_code: 0)
      # The old Summary has no resource registration. Its link must still open.
      metadata = index.zero? ? { "summary_sections" => sections.take(2) } : result.slice("attachments", "summary_sections")
      HQ::AgentMemory.new(agent).append_run_summary!(
        summary: "Review complete.", status: "success", created_at: time + 10,
        metadata: metadata.merge("summary_id" => "links-#{index + 1}", "run_id" => "fixture-#{index + 1}", "run_number" => index + 1)
      )
    end
    agent.structured_result = result
    agent.summary = result["summary"]
    File.write(File.join(root, "managed_agents.json"), JSON.generate([agent.to_hash]))
  end
end

SummaryLinksFixture.build(ENV.fetch("TYCHO_LOGS_ROOT"), ARGV.fetch(0)) if $PROGRAM_NAME == __FILE__
