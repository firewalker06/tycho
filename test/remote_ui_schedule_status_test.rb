# frozen_string_literal: true

require "open3"

module RemoteUIScheduleStatusTest
  module_function

  ROOT = File.expand_path("..", __dir__)
  HELPERS_PATH = File.join(ROOT, "lib", "hq", "remote_ui", "assets", "app_helpers.js")
  APP_PATH = File.join(ROOT, "lib", "hq", "remote_ui", "assets", "app.js")

  def run!
    assert_schedule_role_status_classes
    assert_agent_role_renderer_uses_schedule_status
    assert_schedule_role_status_colors
    puts "remote_ui_schedule_status_test: ok"
  end

  def assert_schedule_role_status_classes
    script = <<~'JAVASCRIPT'
      const fs = require("fs");
      const vm = require("vm");
      const context = { window: {}, URL, URLSearchParams };
      vm.createContext(context);
      vm.runInContext(fs.readFileSync(process.argv[1], "utf8"), context);

      const statusClass = context.window.TychoRemoteHelpers.agentScheduleStatusClass;
      const agent = { schedule_key: "daily" };
      const cases = [
        [{ key: "daily", status: "scheduled" }, "done"],
        [{ key: "daily", status: "paused" }, "need"],
        [{ key: "daily", status: "stopped" }, "fail"],
        [{ key: "daily", status: "unknown" }, "info"],
      ];

      for (const [schedule, expected] of cases) {
        const actual = statusClass(agent, [schedule]);
        if (actual !== expected) {
          throw new Error(`${schedule.status} schedule rendered as ${actual}, expected ${expected}`);
        }
      }
      if (statusClass(agent, []) !== "info") {
        throw new Error("a missing schedule must render with a neutral informational color");
      }
    JAVASCRIPT

    _stdout, stderr, status = Open3.capture3("node", "-e", script, HELPERS_PATH, chdir: ROOT)
    raise "Remote UI schedule status regression failed: #{stderr.strip}" unless status.success?
  end

  def assert_agent_role_renderer_uses_schedule_status
    javascript = File.read(APP_PATH)
    renderer = javascript[/function agentRoleIcons\(agent\).*?^}/m]
    raise "missing agent role icon renderer" unless renderer
    return if renderer.include?("REMOTE_HELPERS.agentScheduleStatusClass(agent, state.schedules)")

    raise "scheduled agent role icon does not use its schedule status"
  end

  def assert_schedule_role_status_colors
    css = File.read(File.join(ROOT, "lib", "hq", "remote_ui", "assets", "app.css"))
    %w[need done fail info].each do |status|
      next if css.include?(".agent-name-role-icon.#{status}")

      raise "missing #{status} color for scheduled agent role icons"
    end
  end
end

RemoteUIScheduleStatusTest.run! if $PROGRAM_NAME == __FILE__
