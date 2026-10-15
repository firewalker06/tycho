# frozen_string_literal: true

require "open3"

module RemoteUIConversationAnimationTest
  module_function

  def run!
    root = File.expand_path("..", __dir__)
    script = <<~'JS'
      const assert = require("node:assert/strict");
      const fs = require("node:fs");
      const vm = require("node:vm");
      const context = { window: {} };
      vm.createContext(context);
      vm.runInContext(fs.readFileSync(process.argv[1], "utf8"), context);
      const marker = context.window.TychoRemoteHelpers.conversationMarkerState;
      const agent = { key: "alpha", current_run_id: "run-1", status: "succeeded", running: false,
        last_result: "success", last_exit_code: 0, finished_at: "2026-10-15T03:00:00Z" };
      const summary = { kind: "run_summary", content: "Work complete", metadata: { status: "success", run_id: "run-1" } };
      assert.equal(marker(agent, [summary]).mode, "complete");
      assert.equal(marker(agent, [summary]).label, "You have reached the end.");
      const running = { ...agent, running: true, status: "running", finished_at: null };
      assert.equal(marker(running, [summary]).mode, "running");
      assert.equal(marker(running, [summary]).label, "Agent is working");
      assert.notEqual(marker(running, [summary]).key, marker(agent, [summary]).key);
      assert.equal(marker({ ...running, current_run_id: "run-2" }, [summary]).mode, "running");
      assert.equal(marker({ ...agent, current_run_id: "run-2" }, [summary]), null, "old success during a new run");
      assert.equal(marker(agent, []), null);
      assert.equal(marker(agent, null), null);
      assert.equal(marker(null, [summary]), null);
      for (const status of ["idle", "failed", "stopped", "partial", "blocked", "awaiting-input", "no_action_needed"]) {
        assert.equal(marker({ ...agent, status }, [summary]), null, status);
      }
      for (const last_result of ["no action", "failed", "partial", "awaiting input", "blocked", "stopped", null]) {
        assert.equal(marker({ ...agent, last_result }, [summary]), null, String(last_result));
      }
      for (const changed of [{ last_exit_code: 1 }, { last_exit_code: null }, { finished_at: null },
        { current_run_id: null }, { blocked: true }, { awaiting_input: true }, { running: true }]) {
        assert.equal(marker({ ...agent, ...changed }, [summary]), null, JSON.stringify(changed));
      }
      for (const changed of [{ content: " " }, { metadata: { status: "no_action_needed", run_id: "run-1" } },
        { metadata: { status: "success" } }, { metadata: { status: "failed", run_id: "run-1" } }]) {
        assert.equal(marker(agent, [{ ...summary, ...changed }]), null);
      }
      assert.equal(marker(agent, [summary, { kind: "message", role: "user", content: "Continue" }]), null);
      for (const options of [{ loading: true }, { unavailable: true }]) {
        assert.equal(marker(agent, [summary], options), null);
        assert.equal(marker(running, [summary], options), null);
      }
      assert.equal(marker({ ...running, running: false }, [summary]), null, "require an active process");

      // Revisit and loading recovery must use the resting pose for a run already seen.
      const source = fs.readFileSync(process.argv[2], "utf8");
      const start = source.indexOf("function syncConversationMarker()");
      const end = source.indexOf("\nfunction renderContextPressureWarning", start);
      const state = { conversationAnimationRuns: new Set() };
      const markerNode = key => ({ dataset: { markerKey: key }, addEventListener: () => {} });
      let node = markerNode("alpha:run-1:complete");
      const motionContext = { state, window: { matchMedia: () => ({ matches: false }) }, els: { view: { querySelector: () => node } } };
      vm.createContext(motionContext);
      vm.runInContext(source.slice(start, end), motionContext);
      motionContext.syncConversationMarker();
      assert.equal(node.dataset.motion, "play");
      motionContext.syncConversationMarker();
      assert.equal(node.dataset.motion, "play");
      node = markerNode("alpha:run-1:complete");
      motionContext.syncConversationMarker();
      assert.equal(node.dataset.motion, "rest");
      node = markerNode("alpha:run-2:complete");
      motionContext.syncConversationMarker();
      assert.equal(node.dataset.motion, "play");
      console.log("conversation animation state and replay guard: ok");
    JS
    assets = File.join(root, "lib", "hq", "remote_ui", "assets")
    out, err, status = Open3.capture3("node", "-e", script, File.join(assets, "app_helpers.js"), File.join(assets, "app.js"))
    raise "#{out}\n#{err}" unless status.success?

    puts out
  end
end

RemoteUIConversationAnimationTest.run! if $PROGRAM_NAME == __FILE__
