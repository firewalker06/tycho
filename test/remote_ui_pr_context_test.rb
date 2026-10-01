# frozen_string_literal: true

require "open3"

module RemoteUIPullRequestContextTest
  module_function

  ROOT = File.expand_path("..", __dir__)
  HELPERS_PATH = File.join(ROOT, "lib", "hq", "remote_ui", "assets", "app_helpers.js")
  APP_PATH = File.join(ROOT, "lib", "hq", "remote_ui", "assets", "app.js")

  def run!
    script = <<~'JAVASCRIPT'
      const fs = require("fs");
      const vm = require("vm");
      const helpersContext = { window: {} };
      vm.createContext(helpersContext);
      vm.runInContext(fs.readFileSync(process.argv[1], "utf8"), helpersContext);
      const helpers = helpersContext.window.TychoRemoteHelpers;

      const contextBlock = (overrides = {}) => {
        const payload = {
          identity: {
            url: "https://github.com/example/web/pull/123",
            repository: "example/web",
            number: 123,
            snapshot_id: "snapshot-1",
            base_sha: "1234567890abcdef",
            head_sha: "fedcba0987654321",
          },
          lines: [
            { path: "lib/new.rb", old_path: "lib/old.rb", side: "left", kind: "removed", old_number: 8, content: "old <script>" },
            { path: "lib/new.rb", old_path: "lib/old.rb", side: "right", kind: "added", new_number: 9, content: "new & better" },
            { path: "lib/new.rb", old_path: "lib/old.rb", side: "both", kind: "context", old_number: 10, new_number: 10, content: "same" },
          ],
          omitted_lines: 2,
          snapshot_truncated: true,
          ...overrides,
        };
        return `[TYCHO_PR_DIFF_CONTEXT]\n${JSON.stringify(payload)}\n[/TYCHO_PR_DIFF_CONTEXT]`;
      };

      const content = [
        "Please address both comments.",
        contextBlock(),
        "Comment on this range:\nUse <img src=x onerror=alert(1)> & explain why.",
        contextBlock({
          identity: {
            url: "https://github.com/example/api/pull/456",
            repository: "example/api",
            number: 456,
          },
          lines: [{ path: "app/model.rb", side: "right", kind: "added", new_number: 2, content: "safe" }],
          omitted_lines: undefined,
          snapshot_truncated: undefined,
        }),
      ].join("\n");
      const parsed = helpers.parsePullRequestContextMessage(content);
      if (!parsed || parsed.length !== 3 || parsed[0].type !== "text" ||
          parsed[1].comment !== "Use <img src=x onerror=alert(1)> & explain why." ||
          parsed[1].payload.lines.map((line) => line.kind).join(",") !== "removed,added,context" ||
          parsed[2].payload.identity.number !== 456 || parsed[2].comment !== "") {
        throw new Error(`representative PR contexts were not parsed: ${JSON.stringify(parsed)}`);
      }

      const malformed = [
        "[TYCHO_PR_DIFF_CONTEXT]\n{bad json}\n[/TYCHO_PR_DIFF_CONTEXT]",
        contextBlock({ identity: { url: "javascript:alert(1)", repository: "example/web", number: 123 } }),
        contextBlock({ identity: { url: "https://github.com/example/web/pull/999", repository: "example/web", number: 123 } }),
        contextBlock({ lines: [{ path: "x.rb", side: "right", kind: "removed", old_number: 1, content: "bad" }] }),
        "[TYCHO_PR_DIFF_CONTEXT]\n{}",
        `${contextBlock()}\nunrecognized trailing content`,
      ];
      malformed.forEach((candidate, index) => {
        if (helpers.parsePullRequestContextMessage(candidate) !== null) {
          throw new Error(`malformed PR context ${index} did not use raw fallback`);
        }
      });

      const source = fs.readFileSync(process.argv[2], "utf8");
      function extractFunction(name) {
        const marker = `function ${name}(`;
        const start = source.indexOf(marker);
        if (start < 0) throw new Error(`missing ${name}`);
        const bodyStart = source.indexOf("{", start);
        let depth = 0;
        let quote = null;
        let escaped = false;
        for (let index = bodyStart; index < source.length; index += 1) {
          const char = source[index];
          if (quote) {
            if (escaped) escaped = false;
            else if (char === "\\") escaped = true;
            else if (char === quote) quote = null;
            continue;
          }
          if (["\"", "'", "`"].includes(char)) {
            quote = char;
          } else if (char === "{") {
            depth += 1;
          } else if (char === "}") {
            depth -= 1;
            if (depth === 0) return source.slice(start, index + 1);
          }
        }
        throw new Error(`unterminated ${name}`);
      }

      const renderContext = {
        REMOTE_HELPERS: helpers,
        escapeHtml: (value) => String(value).replaceAll("&", "&amp;").replaceAll("<", "&lt;").replaceAll(">", "&gt;").replaceAll('"', "&quot;"),
        escapeAttr: (value) => String(value).replaceAll("&", "&amp;").replaceAll("<", "&lt;").replaceAll(">", "&gt;").replaceAll('"', "&quot;"),
        iconSvg: () => "<svg aria-hidden=\"true\"></svg>",
      };
      vm.createContext(renderContext);
      const renderFunctions = [
        "renderPullRequestContextMessage",
        "renderPullRequestContext",
        "pullRequestContextFileGroups",
        "renderPullRequestContextFile",
        "renderPullRequestContextLine",
      ].map(extractFunction).join("\n");
      vm.runInContext(`${renderFunctions}\nthis.renderPullRequestContextMessage = renderPullRequestContextMessage;`, renderContext);
      const html = renderContext.renderPullRequestContextMessage(content);
      if (!html.includes('href="https://github.com/example/web/pull/123"') ||
          !html.includes("lib/old.rb") || !html.includes("lib/new.rb") ||
          !html.includes("2 additional selected lines were omitted") ||
          !html.includes("The source diff snapshot was truncated") ||
          !html.includes("&lt;script&gt;") || !html.includes("&lt;img src=x onerror=alert(1)&gt;") ||
          html.includes("<script>") || html.includes("<img src=x")) {
        throw new Error(`structured PR context was incomplete or unsafe: ${html}`);
      }
      if (renderContext.renderPullRequestContextMessage(malformed[0]) !== "") {
        throw new Error("malformed PR context renderer bypassed raw-content fallback");
      }
    JAVASCRIPT

    _stdout, stderr, status = Open3.capture3("node", "-e", script, HELPERS_PATH, APP_PATH, chdir: ROOT)
    raise "Remote UI PR context regression failed: #{stderr.strip}" unless status.success?

    puts "remote_ui_pr_context_test: ok"
  end
end

RemoteUIPullRequestContextTest.run! if $PROGRAM_NAME == __FILE__
