# frozen_string_literal: true

require "open3"
require "tempfile"

module RemoteUIMarkdownFrontmatterTest
  module_function

  ROOT = File.expand_path("..", __dir__)

  def run!
    Tempfile.create(["tycho-markdown-frontmatter", ".js"]) do |script|
      script.write(node_test)
      script.flush
      output, error, status = Open3.capture3("node", script.path, chdir: ROOT)
      raise "Markdown frontmatter parser test failed:\n#{output}#{error}" unless status.success?
    end
    puts "remote_ui_markdown_frontmatter_test: ok"
  end

  def node_test
    <<~'JAVASCRIPT'
      const fs = require("fs");
      const vm = require("vm");
      const source = fs.readFileSync("lib/hq/remote_ui/assets/app.js", "utf8");
      const start = source.indexOf("function splitMarkdownFrontmatter");
      const finish = source.indexOf("\nfunction markdownParserReady", start);
      if (start < 0 || finish < 0) throw new Error("frontmatter parser was not found");
      const context = {};
      vm.runInNewContext(source.slice(start, finish) + "; globalThis.parse = splitMarkdownFrontmatter;", context);
      const parse = context.parse;
      const fixture = fs.readFileSync("test/fixtures/markdown/pr-review-frontmatter.md", "utf8");

      function equal(actual, expected, label) {
        if (actual !== expected) throw new Error(label + ": expected " + JSON.stringify(expected) + ", got " + JSON.stringify(actual));
      }
      function truthy(value, label) {
        if (!value) throw new Error(label);
      }

      const parsedFixture = parse(fixture);
      equal(parsedFixture.metadata.length, 9, "tracked fixture metadata count");
      equal(parsedFixture.frontmatterRejected, false, "tracked fixture is supported");
      truthy(parsedFixture.body.startsWith("\n## Changes since the last review"), "fixture body remains separate");
      truthy(parsedFixture.body.includes("- First retained unordered item."), "fixture body retains Markdown lists");

      const accepted = parse("---\ntitle: \"Safe punctuation, ] } @ ? - # !\"\nowner: O'Reilly\ncount: 42\nlink: https://example.test/a:b\n---\n# Body\n");
      equal(accepted.metadata.length, 4, "quoted and narrow plain scalars are accepted");
      equal(accepted.frontmatterRejected, false, "accepted frontmatter is not rejected");

      [
        "title: !123 value",
        "title: !",
        "title: !!ruby/object:X {}",
        "title: !<tag:example.test,2026:x> hello",
        "title: &",
        "title: *",
        "%TAG ! tag:example.test,2026:",
        "items: [one, two]",
        "note: |",
        "title: \"unterminated",
        "comment: # only a comment",
        "nested: value: child"
      ].forEach((line) => {
        const input = "---\n" + line + "\n---\n## Formatted body\n\n- retained\n";
        const parsed = parse(input);
        equal(parsed.metadata.length, 0, "unsupported input has no metadata: " + line);
        equal(parsed.frontmatterRejected, true, "unsupported input is rejected: " + line);
        equal(parsed.frontmatterSource, "---\n" + line + "\n---", "rejected block remains exact: " + line);
        equal(parsed.body, "## Formatted body\n\n- retained\n", "rejected block keeps Markdown body: " + line);
      });

      const ordinaryRule = parse("---\n# Heading after an ordinary rule\n");
      equal(ordinaryRule.frontmatterRejected, false, "unclosed delimiter is ordinary Markdown");
      equal(ordinaryRule.body, ordinaryRule.source, "unclosed delimiter retains complete document");
    JAVASCRIPT
  end
end

RemoteUIMarkdownFrontmatterTest.run!
