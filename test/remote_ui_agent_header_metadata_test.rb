# frozen_string_literal: true

require "open3"

module RemoteUIAgentHeaderMetadataTest
  module_function

  ROOT = File.expand_path("..", __dir__)
  APP_PATH = File.join(ROOT, "lib", "hq", "remote_ui", "assets", "app.js")
  CSS_PATH = File.join(ROOT, "lib", "hq", "remote_ui", "assets", "app.css")

  def run!
    css = File.read(CSS_PATH)
    subtitle_rule = css[/^[ \t]*\.subtitle-status-text \{([^}]*)\}/, 1]
    unless subtitle_rule&.include?("white-space: nowrap") &&
           subtitle_rule.include?("overflow: hidden") && subtitle_rule.include?("text-overflow: ellipsis")
      raise "header metadata must use one-line ellipsis"
    end
    if css.match?(/\.app-header\.detail-header \.subtitle-status-text \{[^}]*white-space: normal/m)
      raise "mobile detail-header metadata must preserve one-line ellipsis"
    end

    script = <<~'JAVASCRIPT'
      const fs = require("fs");
      const vm = require("vm");
      const source = fs.readFileSync(process.argv[1], "utf8");
      const start = source.indexOf("function focusedWorkspacePreservedDuringPoll");
      const end = source.indexOf("\nfunction focusedWorkspaceAgent", start);
      if (start < 0 || end < 0) throw new Error("missing focused workspace subtitle functions");
      const agent = {
        key: "fixture", name: "Fixture", server_key: "local", project_key: "secondbrain",
        agent: "codex", model: "gpt-6.2-sol", reasoning_effort: "low", status: "succeeded",
      };
      const headerStart = source.indexOf("function agentHeaderLabel");
      const headerEnd = source.indexOf("\nfunction agentTemplateLabel", headerStart);
      const context = {
        parseRoute: () => ({ type: "agentSummary", key: agent.key }),
        focusedWorkspaceAgent: () => agent,
        findAgent: () => agent,
        agentProjectLabel: () => "Second Brain",
        agentHarnessLabel: value => value.agent || "agent",
        resourceServer: () => ({ local: true, name: "Host" }),
        serverDisplayName: server => server.local ? "Host" : server.name,
        statusLabel: value => value.running ? "Running" : value.status,
      };
      vm.createContext(context);
      vm.runInContext(`${source.slice(headerStart, headerEnd)}\n${source.slice(start, end)}\nthis.subtitle = focusedWorkspacePollingSubtitle;`, context);
      const expected = "Paused / succeeded / Host / Second Brain / codex / gpt-6.2-sol / low";
      if (context.subtitle() !== expected) throw new Error(`metadata mismatch: ${context.subtitle()}`);
      if (context.agentHeaderLabel(agent) !== "succeeded / Host / Second Brain / codex / gpt-6.2-sol / low") {
        throw new Error("Conversation and side-panel header did not include status");
      }
      agent.running = true;
      if (!context.subtitle().startsWith("Paused / Running / Host / Second Brain") ||
          !context.agentHeaderLabel(agent).startsWith("Running / Host / Second Brain")) {
        throw new Error("focused subtitle did not use the current running status");
      }
      agent.model = "new-model";
      if (!context.subtitle().endsWith("new-model / low")) throw new Error("focused subtitle did not use updated metadata");
      if (!context.agentHeaderLabel(agent).endsWith("new-model / low")) throw new Error("conversation subtitle did not use updated metadata");
    JAVASCRIPT
    _stdout, stderr, status = Open3.capture3("node", "-e", script, APP_PATH)
    raise "Remote UI agent header metadata regression failed: #{stderr.strip}" unless status.success?

    puts "remote_ui_agent_header_metadata_test: ok"
  end
end

RemoteUIAgentHeaderMetadataTest.run!
