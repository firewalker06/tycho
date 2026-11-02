# frozen_string_literal: true

require "open3"

module RemoteUISummaryCostTest
  module_function

  def run!
    script = <<~'JS'
      const fs = require("node:fs"), vm = require("node:vm"), assert = require("node:assert/strict");
      const source = fs.readFileSync("lib/hq/remote_ui/assets/app.js", "utf8");
      const context = {
        state: { conversations: {} }, escapeHtml: String, escapeAttr: String,
        normalizedSummarySections: () => [], usableRunSummaryContent: () => true,
        runSummaryDetailContent: block => block.content, runSummaryNumber: block => block.metadata.run_number,
        runSummaryId: block => block.metadata.summary_id, statusLabel: () => "success",
        timeShort: () => "", summaryOutcomeValueInline: () => "success", kv: (label, value) => `${label}:${value}`,
        runSummaryNavigation: () => ({}), renderSummaryNavigationButton: () => "",
        renderSummaryFreshnessRegion: () => "", renderAgentSummaryContent: () => "",
        renderSummaryDelegatedActions: () => "", renderSummaryAttachmentList: () => "",
        summaryAttachmentsOutsideSections: () => [], renderAgentFloatingActions: () => ""
      };
      vm.createContext(context);
      for (const [start, end] of [
        ["function renderAgentSummaryView(", "function renderSummaryFreshnessRegion("],
        ["function latestRunSummaryFromAgent(", "function usableRunSummaryContent("],
        ["function sessionCostSnapshotText(", "function runSummaryNavigation("],
        ["function formatCurrencyMetric(", "function formatDurationMetric("]
      ]) {
        const offset = source.indexOf(start), limit = source.indexOf(end, offset);
        assert(offset >= 0 && limit > offset);
        vm.runInContext(source.slice(offset, limit), context);
      }
      const latest = { session_id: "first", amount_usd: 30.774118, run_amount_usd: 0.6030092, run_cost_scope: "run" };
      const selected = { session_id: "first", amount_usd: 30.1711088, run_amount_usd: 0.0579388, run_cost_scope: "run" };
      const agent = { key: "fixture", run_count: 127, cost_snapshot: latest };
      const blocks = context.state.conversations.fixture = { blocks: [] };
      const block = (id, snapshot) => ({ kind: "run_summary", content: "Saved summary", metadata: { summary_id: id, run_number: Number(id), status: "success", cost_snapshot: snapshot } });
      blocks.blocks = [block("126", selected), block("127", latest)];
      assert.equal(context.agentSummaryDetail(agent, "126").costSnapshot.amount_usd, 30.1711088);
      const render = () => context.renderAgentSummaryView(agent, { summaryId: "126" });
      let html = render();
      assert(html.includes("Est. total cost:$30.17"), html);
      assert(!html.includes("$0.0579") && !html.includes("$30.77"), "use selected total, not run or live cost");
      for (const [snapshot, expected] of [
        [{ session_id: "new-native-session", amount_usd: 0.5, run_amount_usd: 0.1 }, "$0.5000"],
        [{ amount_usd: 2.5, run_amount_usd: 0.5, run_cost_scope: "run" }, "$2.50"],
        [{ amount_usd: 2.5, run_amount_usd: 0.5, run_cost_scope: "reported" }, "$2.50"],
        [{ amount_usd: 458.58, coverage: "partial" }, "$458.58+"],
        [{ amount_usd: 0 }, "$0.0000"],
        [{ run_amount_usd: 9 }, "Unavailable"],
        [{ amount_usd: null }, "Unavailable"],
        [{ amount_usd: Infinity }, "Unavailable"],
        [null, "Untracked"]
      ]) {
        blocks.blocks[0] = block("126", snapshot);
        html = render();
        assert(html.includes(`Est. total cost:${expected}`), html);
        assert(!html.includes("$30.77"), "never borrow live total or combine native sessions");
      }
      console.log("remote_ui_summary_cost_test: ok");
    JS
    out, err, status = Open3.capture3("node", "-e", script, chdir: File.expand_path("..", __dir__))
    raise "#{out}\n#{err}" unless status.success?

    puts out
  end
end

RemoteUISummaryCostTest.run! if $PROGRAM_NAME == __FILE__
