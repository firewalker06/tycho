# frozen_string_literal: true

require "open3"

module RemoteUIPRDiffLoadingTest
  module_function

  def run!
    script = <<~'JS'
      const fs = require("node:fs"), vm = require("node:vm"), assert = require("node:assert/strict");
      const source = fs.readFileSync("lib/hq/remote_ui/assets/app.js", "utf8");
      const queue = source.slice(source.indexOf("function enqueuePullRequestDiffFetch("), source.indexOf("function touchPullRequestDiffData("));
      const cache = source.slice(source.indexOf("function touchPullRequestDiffData("), source.indexOf("function rememberPullRequestDiffPreloadFailure("));
      const batch = source.slice(source.indexOf("async function refreshAllPullRequestDiffs("), source.indexOf("async function deleteAttachment("));
      const requests = [], labels = [], renders = [];
      const state = { pullRequests: { agent: { items: Array.from({ length: 15 }, (_, i) => ({ id: `pr-${i}` })) } }, pullRequestDiffs: { "agent:pr-0": { snapshot_id: "previous", files: [] } }, pullRequestDiffFetches: {}, pullRequestDiffFetchQueue: [], pullRequestDiffsInFlight: 0, pullRequestDiffDataOrder: new Map([["agent:pr-0", true]]), pullRequestDiffPreloadFailures: new Set() };
      const context = { state, MAX_CONCURRENT_PR_DIFF_FETCHES: 3, MAX_CACHED_PR_DIFF_DATA: 8,
        pullRequestDiffKey: (agent, id) => `${agent}:${id}`,
        parseRoute: () => ({ type: "agentPullRequests", key: "agent", pullRequestId: "pr-14" }),
        selectedPullRequestId: (_, id) => id,
        setConnection: label => labels.push(label),
        render: () => renders.push(state.pullRequestDiffs["agent:pr-14"]?.snapshot_id),
        ensureAgentPullRequests: async () => {},
        rememberPullRequestDiffData: () => {}, rememberPullRequestDiffPreloadFailure: () => {},
        apiGet: () => { throw new Error("refresh must use POST"); },
        apiPost: path => new Promise((resolve, reject) => requests.push({ path, resolve, reject })),
      };
      vm.createContext(context); vm.runInContext(queue + cache + batch, context);
      const tick = () => new Promise(resolve => setImmediate(resolve));
      (async () => {
        const batch = context.refreshAllPullRequestDiffs("agent"); await tick();
        assert.equal(requests.length, 3); assert(requests[0].path.includes("pr-14/refresh"));
        await context.refreshAllPullRequestDiffs("agent"); assert.equal(requests.length, 3, "duplicate bulk action must coalesce");
        requests[0].resolve({ diff: { id: "pr-14", snapshot_id: "selected", files: [] } }); await tick();
        assert.equal(state.pullRequests.agent.items.at(-1).snapshot.snapshot_id, "selected");
        assert.equal(state.pullRequests.agent.items.at(-1).snapshot.fresh, undefined, "local completion must not invent provider freshness");
        assert(renders.includes("selected"), "selected result must render while the batch is pending");
        assert.equal(requests.length, 4); assert.equal(state.pullRequestDiffsInFlight, 3);
        requests[1].reject(new Error("Synthetic denied request")); await tick();
        assert.equal(state.pullRequestDiffs["agent:pr-0"].snapshot_id, "previous", "failed refresh must preserve saved data");
        let resolved = 2;
        while (resolved < 15) {
          await tick();
          while (resolved < requests.length) { const req = requests[resolved++]; req.resolve({ diff: { id: req.path.split("/").at(-2), snapshot_id: "saved", files: [] } }); }
          assert(state.pullRequestDiffsInFlight <= 3);
        }
        await batch;
        assert.equal(requests.length, 15); assert.equal(state.pullRequestDiffsInFlight, 0);
        assert.equal(Object.keys(state.pullRequestDiffFetches).length, 0);
        assert(labels.at(-1).includes("1 failure"));
        assert.equal(state.pullRequestDiffs["agent:pr-14"].snapshot_id, "selected");
        console.log("bounded progressive PR diff loading: ok");
      })().catch(error => { console.error(error); process.exitCode = 1; });
    JS
    out, err, status = Open3.capture3("node", "-e", script, chdir: File.expand_path("..", __dir__))
    raise "#{out}\n#{err}" unless status.success?

    puts "remote_ui_pr_diff_loading_test: ok"
  end
end

RemoteUIPRDiffLoadingTest.run! if $PROGRAM_NAME == __FILE__
