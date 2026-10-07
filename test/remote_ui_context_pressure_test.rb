# frozen_string_literal: true

require "open3"

module RemoteUIContextPressureTest
  module_function

  ROOT = File.expand_path("..", __dir__)
  APP_PATH = File.join(ROOT, "lib", "hq", "remote_ui", "assets", "app.js")
  CSS_PATH = File.join(ROOT, "lib", "hq", "remote_ui", "assets", "app.css")

  def run!
    script = <<~'JAVASCRIPT'
      const fs = require("fs");
      const vm = require("vm");
      const source = fs.readFileSync(process.argv[1], "utf8");
      const styles = fs.readFileSync(process.argv[2], "utf8");
      const start = source.indexOf("function renderContextPressureWarning");
      const end = source.indexOf("\nfunction linkedAgentReferences", start);
      if (start < 0 || end < 0) throw new Error("missing context warning renderer");
      const context = {
        escapeAttr: String,
        escapeHtml: String,
        iconSvg: (name) => `<i>${name}</i>`,
        moreMenuButton: ({ label, icon, attrs = "", danger = false, disabled = false }) =>
          `<button role="menuitem" class="${danger ? "danger" : ""}" ${attrs} ${disabled ? "disabled" : ""}><i>${icon}</i>${label}</button>`,
        moreMenuSeparator: () => '<span role="separator"></span>',
        moreMenuHtml: (items) => `<div role="menu">${items.join("")}</div>`,
      };
      vm.createContext(context);
      vm.runInContext(`${source.slice(start, end)}\nthis.renderContextPressureWarning = renderContextPressureWarning;`, context);
      const html = context.renderContextPressureWarning({
        key: "agent-1",
        context_pressure: {
          warning: true, basis: "measured", summary: "Context pressure is high", detail: "Measured by harness",
          used_tokens: 90, limit_tokens: 100, signal_id: "signal-1", actions: { archive: false },
        },
      });
      for (const text of ["Start New", "Keep Going", "Start with Handoff", "Archive", "90% active-context usage"]) {
        if (!html.includes(text)) throw new Error(`missing warning action: ${text}`);
      }
      if (html.includes("90 of 100") || html.includes("active tokens reported")) {
        throw new Error("measured warning must not render an x-of-y token count");
      }
      for (const icon of ["shieldAlert", "sportShoe", "thumbsUp", "ellipsis"]) {
        if (!html.includes(`<i>${icon}</i>`)) throw new Error(`missing warning icon: ${icon}`);
      }
      if (!html.includes("data-context-pressure-ack") || !html.includes("data-context-pressure-dismiss") || !html.includes("disabled") ||
          !html.includes('aria-label="More context pressure actions"') ||
          !html.includes('aria-haspopup="menu"') || !html.includes('role="menu"')) {
        throw new Error("warning actions do not expose safe control state");
      }
      const topLevelActions = html.match(/data-context-pressure-(?:clone|ack)=/g) || [];
      if (topLevelActions.length !== 2 || !html.includes('class="context-pressure-dismiss inline-icon-button ui-button"') || !html.includes('class="primary inline-icon-button ui-button"')) {
        throw new Error("warning must expose exactly two primary actions before the menu");
      }
      if (context.renderContextPressureWarning({ key: "quiet", context_pressure: { warning: false } }) !== "") {
        throw new Error("unknown or acknowledged state must not show a warning");
      }
      const compactionHtml = context.renderContextPressureWarning({
        key: "compacted",
        context_pressure: {
          warning: true, basis: "reported", summary: "The harness compacted this session",
          detail: "The harness reported a compaction.", signal_id: "signal-2", actions: { archive: true },
        },
      });
      if (!compactionHtml.includes("No context percentage is shown") || compactionHtml.includes("NaN%")) {
        throw new Error("reported-only warning must explain that no percentage is available");
      }
      if (!source.includes("archive_source: false") || !source.includes("context_handoff: handoff") ||
          !source.includes("start: handoff") || !styles.includes(".context-pressure-warning") ||
          !styles.includes(".context-pressure-dismiss") || !styles.includes("position: absolute") ||
          !styles.includes(".context-pressure-warning-copy > div") || !styles.includes("padding-right")) {
        throw new Error("clone safety or warning styles are missing");
      }
    JAVASCRIPT
    _stdout, stderr, status = Open3.capture3("node", "-e", script, APP_PATH, CSS_PATH)
    raise "Remote UI context pressure regression failed: #{stderr.strip}" unless status.success?

    puts "remote_ui_context_pressure_test: ok"
  end
end

RemoteUIContextPressureTest.run!
