# frozen_string_literal: true

require "open3"

module RemoteUIAttachmentFilterTest
  module_function

  def run!
    script = <<~'JS'
      const fs = require("node:fs");
      const vm = require("node:vm");
      const assert = require("node:assert/strict");
      const source = fs.readFileSync("lib/hq/remote_ui/assets/app.js", "utf8");
      const context = { window: {}, URL, URLSearchParams, attachmentTypeFilters: new Map(),
        escapeAttr: String, escapeHtml: String };
      vm.createContext(context);
      vm.runInContext(fs.readFileSync("lib/hq/remote_ui/assets/app_helpers.js", "utf8"), context);
      context.REMOTE_HELPERS = context.window.TychoRemoteHelpers;
      for (const [start, end] of [
        ["function attachmentFilterType(", "function renderAgentAttachments("],
        ["function agentAttachments(", "function attachmentId("],
        ["function attachmentKind(", "function attachmentIcon("],
        ["function attachmentTarget(", "function attachmentTargetForMatch("],
        ["function attachmentFormat(", "function renderHtmlAttachment("],
      ]) {
        const offset = source.indexOf(start);
        const limit = source.indexOf(end, offset);
        assert(offset >= 0 && limit > offset, `source range ${start}`);
        vm.runInContext(source.slice(offset, limit), context);
      }
      const records = [
        { type: "file", path: "/diagram.png", title: "same" },
        { type: "file", path: "/diagram.png", title: "duplicate" },
        { type: "file", path: "/notes.md", title: "same" },
        { type: "file", path: "/binary.unknown" },
        { type: "link", url: "https://example.test/image.png" },
        { type: "future", path: "/unknown" },
        { path: "/mime", mime_type: "image/jpeg" },
        { path: "/format", format: "image" },
        { url: "https://example.test/legacy" },
      ];
      const agent = { key: "first", attachments: records };
      const list = context.agentAttachments(agent);
      assert.equal(list.length, 8, "counts follow existing target deduplication");
      assert.equal(context.filteredAgentAttachments(agent, list).length, 8, "All is default");
      const expected = { images: 3, files: 3, links: 2 };
      for (const [type, count] of Object.entries(expected)) {
        context.attachmentTypeFilters.set(agent.key, type);
        const filtered = context.filteredAgentAttachments(agent, list);
        assert.equal(filtered.length, count, type);
        assert(filtered.every(item => context.attachmentFilterType(item) === type));
        const html = context.renderAttachmentTypeFilters(agent, list, "flyout");
        assert(html.includes(`aria-label="${type[0].toUpperCase() + type.slice(1)} (${count})`));
        assert(html.includes(`${count} of 8 shown`));
      }
      assert.equal(context.attachmentFilterType({ type: "future", path: "/unknown" }), "files");
      context.attachmentTypeFilters.set(agent.key, "images");
      assert.equal(context.filteredAgentAttachments(agent, []).length, 0);
      assert(context.renderAttachmentFilterEmpty().includes("Select All"));
      const updated = context.agentAttachments({ ...agent, attachments: [...records, { path: "/new.webp" }] });
      assert.equal(context.filteredAgentAttachments(agent, updated).length, 4, "metadata updates use current filter");
      assert.equal(context.filteredAgentAttachments({ key: "second" }, list).length, 8, "agent scope is independent");
      context.attachmentTypeFilters.set(agent.key, "all");
      assert.equal(context.filteredAgentAttachments(agent, updated).length, 9, "All clears filtering");
      context.attachmentTypeFilters.set(agent.key, "future-filter");
      assert.equal(context.filteredAgentAttachments(agent, list).length, 8, "unknown filter resets safely");
      assert.equal(list.filter(item => item.title === "same").length, 2, "same title does not merge different targets");
      console.log("remote_ui_attachment_filter_test: ok");
    JS
    out, err, status = Open3.capture3("node", "-e", script, chdir: File.expand_path("..", __dir__))
    raise "#{out}\n#{err}" unless status.success?

    puts out
  end
end

RemoteUIAttachmentFilterTest.run! if $PROGRAM_NAME == __FILE__
