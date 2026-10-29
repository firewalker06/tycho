# frozen_string_literal: true

require "open3"

module RemoteUIArchiveCloneTest
  module_function

  def run!
    script = <<~'JS'
      const assert = require("node:assert/strict");
      const fs = require("node:fs");
      const vm = require("node:vm");
      const source = fs.readFileSync(process.argv[1], "utf8");
      const start = source.indexOf('  if (event.target.id === "agent-form") {');
      const end = source.indexOf('\n});', start);
      assert(start > 0 && end > start);
      const pendingStart = source.indexOf("function syncFormPending(");
      const pendingEnd = source.indexOf("\nfunction ", pendingStart + 1);
      const pendingContext = {};
      vm.createContext(pendingContext);
      vm.runInContext(source.slice(pendingStart, pendingEnd), pendingContext);
      const enabled = { disabled: false, dataset: {} };
      const disabled = { disabled: true, dataset: {} };
      const form = { classList: { toggle() {} }, setAttribute() {}, querySelectorAll: () => [enabled, disabled] };
      pendingContext.syncFormPending(form, true);
      pendingContext.syncFormPending(form, true);
      pendingContext.syncFormPending(form, false);
      assert.equal(enabled.disabled, false, "Repeated pending render must permit retry after failure");
      assert.equal(disabled.disabled, true, "Previously disabled controls must stay disabled");
      (async () => {
        for (const mode of ["clone", "edit"]) {
          for (const outcome of ["archived", "active", "rejected"]) {
            const calls = [];
            let pending;
            const form = { id: "agent-form", dataset: { mode, agentKey: "source", projectKey: "web" } };
            const request = async (path, payload) => {
              calls.push(["request", path, payload]);
              if (outcome === "rejected") throw new Error("Save failed");
              return { agent: { key: "target" }, archived: outcome === "archived" };
            };
            const context = {
              event: { target: form, submitter: { value: mode === "create" ? "create-run" : mode } },
              agentFormPayload: () => ({ name: "Edited name" }),
              formPending: () => false,
              mutate: callback => { pending = callback(); },
              apiPost: request, apiPatch: request,
              retireArchivedAgent: key => calls.push(["retire", key]),
              upsertAgent: agent => calls.push(["upsert", agent.key]),
              clearFormDraft: () => calls.push(["clear"]),
              navigate: route => calls.push(["navigate", route.key]),
            };
            vm.runInNewContext(`(() => {${source.slice(start, end)}\n})()`, context);
            if (outcome === "rejected") await assert.rejects(pending, /Save failed/);
            else await pending;
            const payload = calls[0][2];
            if (mode === "clone") {
              assert.equal(payload.archive_source, true, "Combined form must request archive");
              assert.equal(payload.start, undefined, "Editable clone must not start implicitly");
            }
            assert.equal(calls.some(c => c[0] === "retire"), mode === "clone" && outcome === "archived");
            assert.equal(calls.some(c => c[0] === "clear"), outcome !== "rejected");
            assert.equal(calls.some(c => c[0] === "navigate"), outcome !== "rejected");
            if (outcome === "rejected") assert.equal(calls.length, 1, "Rejected save must retain source and form");
          }
        }
        for (const action of ["create", "create-run"]) {
          for (const alreadyPending of [false, true]) {
            const calls = [];
            const form = { id: "agent-form", dataset: { mode: "create", projectKey: "web" } };
            const context = {
              event: { target: form, submitter: { value: action } },
              formPending: () => alreadyPending,
              agentFormPayload: () => ({ name: "Optional name", prompt: "Keep prompt" }),
              beginAgentCreation: (payload, submittedForm) => calls.push({ payload, submittedForm }),
              mutate: () => { throw new Error("Create must use pending Conversation"); },
            };
            vm.runInNewContext(`(() => {${source.slice(start, end)}\n})()`, context);
            assert.equal(calls.length, alreadyPending ? 0 : 1, "Pending form must not create twice");
            if (!alreadyPending) {
              assert.equal(calls[0].submittedForm, form);
              assert.equal(calls[0].payload.project_key, "web");
              assert.equal(calls[0].payload.name, "Optional name");
              assert.equal(calls[0].payload.prompt, "Keep prompt");
              assert.equal(calls[0].payload.start, action === "create-run");
            }
          }
        }
      })().catch(error => { console.error(error); process.exit(1); });
    JS
    app_path = File.expand_path("../lib/hq/remote_ui/assets/app.js", __dir__)
    out, err, status = Open3.capture3("node", "-e", script, app_path)
    raise "Archive clone UI regression failed:\n#{out}#{err}" unless status.success?

    puts "remote_ui_archive_clone_test: ok"
  end
end

RemoteUIArchiveCloneTest.run! if $PROGRAM_NAME == __FILE__
