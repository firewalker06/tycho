# frozen_string_literal: true

require "open3"

module RemoteUIDelegationGroupingTest
  module_function

  ROOT = File.expand_path("..", __dir__)
  HELPERS_PATH = File.join(ROOT, "lib", "hq", "remote_ui", "assets", "app_helpers.js")

  def run!
    script = <<~'JAVASCRIPT'
      const fs = require("fs");
      const vm = require("vm");
      const context = { window: {}, URL, URLSearchParams };
      vm.createContext(context);
      vm.runInContext(fs.readFileSync(process.argv[1], "utf8"), context);

      const helpers = context.window.TychoRemoteHelpers;
      const agent = (key, updatedAt, parentKey) => ({
        key,
        name: key,
        updated_at: updatedAt,
        delegation: parentKey ? { parent: { key: parentKey } } : {},
      });
      const keys = (list) => list.map((item) => item.key).join(",");

      const nested = [
        agent("child-old", "2026-10-01T10:00:00Z", "parent-old"),
        agent("parent-old", "2026-10-01T09:00:00Z"),
        agent("parent-new", "2026-10-03T09:00:00Z"),
        agent("child-new", "2026-10-02T10:00:00Z", "parent-old"),
        agent("grandchild", "2026-10-04T10:00:00Z", "child-old"),
        agent("orphan", "2026-10-01T08:00:00Z", "missing-parent"),
      ];
      const grouped = helpers.groupAgentsByDelegation(nested);
      const expected = "parent-new,parent-old,child-new,child-old,grandchild,orphan";
      if (keys(grouped) !== expected) {
        throw new Error(`delegation grouping order was ${keys(grouped)}, expected ${expected}`);
      }

      const cycle = [
        agent("cycle-a", "2026-10-01T10:00:00Z", "cycle-b"),
        agent("cycle-b", "2026-10-01T11:00:00Z", "cycle-a"),
        agent("self", "2026-10-01T12:00:00Z", "self"),
      ];
      const cycleGrouped = helpers.groupAgentsByDelegation(cycle);
      if (cycleGrouped.length !== cycle.length || new Set(keys(cycleGrouped).split(",")).size !== cycle.length) {
        throw new Error(`delegation cycle dropped or duplicated agents: ${keys(cycleGrouped)}`);
      }

      const custom = helpers.groupAgentsByDelegation(
        [agent("a", "2026-10-01T10:00:00Z"), agent("b", "2026-10-02T10:00:00Z")],
        (left, right) => left.key.localeCompare(right.key)
      );
      if (keys(custom) !== "a,b") {
        throw new Error(`delegation grouping ignored the supplied comparator: ${keys(custom)}`);
      }
    JAVASCRIPT

    output, status = Open3.capture2e("node", "-e", script, HELPERS_PATH)
    raise "remote UI delegation grouping check failed:\n#{output}" unless status.success?
  end
end

RemoteUIDelegationGroupingTest.run! if $PROGRAM_NAME == __FILE__
