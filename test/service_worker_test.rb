# frozen_string_literal: true

require "open3"

module ServiceWorkerTest
  module_function

  ROOT = File.expand_path("..", __dir__)
  SERVICE_WORKER_PATH = File.join(ROOT, "lib", "hq", "remote_ui", "assets", "service-worker.js")

  def run!
    assert_push_display_and_click_flow
    puts "service_worker_test: ok"
  end

  def assert_push_display_and_click_flow
    script = <<~'JAVASCRIPT'
      const fs = require("fs");
      const vm = require("vm");
      const assert = require("assert");
      const source = fs.readFileSync(process.argv[1], "utf8");
      const handlers = {};
      const notifications = [];
      const badges = [];
      const navigations = [];
      const opened = [];
      let focused = 0;
      let matchedClients = [{
        url: "https://tycho.test/#setup",
        navigate: async (url) => navigations.push(url),
        focus: async () => { focused += 1; },
      }];
      const worker = {
        location: { origin: "https://tycho.test" },
        navigator: {
          setAppBadge: async (count) => badges.push(count),
          clearAppBadge: async () => badges.push(0),
        },
        registration: {
          showNotification: async (title, options) => notifications.push({ title, options }),
        },
        clients: {
          claim: async () => {},
          matchAll: async () => matchedClients,
          openWindow: async (url) => opened.push(url),
        },
        skipWaiting: () => {},
        addEventListener: (name, handler) => { handlers[name] = handler; },
      };
      const context = { self: worker, URL, Promise, Number, Object, Boolean, Math };
      vm.runInNewContext(source, context, { filename: process.argv[1] });

      async function dispatch(name, event) {
        let pending = Promise.resolve();
        handlers[name]({ ...event, waitUntil: (promise) => { pending = Promise.resolve(promise); } });
        await pending;
      }

      (async () => {
        await dispatch("push", {
          data: { json: () => ({
            title: "Agent finished",
            body: "Windows check",
            tag: "hq:agents",
            renotify: true,
            silent: false,
            badge_count: 2,
            url: "/#agent/windows-check",
          }) },
        });
        assert.deepStrictEqual(badges, [2]);
        assert.strictEqual(notifications.length, 1);
        assert.strictEqual(notifications[0].title, "Agent finished");
        assert.strictEqual(notifications[0].options.body, "Windows check");
        assert.strictEqual(notifications[0].options.tag, "hq:agents");
        assert.strictEqual(notifications[0].options.renotify, true);
        assert.strictEqual(notifications[0].options.silent, false);
        assert.strictEqual(notifications[0].options.data.url, "/#agent/windows-check");

        let closed = 0;
        await dispatch("notificationclick", {
          notification: {
            data: { url: "/#agent/windows-check" },
            close: () => { closed += 1; },
          },
        });
        assert.strictEqual(closed, 1);
        assert.deepStrictEqual(navigations, ["https://tycho.test/#agent/windows-check"]);
        assert.strictEqual(focused, 1);

        matchedClients = [];
        await dispatch("notificationclick", {
          notification: {
            data: { url: "/#agent/new-window" },
            close: () => {},
          },
        });
        assert.deepStrictEqual(opened, ["https://tycho.test/#agent/new-window"]);
      })().catch((error) => {
        console.error(error.stack || error.message);
        process.exitCode = 1;
      });
    JAVASCRIPT
    stdout, stderr, status = Open3.capture3("node", "-e", script, SERVICE_WORKER_PATH)
    return if status.success?

    raise "service worker regression failed: #{[stdout, stderr].join.strip}"
  end
end

ServiceWorkerTest.run! if $PROGRAM_NAME == __FILE__
