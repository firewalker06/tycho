# frozen_string_literal: true

require "open3"

module RemoteUIStateReconciliationTest
  module_function

  ROOT = File.expand_path("..", __dir__)
  HELPERS_PATH = File.join(ROOT, "lib", "hq", "remote_ui", "assets", "app_helpers.js")

  def run!
    script = <<~'JAVASCRIPT'
      const fs = require("fs");
      const vm = require("vm");
      const context = { window: {}, URL, URLSearchParams };
      vm.createContext(context);
      vm.runInContext(fs.readFileSync(process.argv[1], "utf8"), context);

      const helpers = context.window.TychoRemoteHelpers;
      const attachment = { id: "report", type: "file", path: "/tmp/report.md" };
      const detail = { key: "agent-1", revision: "old", attachments: [attachment], workspace: "/tmp/work" };
      const catalog = { key: "agent-1", revision: "new", status: "succeeded", summary: "Done" };
      const reconciled = helpers.reconcileAgentDetail(detail, catalog);

      if (reconciled.attachments?.[0]?.id !== "report") {
        throw new Error("catalog reconciliation dropped existing detail attachments");
      }
      if (reconciled.revision !== "new" || reconciled.status !== "succeeded" || reconciled.detail_stale !== true) {
        throw new Error(`catalog reconciliation did not mark the merged detail stale: ${JSON.stringify(reconciled)}`);
      }

      const activityServers = helpers.mergeActivityServers(
        [
          { key: "healthy", ready: true, agents: [{ key: "healthy-old" }] },
          { key: "failing", ready: true, agents: [{ key: "retained" }] },
        ],
        [
          { serverKey: "healthy", ready: true, revision: "2", agents: [{ key: "healthy-new" }] },
          { serverKey: "failing", failed: true, status: 503, retryAfterMs: 3000, error: "Activity unavailable" },
        ]
      );
      if (activityServers[0].agents[0].key !== "healthy-new") {
        throw new Error("failing peer prevented a healthy peer activity update");
      }
      if (activityServers[1].agents[0].key !== "retained" || activityServers[1].ready !== false ||
          activityServers[1].activity_status !== 503 || activityServers[1].activity_retry_after_ms !== 3000) {
        throw new Error(`recoverable peer failure lost stale activity or retry context: ${JSON.stringify(activityServers[1])}`);
      }

      let failingCircuit = null;
      failingCircuit = helpers.nextActivityPollingFailure(failingCircuit, { status: 503, message: "unavailable" });
      if (failingCircuit.failures !== 1 || failingCircuit.stopped || !helpers.shouldPollServerActivity(failingCircuit)) {
        throw new Error(`first activity failure did not keep automatic polling active: ${JSON.stringify(failingCircuit)}`);
      }
      failingCircuit = helpers.nextActivityPollingFailure(failingCircuit, { status: 503, message: "unavailable" });
      failingCircuit = helpers.nextActivityPollingFailure(failingCircuit, { status: 503, message: "unavailable" });
      if (failingCircuit.failures !== 3 || !failingCircuit.stopped || helpers.shouldPollServerActivity(failingCircuit)) {
        throw new Error(`third activity failure did not stop only that server: ${JSON.stringify(failingCircuit)}`);
      }
      if (!helpers.shouldPollServerActivity(failingCircuit, { manual: true })) {
        throw new Error("manual activity refresh could not retry a stopped server");
      }
      const failedManualCircuit = helpers.nextActivityPollingFailure(failingCircuit, { status: 503, message: "unavailable" });
      if (!failedManualCircuit.stopped || helpers.shouldPollServerActivity(failedManualCircuit)) {
        throw new Error("a failed manual activity refresh resumed automatic polling");
      }

      const healthyCircuit = helpers.nextActivityPollingFailure(null, { status: 503, message: "unavailable" });
      if (!helpers.shouldPollServerActivity(healthyCircuit) || healthyCircuit.stopped) {
        throw new Error("a failing peer stopped healthy peer activity polling");
      }
      if (helpers.nextActivityPollingFailure(failingCircuit, { name: "AbortError", status: 503 }) !== failingCircuit) {
        throw new Error("aborted activity fetch changed the server failure state");
      }
      const failureMap = new Map([["failing", failingCircuit]]);
      helpers.clearActivityPollingFailure(failureMap, "failing");
      const recoveredCircuit = failureMap.get("failing");
      if (!helpers.shouldPollServerActivity(recoveredCircuit)) {
        throw new Error("successful manual activity refresh did not resume automatic polling");
      }
    JAVASCRIPT

    _stdout, stderr, status = Open3.capture3("node", "-e", script, HELPERS_PATH, chdir: ROOT)
    raise "Remote UI state reconciliation regression failed: #{stderr.strip}" unless status.success?

    puts "remote_ui_state_reconciliation_test: ok"
  end
end

RemoteUIStateReconciliationTest.run! if $PROGRAM_NAME == __FILE__
