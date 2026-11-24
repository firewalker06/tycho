# frozen_string_literal: true

require "open3"

module RemoteUIDelegationListsTest
  module_function

  def run!
    script = <<~'JS'
      const assert = require("node:assert/strict");
      const fs = require("node:fs");
      const vm = require("node:vm");
      const appPath = process.argv[1];
      const helperPath = process.argv[2];
      const source = fs.readFileSync(appPath, "utf8");
      const window = {};
      vm.runInNewContext(fs.readFileSync(helperPath, "utf8"), { window });
      const parent = { key: "parent", name: "Zulu parent", status: "idle", running: false, server_key: "local", project_key: "web" };
      const child = { key: "child", name: "Alpha child", status: "running", running: true, server_key: "local", project_key: "other",
        delegation: { parent: { key: "parent" } } };
      const other = { key: "other", name: "Beta root", status: "idle", running: false, server_key: "local", project_key: "web" };
      const state = { agents: [child, other, parent], filters: { server: "", agents: "" }, agentSort: "agent_name_asc",
        projects: [{ key: "web", name: "Web" }, { key: "other", name: "Other" }],
        expandedAgentTreeKeys: new Set(), bulkArchiveMode: false, bulkArchiveSelection: new Set() };
      const context = {
        REMOTE_HELPERS: window.TychoRemoteHelpers,
        state,
        findAgent: key => state.agents.find(agent => agent.key === key),
        currentAgents: () => state.agents,
        findProject: key => state.projects.find(project => project.key === key) || null,
        groupBy: (list, callback) => list.reduce((groups, item) => {
          const key = callback(item);
          (groups[key] ||= []).push(item);
          return groups;
        }, {}),
        compareAgentProjectKeysForCurrentSort: (left, right) => left.localeCompare(right),
        agentProjectGroup: (projectKey, agents) => agents.length ? { projectKey, agents, matchPriority: 0 } : null,
        agentSortConfig: () => ({}),
        escapeAttr: value => String(value).replace(/&/g, "&amp;").replace(/\"/g, "&quot;"),
        escapeHtml: value => String(value),
        iconSvg: () => "<svg></svg>",
        agentListStatusIcon: agent => agent.running ? '<span class="agent-status-icon running"></span>' : "",
        agentIdentityIcon: () => '<span class="agent-identity-icon"></span>',
        resourceStaleClass: () => "",
        statusLabel: agent => agent.status,
        agentNameHtml: agent => agent.name,
        agentListSubtextHtml: () => "",
        agentStatusBadge: agent => `<span>${agent.status}</span>`,
        statusBadge: label => `<span>${label}</span>`,
        resourceIsStale: () => false,
        agentArchiveable: agent => !agent.running,
        titleFromKey: value => value,
        statusClass: () => "info",
      };
      vm.createContext(context);
      function extract(name) {
        const start = source.indexOf(`function ${name}(`);
        const end = source.indexOf("\nfunction ", start + 1);
        assert(start >= 0 && end > start, `missing ${name}`);
        vm.runInContext(source.slice(start, end), context);
      }
      ["currentAgents", "serverFilteredAgents", "compareAgentsBySort", "compareAgentsForCurrentSort",
        "rankMatchingAgents", "sortedAgentList", "sortedAgentTrees", "collapseDelegatedAgents",
        "renderAgentRow", "renderSelectableAgentRow", "renderAgentTree", "serverFilteredProjects", "groupBy",
        "agentProjectGroups"].forEach(extract);

      const trees = context.sortedAgentTrees("");
      assert.deepEqual(Array.from(trees, tree => tree.root.key), ["other", "parent"],
        "explicit sort must sort delegation roots, not lift a child above its parent");
      const collapsed = context.collapseDelegatedAgents([parent, child]);
      assert.equal(collapsed.length, 1);
      assert.equal(collapsed[0].running, true, "a running child must set the displayed parent to Running");
      assert.equal(collapsed[0].delegated_running_count, 1);
      assert.equal(context.sortedAgentTrees("Alpha child")[0].root.key, "child",
        "search must keep a matching child directly reachable");

      state.agentSort = "project_asc";
      const projectGroups = context.agentProjectGroups("");
      const webGroup = projectGroups.find(group => group.projectKey === "web");
      const otherGroup = projectGroups.find(group => group.projectKey === "other");
      assert.equal(webGroup.agents.find(agent => agent.key === "parent")?.delegated_agents?.[0]?.key, "child",
        "project sorts must assign the complete cross-project delegation tree to the root project");
      assert.equal(webGroup.agents.find(agent => agent.key === "parent")?.delegated_running_count, 1,
        "cross-project running child must keep the parent count and Running state");
      assert.equal(otherGroup, undefined, "a delegated child must not create a separate project root");

      const html = context.renderAgentTree({ root: collapsed[0], entries: [{ agent: parent, depth: 0 }, { agent: child, depth: 1 }] }, "");
      const mainButton = html.indexOf('data-open-agent="parent"');
      const mainButtonEnd = html.indexOf("</button>", mainButton);
      const toggleButton = html.indexOf('data-toggle-agent-tree="parent"');
      assert(mainButton >= 0 && mainButtonEnd > mainButton && toggleButton > mainButtonEnd,
        "agent action and disclosure must be sibling buttons in one parent row");
      assert.match(html, /delegated-running-count[^>]*>1<\/span>/);
      assert.match(html, /data-preserve-focus[^>]*data-state-key="delegation-tree-toggle:parent"/);

      state.expandedAgentTreeKeys.add("parent");
      const expanded = context.renderAgentTree({ root: collapsed[0], entries: [{ agent: parent, depth: 0 }, { agent: child, depth: 1 }] }, "");
      assert.match(expanded, /data-toggle-agent-tree="parent"[^>]*aria-expanded="true"/,
        "rerender must restore the expanded disclosure state");
      assert.match(expanded, /class="agent-delegation-children">/,
        "rerender must leave expanded children visible");

      state.bulkArchiveMode = true;
      const bulk = context.renderAgentTree({ root: collapsed[0], entries: [{ agent: parent, depth: 0 }, { agent: child, depth: 1 }] }, "");
      assert.equal((bulk.match(/data-select-agent=/g) || []).length, 2,
        "bulk mode must retain selection controls for both parent and delegated child in grouped lists");
      assert.match(bulk, /data-toggle-agent-tree="parent"/,
        "bulk mode must keep a disclosure control to reach child selections");
      const nowRow = context.renderAgentRow(parent, { useStandardRow: true });
      assert.match(nowRow, /data-open-agent="parent"/, "Now standard rows must keep agent navigation in selection mode");
      assert.doesNotMatch(nowRow, /data-select-agent=/, "Now standard rows must not become archive checkboxes");
      const runningParentRow = context.renderAgentRow(parent, { useStandardRow: true, delegatedRunningCount: 2 });
      assert.match(runningParentRow, /delegated-running-count[^>]*>2<\/span>/,
        "standard rows must retain the delegated running count badge");
      const archiveChildRow = context.renderAgentRow(child, { archiveSelectable: true, selected: true, delegatedRunningCount: 1 });
      assert.match(archiveChildRow, /data-archive-delegate\b/,
        "archive rows must keep the separate delegate checkbox");
      assert.match(archiveChildRow, /delegated-running-count[^>]*>1<\/span>/,
        "archive rows must also retain the delegated running count badge");
      console.log("remote_ui_delegation_lists_test: explicit sorts, search, running counts, sibling actions, expansion and bulk selection passed");
    JS

    app = File.expand_path("../lib/hq/remote_ui/assets/app.js", __dir__)
    helpers = File.expand_path("../lib/hq/remote_ui/assets/app_helpers.js", __dir__)
    output, status = Open3.capture2e("node", "-e", script, app, helpers)
    raise output unless status.success?

    puts output
  end
end

RemoteUIDelegationListsTest.run! if $PROGRAM_NAME == __FILE__
