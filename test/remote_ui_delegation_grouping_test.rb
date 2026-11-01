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
      const flatten = (trees) => trees.flatMap((tree) => tree.entries.map((entry) => entry.agent));

      const nested = [
        agent("child-old", "2026-10-01T10:00:00Z", "parent-old"),
        agent("parent-old", "2026-10-01T09:00:00Z"),
        agent("parent-new", "2026-10-03T09:00:00Z"),
        agent("child-new", "2026-10-02T10:00:00Z", "parent-old"),
        agent("grandchild", "2026-10-04T10:00:00Z", "child-old"),
        agent("orphan", "2026-10-01T08:00:00Z", "missing-parent"),
      ];
      const trees = helpers.groupAgentsByDelegation(nested);
      const expected = "parent-new,parent-old,child-new,child-old,grandchild,orphan";
      if (keys(flatten(trees)) !== expected) {
        throw new Error(`delegation grouping order was ${keys(flatten(trees))}, expected ${expected}`);
      }
      const depths = trees.flatMap((tree) => tree.entries.map((entry) => `${entry.agent.key}:${entry.depth}`)).join(",");
      const expectedDepths = "parent-new:0,parent-old:0,child-new:1,child-old:1,grandchild:2,orphan:0";
      if (depths !== expectedDepths) {
        throw new Error(`delegation depths were ${depths}, expected ${expectedDepths}`);
      }
      if (trees[1].root.key !== "parent-old" || trees.length !== 3) {
        throw new Error(`delegation trees were not rooted per parent: ${trees.map((tree) => tree.root.key).join(",")}`);
      }

      const cycle = [
        agent("cycle-a", "2026-10-01T10:00:00Z", "cycle-b"),
        agent("cycle-b", "2026-10-01T11:00:00Z", "cycle-a"),
        agent("self", "2026-10-01T12:00:00Z", "self"),
      ];
      const cycleGrouped = flatten(helpers.groupAgentsByDelegation(cycle));
      if (cycleGrouped.length !== cycle.length || new Set(keys(cycleGrouped).split(",")).size !== cycle.length) {
        throw new Error(`delegation cycle dropped or duplicated agents: ${keys(cycleGrouped)}`);
      }

      const custom = helpers.groupAgentsByDelegation(
        [agent("a", "2026-10-01T10:00:00Z"), agent("b", "2026-10-02T10:00:00Z")],
        (left, right) => left.key.localeCompare(right.key)
      );
      if (keys(flatten(custom)) !== "a,b") {
        throw new Error(`delegation grouping ignored the supplied comparator: ${keys(custom)}`);
      }

      const assert = require("node:assert/strict");
      const visible = options => helpers.switcherDelegationEntries(nested, options);
      const visibleKeys = options => keys(visible(options).map(entry => entry.agent));
      assert.equal(visibleKeys({}), "parent-new,parent-old,orphan");
      const overrides = new Map([["parent-old", true]]);
      assert.equal(visibleKeys({ overrides }), "parent-new,parent-old,child-new,child-old,orphan");
      overrides.set("child-old", true);
      assert.equal(visibleKeys({ overrides }), expected);
      assert.equal(visible({ overrides })[1].childCount, 3);
      assert.equal(visibleKeys({ expanded: true }), expected);
      for (const match of ["parent-old", "child-new", "grandchild"]) {
        assert.equal(visibleKeys({ matches: new Set([match]) }), "parent-old,child-new,child-old,grandchild");
      }
      assert.equal(visibleKeys({ matches: new Set() }), "");
      assert.equal(visibleKeys({}), "parent-new,parent-old,orphan", "search does not change normal state");
      assert.equal(visibleKeys({ overrides }), expected, "search preserves explicit expansion");
      const collision = [agent("one", "", "unknown"), agent("two", "", "absent")];
      collision.forEach(item => item.name = "Same title");
      collision[1].server_key = "peer";
      assert.equal(helpers.switcherDelegationEntries([...collision, collision[0]]).length, 2);
      assert.equal(helpers.switcherDelegationEntries(cycle, { expanded: true }).length, 3);
      assert.equal(helpers.switcherDelegationEntries(nested.concat(agent("fresh", "", "parent-old")), { expanded: true }).length, 7);
    JAVASCRIPT

    output, status = Open3.capture2e("node", "-e", script, HELPERS_PATH)
    raise "remote UI delegation grouping check failed:\n#{output}" unless status.success?
  end
end

RemoteUIDelegationGroupingTest.run! if $PROGRAM_NAME == __FILE__
