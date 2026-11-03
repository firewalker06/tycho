# frozen_string_literal: true

require "open3"

module RemoteUIScheduleSaveTest
  module_function

  def run!
    script = <<~'JAVASCRIPT'
      const assert = require("node:assert/strict");
      const fs = require("node:fs");
      const vm = require("node:vm");
      const source = fs.readFileSync(process.argv[1], "utf8");
      const fn = name => source.match(new RegExp(`^(?:async )?function ${name}\\([^]*?^}`, "m"))[0];
      const handlers = source.slice(source.indexOf('  if (event.target.id === "schedule-form") {'), source.indexOf('  if (event.target.id === "agent-form") {', source.indexOf('  if (event.target.id === "schedule-form") {')));
      async function check(kind, scenario) {
        let resolveWrite, writes = 0, reads = 0, clears = 0, applied = 0, pending = false;
        const response = kind === "message" ? { message: { key: "saved", content: "Normalized body" } } : { schedule: { key: "saved", name: "Normalized", cron: "0 9 * * *", project_key: "web", message_source: "inline" } };
        const state = { failureCount: 0, scheduleMessages: {} };
        const form = { id: kind === "message" ? "schedule-message-form" : "schedule-form", dataset: { mode: kind === "edit" ? "edit" : "create", scheduleKey: "saved" } };
        const context = {
          state, event: { target: form }, location: { hash: "#form" }, clearTimeout,
          FormData: class { get() { return "body"; } },
          formPending: () => pending,
          formDraftStorageKey: () => "draft", safeLocalStorageGet: () => "draft value",
          setFormPending: (_, value) => { pending = value; }, setConnection: () => {}, render: () => {}, schedule: () => {}, showGrowl: () => {},
          refresh: async () => { reads++; },
          apiPost: async () => { writes++; return new Promise(resolve => { resolveWrite = resolve; }); },
          apiPatch: async () => { writes++; return new Promise(resolve => { resolveWrite = resolve; }); },
          findProject: () => ({ server_key: "local" }), resourceRawKey: () => "web",
          scheduleFormPayload: () => ({ project_key: "web" }),
          normalizeLocalSchedule: x => x,
          upsertSchedule: x => { applied++; assert.equal(x.name, "Normalized"); },
          clearFormDraft: () => { clears++; },
          navigate: () => { context.location.hash = "#now"; },
        };
        vm.createContext(context);
        vm.runInContext(`let scheduleFormNavigationGeneration = 0; const scheduleStateVersions = new Map(); const scheduleMessageReadGenerations = new Map();\n${fn("invalidateScheduleMessageReads")}\n${fn("mutate")}\n${fn("saveScheduleForm")}\nconst originalMutate = mutate; mutate = (...args) => { mutationResult = originalMutate(...args); };`, context);
        vm.runInContext(handlers, context);
        assert.equal(writes, 1);
        assert.equal(pending, true);
        vm.runInContext(handlers, context);
        assert.equal(writes, 1, "pending submit must not issue another write");
        if (scenario === "stale") vm.runInContext('scheduleFormNavigationGeneration++; location.hash = "#form";', context);
        if (["newer", "deleted"].includes(scenario)) vm.runInContext('scheduleStateVersions.set("saved", 1);', context);
        resolveWrite(scenario === "invalid" ? {} : response);
        await context.mutationResult;
        assert.equal(pending, false);
        assert.equal(reads, ["ok", "newer", "deleted"].includes(scenario) ? 1 : 0, "one reconciliation after a current valid save");
        assert.equal(clears, scenario === "ok" ? 1 : 0);
        assert.equal(context.location.hash, scenario === "ok" ? "#now" : "#form");
        assert.equal(applied, scenario === "ok" && kind !== "message" ? 1 : 0);
        assert.equal(Boolean(state.scheduleMessages.saved), scenario === "ok" && kind === "message");
      }
      async function checkMessageReads(failOld, acceptSave) {
        const pending = [];
        const state = { scheduleMessages: {} };
        const context = { state, apiGet: () => new Promise((resolve, reject) => pending.push({ resolve, reject })) };
        vm.createContext(context);
        vm.runInContext(`const scheduleMessageReadGenerations = new Map();\n${fn("invalidateScheduleMessageReads")}\n${fn("ensureScheduleMessage")}`, context);
        const old = vm.runInContext('ensureScheduleMessage("saved", true)', context);
        if (acceptSave) {
          vm.runInContext('invalidateScheduleMessageReads("saved"); state.scheduleMessages.saved = { content: "Accepted body" };', context);
        } else {
          const newer = vm.runInContext('ensureScheduleMessage("saved", true)', context);
          pending[1].resolve({ message: { content: "Accepted body" } });
          await newer;
        }
        if (failOld) pending[0].reject(new Error("Old read failed"));
        else pending[0].resolve({ message: { content: "Old body" } });
        await old;
        assert.equal(state.scheduleMessages.saved.content, "Accepted body");
        assert.equal(state.scheduleMessages.saved.error, undefined);
      }
      (async () => {
        for (const kind of ["create", "edit", "message"]) for (const scenario of ["ok", "invalid", "stale", "newer", "deleted"]) await check(kind, scenario);
        for (const fail of [false, true]) for (const accept of [false, true]) await checkMessageReads(fail, accept);
      })().catch(error => { console.error(error); process.exitCode = 1; });
    JAVASCRIPT
    root = File.expand_path("..", __dir__)
    _out, err, status = Open3.capture3("node", "-e", script, File.join(root, "lib/hq/remote_ui/assets/app.js"))
    raise "Schedule save regression failed: #{err}" unless status.success?

    puts "remote_ui_schedule_save_test: ok"
  end
end

RemoteUIScheduleSaveTest.run! if $PROGRAM_NAME == __FILE__
