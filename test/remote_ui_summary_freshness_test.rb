# frozen_string_literal: true

require "open3"

module RemoteUISummaryFreshnessTest
  module_function

  ROOT = File.expand_path("..", __dir__)
  HELPERS_PATH = File.join(ROOT, "lib", "hq", "remote_ui", "assets", "app_helpers.js")
  APP_PATH = File.join(ROOT, "lib", "hq", "remote_ui", "assets", "app.js")

  def run!
    script = <<~'JAVASCRIPT'
      const fs = require("fs");
      const vm = require("vm");
      const context = { window: {} };
      vm.createContext(context);
      vm.runInContext(fs.readFileSync(process.argv[1], "utf8"), context);
      const summaryFreshness = context.window.TychoRemoteHelpers.summaryFreshness;
      const summary = { kind: "run_summary", created_at: "2026-09-28T01:00:00Z", metadata: { summary_id: "summary-1" } };
      const message = { kind: "message", created_at: "2026-09-28T01:01:00Z", content: "New follow-up" };
      const nextSummary = { kind: "run_summary", created_at: "2026-09-28T01:02:00Z", metadata: { summary_id: "summary-2" } };

      const current = summaryFreshness([summary], "summary-1");
      if (current.stale || current.newerSummaryId) throw new Error("current summary was marked stale");

      const staged = summaryFreshness([summary], "summary-1", { unseenCount: 2 });
      if (!staged.stale || staged.loading || staged.unseenCount !== 2) throw new Error("staged messages did not mark the summary stale");

      const loading = summaryFreshness([summary], "summary-1", { unseenCount: 2, loading: true });
      if (!loading.stale || !loading.loading) throw new Error("refresh action did not expose its loading state");

      const continued = summaryFreshness([summary, message], "summary-1");
      if (!continued.stale || continued.newerSummaryId) throw new Error("newer conversation did not mark the summary stale");

      const updated = summaryFreshness([summary, message, nextSummary], "summary-1");
      if (!updated.stale || updated.newerSummaryId !== "summary-2") throw new Error("newer summary was not identified");

      const latest = summaryFreshness([summary, message, nextSummary], "summary-2");
      if (latest.stale) throw new Error("updated latest summary remained stale");

      const app = fs.readFileSync(process.argv[2], "utf8");
      if (!app.includes("data-open-latest-summary-after-load") ||
          !app.includes("loadPendingConversationMessages(loadConversationButton.dataset.loadPendingConversation, {") ||
          !app.includes('navigate({ type: "agentSummary", key, summaryId: latestSummaryId });')) {
        throw new Error("Summary refresh action did not reuse the conversation loader and retain Summary navigation");
      }
      if (!app.includes('if (preserveWorkspace && focusedRoute.type === "agentSummary")') ||
          !app.includes("if (summaryAgent) await ensureConversation(summaryAgent);") ||
          !app.includes("syncFocusedSummaryFreshness(agent, route);") ||
          !app.includes("data-summary-freshness-region")) {
        throw new Error("Preserved Summary polling did not request conversation metadata and sync the stale indicator in place");
      }
    JAVASCRIPT

    _stdout, stderr, status = Open3.capture3("node", "-e", script, HELPERS_PATH, APP_PATH, chdir: ROOT)
    raise "summary freshness regression failed: #{stderr.strip}" unless status.success?

    puts "remote_ui_summary_freshness_test: ok"
  end
end

RemoteUISummaryFreshnessTest.run! if $PROGRAM_NAME == __FILE__
