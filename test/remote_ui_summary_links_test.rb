# frozen_string_literal: true

require "open3"
require "tmpdir"
require_relative "../lib/hq/domain/agent_result_normalizer"

module RemoteUISummaryLinksTest
  module_function

  def run!
    Dir.mktmpdir("summary-links-test") do |dir|
      normalizer = HQ::AgentResultNormalizer.new(workspace: dir)
      link = { "type" => "link", "title" => "Change #42", "url" => "https://example.test/review/42?view=full&tab=files#diff" }
      file = File.join(dir, "notes.md")
      File.write(file, "Synthetic notes")
      result = normalizer.normalize_structured_result(
        "status" => "success", "summary" => "Review complete.",
        "attachments" => [link, { "type" => "file", "title" => "Notes", "path" => file }],
        "summary_sections" => [
          { "type" => "link", "text" => link["title"], "url" => link["url"] },
          { "type" => "link", "text" => "Only in Summary", "url" => "https://example.test/only" },
          { "type" => "attachment", "attachment" => link },
          { "type" => "link", "text" => "Unsafe", "url" => "javascript:alert(1)" }
        ]
      )
      targets = result.fetch("attachments").map { |item| [item["type"], item["url"] || item["path"]] }
      raise "Summary-only links must join resources once as links: #{targets}" unless targets == [
        ["link", link["url"]], ["file", file], ["link", "https://example.test/only"]
      ]
    end
    script = <<~'JS'
      const fs = require("node:fs"), vm = require("node:vm"), assert = require("node:assert/strict");
      const source = fs.readFileSync("lib/hq/remote_ui/assets/app.js", "utf8");
      const context = { window: {}, state: { agents: [], agentDetails: {} }, iconSvg: () => "", renderMarkdown: text => text };
      vm.createContext(context);
      vm.runInContext(fs.readFileSync("lib/hq/remote_ui/assets/app_helpers.js", "utf8"), context);
      context.REMOTE_HELPERS = context.window.TychoRemoteHelpers;
      function load(name) {
        const start = source.indexOf(`function ${name}(`), end = source.indexOf("\nfunction ", start + 1);
        assert(start >= 0 && end > start, name);
        vm.runInContext(source.slice(start, end), context);
      }
      for (const name of ["normalizedSummarySections", "renderSummarySections", "summarySectionAttachment", "summaryAttachmentsOutsideSections",
        "renderSummaryAttachmentRow", "currentSummaryAttachment", "attachmentById", "attachmentId", "attachmentKind",
        "attachmentKindLabel", "attachmentKindIcon", "attachmentIcon", "attachmentHref", "attachmentTarget",
        "attachmentTargetLabel", "attachmentDownloadHref", "escapeHtml", "escapeAttr", "formatBytes"]) load(name);
      const url = "https://example.test/review/42?view=full&tab=files#diff";
      const link = {type: "link", title: 'Change <42> "review"', url};
      const section = {type: "link", text: link.title, url};
      const agent = {key: "fixture", attachments: []};
      for (const block of [section, {type: "attachment", attachment: link}]) {
        const html = context.renderSummarySections([block], agent);
        assert(html.includes('class="summary-attachment-row"'), html);
        assert(html.includes('href="https://example.test/review/42?view=full&amp;tab=files#diff"'), html);
        assert(html.includes('target="_blank" rel="noreferrer"'), html);
        assert(html.includes('Change &lt;42&gt; &quot;review&quot;'), html);
        assert(!html.includes('data-download-attachment') && !html.includes('data-preview-summary-attachment'), html);
      }
      assert.equal(context.summaryAttachmentsOutsideSections([link], [section]).length, 0, "no duplicate footer link");
      for (const url of ["javascript:alert(1)", "data:text/html,bad", "file:///tmp/notes.md", "//example.test/path"]) {
        assert.equal(context.normalizedSummarySections([{type: "link", text: "Unsafe", url}]).length, 0);
      }
      console.log("remote_ui_summary_links_test: ok");
    JS
    out, err, status = Open3.capture3("node", "-e", script, chdir: File.expand_path("..", __dir__))
    raise "#{out}\n#{err}" unless status.success?

    puts out
  end
end

RemoteUISummaryLinksTest.run! if $PROGRAM_NAME == __FILE__
