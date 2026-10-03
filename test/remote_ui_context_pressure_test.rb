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
        formatCompactMetricNumber: (value) => String(value),
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
      for (const text of ["Keep going", "Clone fresh", "Clone with handoff", "Archive when safe", "90 of 100 active tokens reported"]) {
        if (!html.includes(text)) throw new Error(`missing warning action: ${text}`);
      }
      if (!html.includes("data-context-pressure-ack") || !html.includes("disabled")) {
        throw new Error("warning actions do not expose safe control state");
      }
      if (context.renderContextPressureWarning({ key: "quiet", context_pressure: { warning: false } }) !== "") {
        throw new Error("unknown or acknowledged state must not show a warning");
      }
      if (!source.includes("archive_source: false") || !styles.includes(".context-pressure-warning")) {
        throw new Error("clone safety or warning styles are missing");
      }
    JAVASCRIPT
    _stdout, stderr, status = Open3.capture3("node", "-e", script, APP_PATH, CSS_PATH)
    raise "Remote UI context pressure regression failed: #{stderr.strip}" unless status.success?

    puts "remote_ui_context_pressure_test: ok"
  end
end

RemoteUIContextPressureTest.run!
