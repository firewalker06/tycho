# frozen_string_literal: true

require "open3"

module RemoteUIAgentCreationTest
  module_function

  def run!
    script = <<~'JS'
      const assert = require("node:assert/strict");
      const fs = require("node:fs");
      const vm = require("node:vm");
      const source = fs.readFileSync(process.argv[1], "utf8");
      const start = source.indexOf("function creationServerDescriptor(");
      const end = source.indexOf("async function submitQuickAgent(", start);
      let storage = "[]";
      const context = {
        pendingAgentCreations: new Map(), AGENT_CREATION_STORAGE_KEY: "draft",
        sessionStorageValue: () => storage, setSessionStorageValue: (_key, value) => { storage = value; },
      };
      vm.createContext(context);
      vm.runInContext(source.slice(start, end), context);
      const payload = { project_key: "peer/web", prompt: "Only pending prompt", client_request_id: "client-pending" };
      context.pendingAgentCreations.set("client-pending", {
        id: "client-pending", payload,
        request: { path: "/servers/peer/agents", body: { ...payload, project_key: "web" },
          server: { key: "peer", name: "Peer", local: false, token: "PRIVATE_BEARER",
            agents: [{ prompt: "PRIVATE_UNRELATED_PROMPT" }], projects: [{ path: "PRIVATE_WORKSPACE" }] } },
      });
      context.persistAgentCreations();
      assert(!storage.includes("PRIVATE_"), "Must not retain catalogs, unrelated prompts, or credentials");
      assert.equal(storage.split("Only pending prompt").length - 1, 1, "Do not duplicate pending payload");
      context.pendingAgentCreations.clear();
      context.restoreAgentCreations();
      const restored = context.pendingAgentCreations.get("client-pending");
      assert.equal(restored.payload.client_request_id, "client-pending");
      assert.equal(restored.request.path, "/servers/peer/agents");
      assert.equal(restored.request.body.project_key, "web");
      assert.equal(restored.request.server.key, "peer");
      assert.equal(restored.rejected, false, "Interrupted acceptance must remain uncertain");
      assert.match(restored.error, /interrupted/);
      restored.rejected = true;
      restored.editing = true;
      restored.payload.prompt = "Corrected draft";
      restored.error = "Prompt is required";
      context.persistAgentCreations();
      context.pendingAgentCreations.clear();
      context.restoreAgentCreations();
      assert.equal(context.pendingAgentCreations.get("client-pending").payload.prompt, "Corrected draft");
      assert.equal(context.pendingAgentCreations.get("client-pending").editing, true);

      // Migrate an old completed draft without retaining its agent or server snapshot.
      context.pendingAgentCreations.clear();
      storage = JSON.stringify([{ id: "old", agent: { key: "real-agent", prompt: "PRIVATE_COMPLETED_PROMPT" },
        request: { server: { agents: [{ prompt: "PRIVATE_UNRELATED_PROMPT" }] } } }]);
      context.restoreAgentCreations();
      assert.equal(storage, JSON.stringify([{ id: "old", agentKey: "real-agent" }]));
      for (let i = 0; i < 50; i++) context.pendingAgentCreations.set(`done-${i}`, { id: `done-${i}`, agentKey: `agent-${i}` });
      context.persistAgentCreations();
      assert.equal(JSON.parse(storage).length, 20, "Completed route receipts must be bounded");
      assert(JSON.parse(storage).every(entry => Object.keys(entry).sort().join(",") === "agentKey,id"));
      console.log("minimal creation storage and recovery: ok");
    JS
    app_path = File.expand_path("../lib/hq/remote_ui/assets/app.js", __dir__)
    out, err, status = Open3.capture3("node", "-e", script, app_path)
    raise "Agent creation storage regression failed:\n#{out}#{err}" unless status.success?

    puts "remote_ui_agent_creation_test: ok"
  end
end

RemoteUIAgentCreationTest.run! if $PROGRAM_NAME == __FILE__
