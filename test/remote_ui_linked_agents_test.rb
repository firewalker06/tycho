# frozen_string_literal: true

require "open3"

module RemoteUILinkedAgentsTest
  module_function

  def run!
    script = <<~'JS'
      const assert = require("node:assert/strict");
      const fs = require("node:fs");
      const vm = require("node:vm");
      const source = fs.readFileSync(process.argv[1], "utf8");
      const context = { state: { agents: [], agentDetails: {} }, escapeHtml: String, escapeAttr: String,
        iconSvg: () => "", renderAgentRelationshipRow: (owner, ref, child) => `<a data-child="${child}">${ref.key}</a>` };
      vm.createContext(context);
      for (const name of ["findAgent", "linkedAgentReferences", "resolvedAgentReference", "linkedAgentFlyoutGroups", "renderLinkedAgentSections", "renderLinkedAgentsFlyout", "renderLinkedAgentsToggle"]) {
        const start = source.indexOf(`function ${name}(`);
        const end = source.indexOf("\nfunction ", start + 1);
        assert(start >= 0 && end > start);
        vm.runInContext(source.slice(start, end), context);
      }
      const ref = (key, extra = {}) => ({ key, state: "active", connected: true, ...extra });
      const owner = { key: "owner", delegation: { parent: ref("parent"), children: [
        ref("idle", { status: "idle" }), ref("input", { status: "awaiting-input", owner: "user" }),
        ref("running", { status: "running" }), ref("archived", { state: "archived" }),
        ref("disconnected", { connected: false }), ref("both", { archived: true, connected: false }),
        ref("unknown", { state: "missing" }), ref("peer/shared"), ref("shared"), ref("idle"),
      ] } };
      context.state.agents = [{ key: "shared", archived: true }, { key: "idle", status: "idle" }];
      const groups = context.linkedAgentFlyoutGroups(owner);
      assert.equal(groups.current.map(e => e.reference.key).join(","), "parent,idle,input,running,unknown,peer/shared");
      assert.equal(groups.inactive.map(e => e.reference.key).join(","), "archived,disconnected,both,shared");
      const html = context.renderLinkedAgentsFlyout(owner);
      assert(html.includes("Archived or disconnected (4)"));
      const toggle = context.renderLinkedAgentsToggle(owner);
      assert(toggle.includes('<span class="linked-agents-count">6</span>'), "badge counts current linked agents only");
      assert(html.includes("10 agents"), "popover retains the total linked-agent count");
      assert(html.includes('data-child="owner"'), "parent control targets the owner child");
      assert(html.indexOf("peer/shared") < html.indexOf("<details"), "peer key must not resolve to local archived key");
      assert(!/<details[^>]*\sopen(?:\s|>)/.test(html), "history starts collapsed");
      assert.equal((html.match(/>idle<\/a>/g) || []).length, 1, "duplicate references render once");
      assert(html.includes('linked-agent-history:owner'), "view state uses owner identity");
      context.state.agents = [];
      context.state.agentDetails = { unrelated: { key: "unrelated", delegation: { children: [ref("idle", { state: "archived", archived: true })] } } };
      assert(context.linkedAgentFlyoutGroups(owner).current.some(e => e.reference.key === "idle"), "catalog failure must not hide idle linked children");
      assert.equal(context.renderLinkedAgentsFlyout({ key: "empty" }), "");
      const allOld = context.renderLinkedAgentsFlyout({ key: "old", delegation: { children: [ref("old-child", { connected: false })] } });
      assert(allOld.includes("Archived or disconnected (1)"));
      assert(context.renderLinkedAgentsToggle({ key: "old", delegation: { children: [ref("old-child", { connected: false })] } }).includes('<span class="linked-agents-count">0</span>'), "inactive-only links keep the badge control available with zero active agents");
      assert(!allOld.slice(0, allOld.indexOf("<details")).includes("Delegated agents"));
      console.log("linked-agent renderer: lifecycle, ownership, connection, identity, deduplication, missing catalog and empty groups passed");
    JS
    output, status = Open3.capture2e("node", "-e", script, File.expand_path("../lib/hq/remote_ui/assets/app.js", __dir__))
    raise output unless status.success?
    puts output
  end
end

RemoteUILinkedAgentsTest.run! if $PROGRAM_NAME == __FILE__
