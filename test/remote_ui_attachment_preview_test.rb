# frozen_string_literal: true

require "open3"
require "tempfile"

module RemoteUIAttachmentPreviewTest
  module_function

  ROOT = File.expand_path("..", __dir__)

  def run!
    Tempfile.create(["tycho-attachment-preview", ".js"]) do |script|
      script.write(<<~'JS')
        const fs = require("fs");
        const vm = require("vm");
        const source = fs.readFileSync("lib/hq/remote_ui/assets/app.js", "utf8");
        const start = source.indexOf("function summaryAttachmentPreviewAvailable");
        const end = source.indexOf("\nfunction renderSummaryAttachmentList", start);
        const agent = { key: "a", run_count: 1, current_run_id: "run-1", attachments: [{ id: "one" }, { id: "two" }] };
        let route = { type: "agentSummary", key: "a", summaryId: "summary-1" };
        let wide = true;
        let pending = [];
        let renders = 0;
        let navigation;
        let summary = { id: "summary-1", runNumber: 1, createdAt: "today" };
        const context = {
          state: { summaryAttachmentPreview: null, attachmentDetails: {} },
          window: { matchMedia: () => ({ matches: wide }) },
          document: { querySelector: () => null, querySelectorAll: () => [] },
          parseRoute: () => route,
          findAgent: (key) => key === agent.key ? agent : null,
          agentAttachments: (value) => value.attachments,
          attachmentId: (value) => value.id,
          agentSummaryDetail: () => summary,
          navigate: (value) => { navigation = value; },
          closeSummaryAttachmentMenus: () => {},
          render: () => { renders += 1; },
          ensureAttachment: (id) => new Promise((resolve, reject) => pending.push({ id, resolve, reject })),
          attachmentFormat: () => "markdown",
        };
        vm.runInNewContext(source.slice(start, end), context);
        function assert(value, message) { if (!value) throw new Error(message); }
        function complete(request, value) { context.state.attachmentDetails[request.id] = value; request.resolve(); }
        async function main() {
          const first = context.openSummaryAttachmentPreview("one", "a");
          const second = context.openSummaryAttachmentPreview("two", "a");
          const beforeStale = renders;
          complete(pending[0], { id: "one", agent_key: "a" });
          await first;
          assert(renders === beforeStale && context.state.summaryAttachmentPreview.id === "two", "A slow previous attachment replaced current selection");
          complete(pending[1], { id: "two", agent_key: "a" });
          await second;
          assert(!context.state.summaryAttachmentPreview.loading, "Current selection never completed");
          agent.run_count += 1;
          context.reconcileSummaryAttachmentPreview();
          assert(context.state.summaryAttachmentPreview === null, "New run retained stale attachment");

          const wrongOwner = context.openSummaryAttachmentPreview("one", "a");
          complete(pending[2], { id: "one", agent_key: "b" });
          await wrongOwner;
          assert(context.state.summaryAttachmentPreview.error.includes("not part"), "Cross-agent metadata was displayed");
          route = { type: "agentSummary", key: "a", summaryId: "summary-2" };
          context.reconcileSummaryAttachmentPreview();
          assert(context.state.summaryAttachmentPreview === null, "Run navigation retained stale attachment");

          const missing = context.openSummaryAttachmentPreview("one", "a");
          complete(pending[3], null);
          await missing;
          assert(context.state.summaryAttachmentPreview.error.includes("not found"), "404 metadata has no visible error");
          agent.attachments = [{ id: "two" }];
          context.reconcileSummaryAttachmentPreview();
          assert(context.state.summaryAttachmentPreview === null, "Deleted attachment retained stale preview");

          const failed = context.openSummaryAttachmentPreview("two", "a");
          pending[4].reject(new Error("Authentication required"));
          await failed;
          assert(context.state.summaryAttachmentPreview.error === "Authentication required", "Authorization error was hidden");
          context.state.summaryAttachmentPreview = null;
          wide = false;
          await context.openSummaryAttachmentPreview("two", "a");
          assert(navigation.type === "agentAttachment" && navigation.attachmentId === "two" && context.state.summaryAttachmentPreview === null, "Narrow screen bypassed existing detail route");
          wide = true;
          route = { type: "agentSummary", key: "a", summaryId: "summary-2" };
          const navigating = context.openSummaryAttachmentPreview("two", "a");
          route = { type: "agentSummary", key: "b" };
          context.reconcileSummaryAttachmentPreview();
          const beforeNavigation = renders;
          complete(pending[5], { id: "two", agent_key: "a" });
          await navigating;
          assert(context.state.summaryAttachmentPreview === null && renders === beforeNavigation, "A completed request reopened a preview after agent navigation");
        }
        main().catch((error) => { console.error(error); process.exit(1); });
      JS
      script.flush
      out, err, status = Open3.capture3("node", script.path, chdir: ROOT)
      raise "Attachment preview state regression failed:\n#{out}#{err}" unless status.success?
    end
    puts "remote_ui_attachment_preview_test: ok"
  end
end

RemoteUIAttachmentPreviewTest.run! if $PROGRAM_NAME == __FILE__
