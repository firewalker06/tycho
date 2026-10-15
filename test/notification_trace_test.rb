# frozen_string_literal: true

require "open3"
require_relative "../lib/hq/remote_ui"

module NotificationTraceTest
  module_function

  def run!
    script = <<~'JS'
      const vm = require("node:vm");
      const assert = require("node:assert/strict");
      const fs = require("node:fs");
      const { workerSource, helperSource, build } = JSON.parse(fs.readFileSync(0, "utf8"));
      const handlers = {};
      const events = [];
      const actions = [];
      let clients = [];
      const self = {
        location: { origin: "https://tycho.test" },
        addEventListener(name, callback) { handlers[name] = callback; },
        clients: {
          matchAll: async () => clients,
          openWindow: async (url) => { actions.push("open"); return { url }; },
        },
      };
      const context = { self, URL, Promise, globalThis: null };
      context.globalThis = context;
      context.TychoNotificationTrace = {
        recordId: () => "debug:worker-fixture",
        begin: async () => { events.length = 0; },
        record: async (name, fields) => events.push({ name, ...fields }),
      };
      vm.runInNewContext(workerSource, context);
      async function click() {
        let pending;
        handlers.notificationclick({
          notification: { data: { url: "/#notification/debug%3Aworker-fixture" }, close() {} },
          waitUntil(value) { pending = value; },
        });
        return pending;
      }
      (async () => {
        clients = [{ url: "https://other.test/", navigate() { throw new Error("must skip other origin"); } }, {
          url: "https://tycho.test/#settings",
          navigate: async (url) => { actions.push("navigate"); return { url }; },
          focus: async () => { actions.push("focus"); return {}; },
        }];
        await click();
        assert.deepEqual(actions, ["navigate", "focus"]);
        assert(events.some((event) => event.name === "client.selected" && event.same_origin));
        assert(events.some((event) => event.name === "navigate.resolved"));
        assert(events.some((event) => event.name === "focus.resolved"));
        clients = [{ url: "https://tycho.test/", navigate: async () => { throw new Error("PRIVATE ENDPOINT"); }, focus: async () => { throw new Error("PRIVATE TOKEN"); } }];
        await assert.rejects(click());
        assert(events.some((event) => event.name === "navigate.rejected"));
        assert(events.some((event) => event.name === "focus.rejected"));
        assert(!JSON.stringify(events).includes("PRIVATE"));
        clients = [];
        await click();
        assert(events.some((event) => event.name === "window.opened"));
        self.clients.openWindow = async () => { throw new Error("PRIVATE"); };
        await assert.rejects(click());
        assert(events.some((event) => event.name === "window.rejected"));

        // Lack of IndexedDB must be a reported diagnostic limit, not a click failure.
        const unavailable = { URL, setTimeout, clearTimeout, location: { origin: "https://tycho.test" } };
        vm.runInNewContext(helperSource, unavailable);
        const trace = unavailable.TychoNotificationTrace;
        await trace.begin("/#notification/debug%3Atest");
        await trace.record("click.received", { body: "PRIVATE" });
        const snapshot = await trace.snapshot();
        assert.equal(snapshot.storage, "unavailable");
        assert.equal(snapshot.events.length, 0);
        assert.equal(trace.route("https://evil.test/#agent/private"), "other");
        assert.equal(trace.route("/#agent/fixture?token=PRIVATE"), "other");
        assert.equal(trace.route("/#agent/https%3A%2F%2Fendpoint"), "other");
        assert.match(build, /^[a-f0-9]{12}$/);
        assert(!helperSource.includes("__TYCHO_TRACE_BUILD__"));
      })().catch((error) => { console.error(error); process.exitCode = 1; });
    JS
    payload = {
      workerSource: File.read(HQ::RemoteUI::SERVICE_WORKER_PATH),
      helperSource: HQ::RemoteUI.notification_trace_js,
      build: HQ::RemoteUI.asset_version
    }
    out, err, status = Open3.capture3("node", "-e", script, stdin_data: JSON.generate(payload))
    raise "notification trace regression failed: #{out}#{err}" unless status.success?

    puts "notification_trace_test: ok"
  end
end

NotificationTraceTest.run! if $PROGRAM_NAME == __FILE__
