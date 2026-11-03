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
          setFormPending: (_, value) => { pending = value; }, setConnection: () => {}, render: () => {}, schedule: () => {},
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
        vm.runInContext(`let scheduleFormNavigationGeneration = 0;\n${fn("mutate")}\n${fn("saveScheduleForm")}\nconst originalMutate = mutate; mutate = (...args) => { mutationResult = originalMutate(...args); };`, context);
        vm.runInContext(handlers, context);
        assert.equal(writes, 1);
        assert.equal(pending, true);
        vm.runInContext(handlers, context);
        assert.equal(writes, 1, "pending submit must not issue another write");
        if (scenario === "stale") vm.runInContext('scheduleFormNavigationGeneration++; location.hash = "#form";', context);
        resolveWrite(scenario === "invalid" ? {} : response);
        await context.mutationResult;
        assert.equal(pending, false);
        assert.equal(reads, scenario === "ok" ? 1 : 0, "one reconciliation only after a current valid save");
        assert.equal(clears, scenario === "ok" ? 1 : 0);
        assert.equal(context.location.hash, scenario === "ok" ? "#now" : "#form");
        assert.equal(applied, scenario === "ok" && kind !== "message" ? 1 : 0);
        assert.equal(Boolean(state.scheduleMessages.saved), scenario === "ok" && kind === "message");
      }
      (async () => {
        for (const kind of ["create", "edit", "message"]) for (const scenario of ["ok", "invalid", "stale"]) await check(kind, scenario);
      })().catch(error => { console.error(error); process.exitCode = 1; });
    JAVASCRIPT
    root = File.expand_path("..", __dir__)
    _out, err, status = Open3.capture3("node", "-e", script, File.join(root, "lib/hq/remote_ui/assets/app.js"))
    raise "Schedule save regression failed: #{err}" unless status.success?

    puts "remote_ui_schedule_save_test: ok"
  end
end

RemoteUIScheduleSaveTest.run! if $PROGRAM_NAME == __FILE__
