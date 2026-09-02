# frozen_string_literal: true

require "open3"

module RemoteUIAgentSearchTest
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
      const project = { name: "Tycho Project", group: "Personal" };

      const nameMatch = helpers.agentSearchMatch({ name: "Personal Agent" }, project, "personal");
      const projectMatch = helpers.agentSearchMatch({ name: "Other Agent" }, { name: "Personal Project", group: "Work" }, "personal");
      const groupMatch = helpers.agentSearchMatch({ name: "Other Agent" }, project, "personal");
      const hiddenMatch = helpers.agentSearchMatch(
        { name: "Other Agent", key: "personal-key", summary: "personal summary" },
        { name: "Other Project", group: "Work", branch: "personal-branch" },
        "personal"
      );

      if (nameMatch?.field !== "agent_name" || nameMatch.priority !== 0) {
        throw new Error(`agent-name match did not rank first: ${JSON.stringify(nameMatch)}`);
      }
      if (projectMatch?.field !== "project_name" || projectMatch.priority !== 1) {
        throw new Error(`project-name match did not rank second: ${JSON.stringify(projectMatch)}`);
      }
      if (groupMatch?.field !== "group_name" || groupMatch.priority !== 2) {
        throw new Error(`group-name match did not rank third: ${JSON.stringify(groupMatch)}`);
      }
      if (hiddenMatch !== null) {
        throw new Error(`hidden fields still matched agent search: ${JSON.stringify(hiddenMatch)}`);
      }

      const projects = {
        agent: { name: "Other Project", group: "Work" },
        project: { name: "Personal Project", group: "Work" },
        group: { name: "Other Project", group: "Personal" },
        hidden: { name: "Other Project", group: "Work" },
      };
      const ranked = helpers.rankMatchingAgents(
        [
          { key: "group", name: "Group Agent" },
          { key: "hidden", name: "Other Agent", summary: "Personal summary" },
          { key: "project", name: "Project Agent" },
          { key: "agent", name: "Personal Agent" },
        ],
        "personal",
        (agent) => projects[agent.key],
        (left, right) => left.name.localeCompare(right.name)
      );
      if (ranked.map((agent) => agent.key).join(",") !== "agent,project,group") {
        throw new Error(`agent search was not filtered and ranked by visible priority: ${JSON.stringify(ranked)}`);
      }

      const actionableUnread = { key: "actionable-unread", name: "A unread", last_result: "success", unread: true, updated_at: "2026-07-01T12:00:00Z" };
      const actionableReadNewer = { key: "actionable-read-newer", name: "B read", last_result: "success", updated_at: "2026-09-01T12:00:00Z" };
      const noActionUnread = { key: "no-action-unread", name: "C no action unread", last_result: "no action", unread: true, updated_at: "2026-08-01T12:00:00Z" };
      const noActionReadNewer = { key: "no-action-read-newer", name: "D no action read", last_result: "no action", updated_at: "2026-10-01T12:00:00Z" };
      const switched = [noActionReadNewer, actionableReadNewer, noActionUnread, actionableUnread].sort(helpers.compareQuickSwitchAgents);
      if (switched.map((agent) => agent.key).join(",") !== "actionable-read-newer,actionable-unread,no-action-read-newer,no-action-unread") {
        throw new Error(`quick switcher did not keep actionable agents and no-action agents in recency order: ${JSON.stringify(switched)}`);
      }
      const relevancy = [noActionReadNewer, actionableReadNewer, noActionUnread, actionableUnread]
        .sort((left, right) => helpers.compareAgentsBySort(left, right, "relevancy", {
          defaultSort: "relevancy",
          options: [{ value: "relevancy", scope: "agents" }],
        }));
      if (relevancy.map((agent) => agent.key).join(",") !== switched.map((agent) => agent.key).join(",")) {
        throw new Error(`relevancy sorting diverged from quick switching: ${JSON.stringify(relevancy)}`);
      }
      if (helpers.compareAgentsBySort(actionableUnread, noActionReadNewer, "agent_name_asc", {}) >= 0) {
        throw new Error("named agent sorting must not be changed by no-action status");
      }

      const parts = helpers.highlightSearchParts("A <Personal> & personal", "personal");
      if (parts.filter((part) => part.highlighted).length !== 2 || parts.map((part) => part.text).join("") !== "A <Personal> & personal") {
        throw new Error(`visible match ranges were not preserved safely: ${JSON.stringify(parts)}`);
      }
    JAVASCRIPT

    _stdout, stderr, status = Open3.capture3("node", "-e", script, HELPERS_PATH, chdir: ROOT)
    raise "Remote UI agent search regression failed: #{stderr.strip}" unless status.success?

    puts "remote_ui_agent_search_test: ok"
  end
end

RemoteUIAgentSearchTest.run! if $PROGRAM_NAME == __FILE__
