# frozen_string_literal: true

require "open3"

module RemoteUIInquiryCacheTest
  module_function

  ROOT = File.expand_path("..", __dir__)
  APP_PATH = File.join(ROOT, "lib", "hq", "remote_ui", "assets", "app.js")
  HELPERS_PATH = File.join(ROOT, "lib", "hq", "remote_ui", "assets", "app_helpers.js")

  # Runs the real app.js agent-detail and activity functions in a VM. The revision stays unchanged on
  # purpose: the card 692 bug shows up when the server answers an inquiry without a revision change.
  def run!
    script = <<~'JAVASCRIPT'
      (async () => {
        const fs = require("fs");
        const vm = require("vm");
        const source = fs.readFileSync(process.argv[1], "utf8");
        const helpersSource = fs.readFileSync(process.argv[2], "utf8");
        const helpersContext = { window: {}, URL, URLSearchParams };
        vm.createContext(helpersContext);
        vm.runInContext(helpersSource, helpersContext);

        function slice(from, to) {
          const start = source.indexOf(from);
          const end = source.indexOf(to, start + from.length);
          if (start < 0 || end < 0) throw new Error(`missing app.js block: ${from}`);
          return source.slice(start, end);
        }

        const calls = [];
        let serverAgent = null;
        const fetchServerAgent = async (path) => {
          calls.push(path);
          return { agent: serverAgent };
        };
        const context = {
          REMOTE_HELPERS: helpersContext.window.TychoRemoteHelpers,
          AGENT_ACTIVITY_FIELDS: [
            "name", "project_key", "template_key", "scheduled", "schedule_key", "agent", "model", "reasoning_effort",
            "status", "running", "unread", "awaiting_input", "blocked", "run_count", "current_run_id", "created_at",
            "started_at", "finished_at", "updated_at", "last_exit_code", "last_result", "summary", "archived",
            "archived_at", "delegation",
          ],
          state: { agentDetails: {}, agentDetailGenerations: new Map() },
          reconcileOptimisticPromptQueue: () => {},
          apiGet: fetchServerAgent,
        };
        vm.createContext(context);
        vm.runInContext(
          [
            slice("async function ensureAgentDetail", "\nasync function ensureNotification"),
            slice("function mergeAgentActivityFields", "\nfunction mergeAgentDelegation"),
            slice("function activityFields", "\nfunction applyAgentActivity"),
            "this.ensureAgentDetail = ensureAgentDetail;",
            "this.mergeAgentActivityFields = mergeAgentActivityFields;",
            "this.activityFields = activityFields;",
            "this.refreshAnsweredInquiry = typeof refreshAnsweredInquiry === 'function' ? refreshAnsweredInquiry : null;",
          ].join("\n"),
          context
        );

        const inquiry = (id) => ({ id, message: `Question ${id}`, fields: [] });
        const pending = { key: "a", revision: "r1", status: "awaiting-input", awaiting_input: true, latest_inquiry: inquiry("inq-1") };
        const answeredServer = { key: "a", revision: "r1", status: "running", awaiting_input: false, latest_inquiry: null };
        const cases = [];
        const check = async (name, fn) => {
          try {
            await fn();
            cases.push({ name, ok: true });
          } catch (error) {
            cases.push({ name, ok: false, error: error.message });
          }
        };
        const requireRefresh = () => {
          if (!context.refreshAnsweredInquiry) throw new Error("app.js has no answer refresh (refreshAnsweredInquiry)");
          return context.refreshAnsweredInquiry;
        };
        const reset = (detail) => {
          calls.length = 0;
          context.apiGet = fetchServerAgent;
          context.state.agentDetails = detail ? { a: { ...detail } } : {};
          context.state.agentDetailGenerations = new Map();
        };

        await check("activity poll marks an answered cached inquiry stale, so a revisit refetches it", async () => {
          reset(pending);
          serverAgent = answeredServer;
          const activity = context.activityFields({ key: "a", status: "running", awaiting_input: false });
          context.state.agentDetails.a = context.mergeAgentActivityFields(context.state.agentDetails.a, activity);
          await context.ensureAgentDetail("a");
          if (calls.length !== 1) throw new Error(`revisit did not refetch the detail (fetches: ${calls.length})`);
          if (context.state.agentDetails.a.latest_inquiry !== null) {
            throw new Error(`answered inquiry still cached: ${JSON.stringify(context.state.agentDetails.a.latest_inquiry)}`);
          }
        });

        await check("submit reloads the detail even when the revision is unchanged", async () => {
          reset(pending);
          serverAgent = answeredServer;
          await requireRefresh()("a");
          if (calls.length !== 1) throw new Error(`answer did not reload the detail (fetches: ${calls.length})`);
          if (context.state.agentDetails.a.latest_inquiry !== null) throw new Error("answered inquiry still cached after submit");
        });

        await check("an in-flight detail response from before the answer cannot restore the inquiry", async () => {
          reset(pending);
          let release;
          const staleResponse = new Promise((resolve) => { release = resolve; });
          context.apiGet = async (path) => {
            calls.push(path);
            if (calls.length === 1) return staleResponse;
            return { agent: answeredServer };
          };
          const inFlight = context.ensureAgentDetail("a", true);
          await requireRefresh()("a");
          release({ agent: pending });
          await inFlight;
          if (context.state.agentDetails.a.latest_inquiry !== null) {
            throw new Error(`stale response restored the answered inquiry: ${JSON.stringify(context.state.agentDetails.a.latest_inquiry)}`);
          }
        });

        await check("submit with no cached detail still loads the agent", async () => {
          reset(null);
          serverAgent = answeredServer;
          await requireRefresh()("a");
          if (!context.state.agentDetails.a || context.state.agentDetails.a.latest_inquiry !== null) {
            throw new Error(`no detail loaded after submit: ${JSON.stringify(context.state.agentDetails.a)}`);
          }
        });

        await check("a genuinely new inquiry after an answer stays visible", async () => {
          reset(pending);
          serverAgent = { key: "a", revision: "r1", status: "awaiting-input", awaiting_input: true, latest_inquiry: inquiry("inq-2") };
          await requireRefresh()("a");
          if (context.state.agentDetails.a.latest_inquiry?.id !== "inq-2") {
            throw new Error(`new inquiry was not kept: ${JSON.stringify(context.state.agentDetails.a.latest_inquiry)}`);
          }
        });

        await check("a pending inquiry is not invalidated by an activity poll", async () => {
          reset(pending);
          const activity = context.activityFields({ key: "a", status: "awaiting-input", awaiting_input: true });
          const merged = context.mergeAgentActivityFields(context.state.agentDetails.a, activity);
          if (merged.detail_stale === true || merged.latest_inquiry?.id !== "inq-1") {
            throw new Error(`pending inquiry was invalidated: ${JSON.stringify(merged)}`);
          }
        });

        for (const item of cases) console.log(`${item.ok ? "PASS" : "FAIL"} ${item.name}${item.ok ? "" : ` :: ${item.error}`}`);
        if (cases.some((item) => !item.ok)) process.exit(1);
      })().catch((error) => {
        console.error(error);
        process.exit(1);
      });
    JAVASCRIPT
    stdout, stderr, status = Open3.capture3("node", "-e", script, APP_PATH, HELPERS_PATH)
    puts stdout unless stdout.empty?
    raise "Remote UI inquiry cache regression failed: #{stderr.strip}" unless status.success?

    puts "remote_ui_inquiry_cache_test: ok"
  end
end

RemoteUIInquiryCacheTest.run!
