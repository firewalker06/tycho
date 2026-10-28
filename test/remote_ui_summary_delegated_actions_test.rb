# frozen_string_literal: true

require "open3"

module RemoteUISummaryDelegatedActionsTest
  module_function

  def run!
    helpers = File.expand_path("../lib/hq/remote_ui/assets/app_helpers.js", __dir__)
    script = <<~'JAVASCRIPT'
      const assert = require("node:assert/strict");
      const fs = require("node:fs");
      const vm = require("node:vm");
      const context = { window: {} };
      vm.createContext(context);
      vm.runInContext(fs.readFileSync(process.argv[1], "utf8"), context);
      const project = context.window.TychoRemoteHelpers.visibleSummaryDelegatedActions;
      const action = (event_id, type, server = "server-a", target = "child") => ({
        event_id, action: type, agent_reference: { server_id: server, agent_key: target },
      });
      const created = action("created", "agent_created");
      const first = action("start:child:run-1", "agent_started");
      const second = action("start:child:run-2", "agent_started");
      const queued = { ...action("queued", "agent_message_sent"), delivery_status: "queued" };
      const sent = action("sent", "agent_message_sent");
      const ids = metadata => Array.from(project(metadata), item => item.event_id);
      const metadata = { run_id: "parent-run-1", delegated_actions: [created, first, queued, second, sent] };
      const original = JSON.stringify(metadata);
      assert.deepEqual(ids(metadata), [first.event_id, queued.event_id, second.event_id, sent.event_id]);
      assert.deepEqual(ids(metadata), ids(metadata), "Repeated projection must be stable");
      assert.equal(JSON.stringify(metadata), original, "Saved Summary must remain unchanged");
      assert.deepEqual(ids({ delegated_actions: [created, first] }), [first.event_id], "Create plus start shows one Started");
      assert.deepEqual(ids({ run_id: "parent-run-2", delegated_actions: [created] }), [created.event_id], "Another run's start must not hide creation");
      assert.deepEqual(ids({ delegated_actions: [created, action("other-server", "agent_started", "server-b")] }), [created.event_id, "other-server"]);
      assert.deepEqual(ids({ delegated_actions: [created, action("other-target", "agent_started", "server-a", "other")] }), [created.event_id, "other-target"]);
      assert.deepEqual(ids({ delegated_actions: [action("unknown-created", "agent_created", ""), action("unknown-start", "agent_started", "")] }), ["unknown-created", "unknown-start"], "Incomplete target context must not be guessed");
      assert.deepEqual(ids({}), []);
    JAVASCRIPT
    output, status = Open3.capture2e("node", "-e", script, helpers)
    raise "Summary delegated action projection failed:\n#{output}" unless status.success?

    puts "remote_ui_summary_delegated_actions_test: ok"
  end
end

RemoteUISummaryDelegatedActionsTest.run! if $PROGRAM_NAME == __FILE__
