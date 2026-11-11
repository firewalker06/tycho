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
      const model = source.slice(source.indexOf("function noteScheduleStateChange("), source.indexOf("function saveScheduleForm("));
      const handlers = source.slice(source.indexOf('  if (event.target.id === "schedule-form") {'), source.indexOf('  if (event.target.id === "agent-form") {', source.indexOf('  if (event.target.id === "schedule-form") {')));
      let cases = 0;
      function fixture(kind = "message") {
        let resolveWrite, rejectWrite, writes = 0, refreshes = 0, clears = 0, applied = 0, pending = false, draft = "submitted draft";
        const requests = [];
        const state = { failureCount: 0, scheduleMessages: {}, schedules: [{ key: "saved", name: "Initial", message_source: "file", message_file: "schedules/body.md" }] };
        const form = { id: kind === "message" ? "schedule-message-form" : "schedule-form", dataset: { mode: kind === "edit" ? "edit" : "create", scheduleKey: "saved" } };
        const c = {
          state, event: { target: form }, location: { hash: "#form" }, clearTimeout,
          FormData: class { get() { return "body"; } }, formPending: () => pending,
          formDraftStorageKey: () => "draft", safeLocalStorageGet: () => draft,
          setFormPending: (_, value) => { pending = value; }, setConnection() {}, render() {}, schedule() {}, showGrowl() {},
          refresh: async () => { refreshes++; },
          apiPost: async () => { writes++; return new Promise((resolve, reject) => { resolveWrite = resolve; rejectWrite = reject; }); },
          apiPatch: async () => { writes++; return new Promise((resolve, reject) => { resolveWrite = resolve; rejectWrite = reject; }); },
          apiGet: () => new Promise((resolve, reject) => requests.push({ resolve, reject })),
          findProject: () => ({ server_key: "local" }), resourceRawKey: () => "web",
          scheduleFormPayload: () => ({ key: "saved", project_key: "web" }), normalizeLocalSchedule: x => x,
          upsertSchedule: x => { applied++; assert.equal(x.name, "Normalized"); },
          clearFormDraft: () => { clears++; draft = null; }, navigate: route => { c.location.hash = `#${route.tab}`; },
        };
        vm.createContext(c);
        vm.runInContext(`let scheduleFormNavigationGeneration = 0; const scheduleStateVersions = new Map(); const scheduleMessageOrders = new Map();\n${model}\n${fn("mutate")}\n${fn("saveScheduleForm")}\n${fn("ensureScheduleMessage")}\nconst originalMutate = mutate; mutate = (...args) => { mutationResult = originalMutate(...args); };\napplyScheduleMessage("saved", {key: "saved", content: "Initial body"});`, c);
        const run = code => vm.runInContext(code, c);
        const read = () => { const promise = run('ensureScheduleMessage("saved", true)'); return { promise, request: requests.at(-1) }; };
        const finishRead = async (r, status = 200, content = "Reader body") => {
          if (status === 200) r.request.resolve({ message: { key: "saved", content } });
          else if (status === "invalid") r.request.resolve({ message: {} });
          else r.request.reject(Object.assign(Error("Read failed"), { status }));
          await r.promise;
        };
        const response = kind === "message" ? { message: { key: "saved", content: "Accepted body" } } : { schedule: { key: "saved", name: "Normalized", cron: "0 9 * * *", project_key: "web", message_source: "inline" } };
        return { c, state, run, read, finishRead,
          dispatch: () => { run(handlers); run(handlers); assert.equal(writes, 1); assert.equal(pending, true); },
          finish: async (value = response) => { resolveWrite(value); await c.mutationResult; assert.equal(pending, false); },
          fail: async () => { rejectWrite(Error("Write failed")); await c.mutationResult; assert.equal(pending, false); },
          newDraft: () => { draft = "newer draft"; },
          stats: () => ({ writes, refreshes, clears, applied, pending }),
          order: () => run('JSON.stringify(scheduleMessageOrder("saved"))'),
        };
      }
      (async () => {
        for (const kind of ["create", "edit", "message"]) for (const scenario of ["ok", "invalid", "route", "record", "deleted"]) {
          const f = fixture(kind); f.dispatch();
          if (scenario === "route") f.run('scheduleFormNavigationGeneration++;');
          if (scenario === "record") f.run('applyScheduleList([{key:"saved", name:"Newer", message_source:"file", message_file:"schedules/body.md"}]);');
          if (scenario === "deleted") f.run('applyScheduleList([]);');
          await f.finish(scenario === "invalid" ? {} : undefined);
          assert.equal(f.stats().refreshes, ["ok", "record", "deleted"].includes(scenario) ? 1 : 0);
          assert.equal(f.stats().clears, scenario === "ok" ? 1 : 0);
          assert.equal(f.c.location.hash, scenario === "ok" ? "#schedules" : "#form");
          cases++;
        }
        // Readers pending before or after dispatch lose to an eligible accepted
        // body update. Readers started after acceptance retain normal authority.
        for (const timing of ["before-dispatch", "after-dispatch", "after-acceptance"]) for (const status of [200, 503, 401, "invalid"]) {
          const f = fixture(); let r;
          if (timing === "before-dispatch") r = f.read();
          f.dispatch();
          if (timing === "after-dispatch") r = f.read();
          await f.finish();
          if (timing === "after-acceptance") r = f.read();
          await f.finishRead(r, status);
          const message = f.state.scheduleMessages.saved;
          assert(!message.loading);
          if (timing !== "after-acceptance") assert.equal(message.content, "Accepted body");
          else if (status === 200) assert.equal(message.content, "Reader body");
          else assert(message.error);
          assert.equal(f.stats().refreshes, 1); cases++;
        }
        // A rejected save has no ordering side effects. The latest reader still
        // supplies its value/error; observed deletion retires both operations.
        for (const stale of ["route", "draft", "body", "record", "deleted"]) for (const timing of ["before-dispatch", "after-dispatch"]) for (const status of [200, 503, 401]) {
          const f = fixture(); let r;
          if (timing === "before-dispatch") r = f.read();
          f.dispatch();
          if (stale === "body") { const observed = f.read(); await f.finishRead(observed, 200, "Newer observed body"); }
          if (timing === "after-dispatch") r = f.read();
          if (stale === "route") f.run('scheduleFormNavigationGeneration++;');
          if (stale === "draft") f.newDraft();
          if (stale === "record") f.run('applyScheduleList([{key:"saved", name:"Newer", message_source:"file", message_file:"schedules/body.md"}]);');
          if (stale === "deleted") f.run('applyScheduleList([]);');
          const order = f.order();
          await f.finish();
          assert.equal(f.order(), order, "rejected save must not invalidate or advance message state");
          assert.equal(f.stats().clears, 0); assert.equal(f.c.location.hash, "#form");
          await f.finishRead(r, status);
          const message = f.state.scheduleMessages.saved;
          if (stale === "deleted") assert.equal(message, undefined);
          else if (stale === "body" && timing === "before-dispatch") assert.equal(message.content, "Newer observed body");
          else if (status === 200) assert.equal(message.content, "Reader body");
          else assert(message.error);
          assert(!message?.loading); cases++;
        }
        for (const failure of ["write-error", "invalid-result"]) for (const status of [200, 503, 401]) {
          const f = fixture(); f.dispatch(); const r = f.read(); const order = f.order();
          if (failure === "write-error") await f.fail(); else await f.finish({});
          assert.equal(f.order(), order); assert.equal(f.stats().clears, 0);
          await f.finishRead(r, status); assert(!f.state.scheduleMessages.saved.loading); cases++;
        }
        for (const oldStatus of [200, 503, 401]) for (const newStatus of [200, 503, 401]) {
          const f = fixture(), old = f.read(), newer = f.read();
          await f.finishRead(newer, newStatus, "Latest body");
          const expected = JSON.stringify(f.state.scheduleMessages.saved);
          await f.finishRead(old, oldStatus, "Old body");
          assert.equal(JSON.stringify(f.state.scheduleMessages.saved), expected); cases++;
        }
        for (const identity of ["inline", "other-file"]) for (const status of [200, 503, 401]) {
          const f = fixture(); f.dispatch(); const r = f.read();
          f.run(identity === "inline" ? 'applyScheduleList([{key:"saved", message_source:"inline"}]);' : 'applyScheduleList([{key:"saved", message_source:"file", message_file:"schedules/other.md"}]);');
          const order = f.order(); await f.finish();
          assert.equal(f.order(), order); await f.finishRead(r, status);
          assert.equal(f.state.scheduleMessages.saved, undefined); cases++;
        }
        for (const status of [200, 503]) {
          const f = fixture(); f.dispatch(); await f.finishRead(f.read(), status, "Initial body");
          await f.finish(); assert.equal(f.state.scheduleMessages.saved.content, "Accepted body");
          assert.equal(f.stats().clears, 1); cases++;
        }
        // Observed A -> B -> A is still newer than the dispatch snapshot.
        const aba = fixture(); aba.dispatch();
        await aba.finishRead(aba.read(), 200, "Changed body");
        await aba.finishRead(aba.read(), 200, "Initial body");
        const observed = aba.order(); await aba.finish();
        assert.equal(aba.order(), observed); assert.equal(aba.stats().clears, 0); cases++;
        console.log(`schedule save/message ordering: ${cases} cases passed`);
      })().catch(error => { console.error(error); process.exitCode = 1; });
    JAVASCRIPT
    root = File.expand_path("..", __dir__)
    out, err, status = Open3.capture3("node", "-e", script, File.join(root, "lib/hq/remote_ui/assets/app.js"))
    raise "Schedule save regression failed: #{err}" unless status.success?

    puts out
    puts "remote_ui_schedule_save_test: ok"
  end
end

RemoteUIScheduleSaveTest.run! if $PROGRAM_NAME == __FILE__
