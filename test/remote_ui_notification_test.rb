# frozen_string_literal: true

require "open3"

module RemoteUINotificationTest
  module_function

  ROOT = File.expand_path("..", __dir__)
  HELPERS_PATH = File.join(ROOT, "lib", "hq", "remote_ui", "assets", "app_helpers.js")
  APP_PATH = File.join(ROOT, "lib", "hq", "remote_ui", "assets", "app.js")

  def run!
    assert_notification_route_round_trip
    assert_notification_fallback_contract
    puts "remote_ui_notification_test: ok"
  end

  def assert_notification_route_round_trip
    script = <<~'JAVASCRIPT'
      const fs = require("fs");
      const vm = require("vm");
      const context = { window: {}, URL, URLSearchParams };
      vm.createContext(context);
      vm.runInContext(fs.readFileSync(process.argv[1], "utf8"), context);
      const helpers = context.window.TychoRemoteHelpers;
      const route = helpers.parseRoute("#notification/queue%3Afailure", { topTabs: ["now", "agents", "settings"] });
      if (route.type !== "notification" || route.id !== "queue:failure") throw new Error(JSON.stringify(route));
      if (helpers.routeHash(route) !== "#notification/queue%3Afailure") throw new Error(helpers.routeHash(route));
      const activeTarget = helpers.notificationTargetRoute({ kind: "agent", target_state: "active", agent_key: "release:check" });
      if (activeTarget.type !== "agent" || activeTarget.key !== "release:check") throw new Error(JSON.stringify(activeTarget));
      const archivedTarget = helpers.notificationTargetRoute({ kind: "agent", target_state: "archived", agent_key: "release:archive" });
      if (archivedTarget.type !== "agent" || archivedTarget.key !== "release:archive") throw new Error(JSON.stringify(archivedTarget));
      if (helpers.notificationTargetRoute({ kind: "agent", target_state: "missing", agent_key: "removed" }) !== null) throw new Error("missing agent target redirected");
      if (helpers.notificationTargetRoute({ kind: "queue_process_failed", target_state: "active", agent_key: "queue-agent" }) !== null) throw new Error("queue failure redirected");
      if (helpers.notificationTargetRoute({ kind: "agent", target_state: "active", agent_key: "" }) !== null) throw new Error("empty target redirected");
    JAVASCRIPT
    _stdout, stderr, status = Open3.capture3("node", "-e", script, HELPERS_PATH)
    raise "notification route regression failed: #{stderr}" unless status.success?
  end

  def assert_notification_fallback_contract
    javascript = File.read(APP_PATH)
    required = [
      "notificationDetails: {}",
      "async function ensureNotification",
      "REMOTE_HELPERS.notificationTargetRoute(notification)",
      "function renderNotification",
      'apiPost(`/notifications/${encodeURIComponent(id)}/read`, {})',
      'targetState === "archived"',
      '"Original agent is not available"',
      'notification.queue_work_batch_id',
      'This notification is no longer in Tycho\'s retained history.'
    ]
    missing = required.reject { |fragment| javascript.include?(fragment) }
    raise "missing durable notification UI contract: #{missing.join(', ')}" unless missing.empty?
  end
end

RemoteUINotificationTest.run! if $PROGRAM_NAME == __FILE__
