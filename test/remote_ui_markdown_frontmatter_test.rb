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
      raise "Markdown renderer behavior test failed:\n#{output}#{error}" unless status.success?
    end
    puts "remote_ui_markdown_frontmatter_test: ok"
  end

  def node_test
    <<~'JAVASCRIPT'
      const fs = require("fs");
      const vm = require("vm");
      const source = fs.readFileSync("lib/hq/remote_ui/assets/app.js", "utf8");
      const start = source.indexOf("function renderMarkdown");
      const finish = source.indexOf("\nfunction markdownParserReady", start);
      if (start < 0 || finish < 0) throw new Error("frontmatter parser was not found");
      const context = {};
      context.state = { markdownFallbackSequence: 0, markdownFallbacks: new Map() };
      context.markdownParser = { failed: false };
      context.MARKDOWN_FALLBACK_LIMIT = 200;
      context.markdownParserReady = () => false;
      context.ensureMarkdownParserLoaded = () => {};
      context.renderPlainTextMarkdown = (text) => "plain:" + text;
      context.renderParsedMarkdown = (document) => JSON.stringify(document);
      vm.runInNewContext(source.slice(start, finish) + "; globalThis.parse = splitMarkdownFrontmatter; globalThis.render = renderMarkdown;", context);
      const parse = context.parse;
      const render = context.render;
      const escapeStart = source.indexOf("function escapeHtml");
      const escapeFinish = source.indexOf("\nfunction highlightSearchText", escapeStart);
      const metadataStart = source.indexOf("function renderMarkdownFrontmatter");
      const metadataFinish = source.indexOf("\nfunction prepareMarkdownCodeBlocks", metadataStart);
      vm.runInContext(source.slice(escapeStart, escapeFinish) + source.slice(metadataStart, metadataFinish) + "; globalThis.renderMetadata = renderMarkdownFrontmatter;", context);
      const fixture = fs.readFileSync("/tmp/tycho-pr-review-50154.md", "utf8");

      function equal(actual, expected, label) {
        if (actual !== expected) throw new Error(label + ": expected " + JSON.stringify(expected) + ", got " + JSON.stringify(actual));
      }
      function truthy(value, label) {
        if (!value) throw new Error(label);
      }

      const parsedFixture = parse(fixture);
      equal(parsedFixture.metadata.length, 9, "fixture metadata count");
      truthy(parsedFixture.source.startsWith("---\nURL:"), "fixture source must remain complete for fallback");
      truthy(parsedFixture.body.startsWith("\n## Changes since the last review"), "fixture body must retain the Markdown document");
      truthy(parsedFixture.body.includes("- **Original comment:**"), "fixture unordered lists must remain");
      equal(render(fixture), "plain:" + fixture, "loading fallback must retain complete fixture source");
      context.markdownParserReady = () => true;
      const renderedFixture = JSON.parse(render(fixture));
      equal(renderedFixture.body, parsedFixture.body, "parsed renderer must receive only Markdown body");
      equal(renderedFixture.metadata.length, 9, "parsed renderer must receive fixture metadata");
      context.markdownParserReady = () => false;
      context.markdownParser.failed = true;
      equal(render(fixture), "plain:" + fixture, "permanent fallback must retain complete fixture source");

      const fence = String.fromCharCode(96).repeat(3);
      const accepted = parse("---\ntitle: \"Safe title\"\ncount: 42\nenabled: true\nempty: null\nlink: https://example.test/a:b\n---\n1. first\n   - nested\n---\n" + fence + "ruby\nputs :safe\n" + fence + "\n");
      equal(accepted.metadata.length, 5, "safe scalar metadata count");
      truthy(accepted.body.includes("1. first\n   - nested\n---\n" + fence + "ruby"), "ordered lists, nesting, rules, and fences must remain in body");

      const hostile = parse("---\ntitle: <img src=x onerror=alert(1)>\n---\n- body\n");
      equal(hostile.metadata.length, 1, "hostile HTML is scalar text, not executable input");
      equal(hostile.metadata[0].value, "<img src=x onerror=alert(1)>", "hostile HTML must remain text for later escaping");
      const hostileHtml = context.renderMetadata(hostile.metadata);
      truthy(hostileHtml.includes("&lt;img"), "metadata renderer must escape hostile HTML");
      truthy(!hostileHtml.includes("<img"), "metadata renderer must not emit hostile HTML");

      [
        "items: [one, two]",
        "meta: {owner: me}",
        "alias: *name",
        "tag: !ruby/object:X",
        "anchor: &name",
        "note: |",
        "folded: >",
        "title: \"unterminated",
        "title: 'unterminated",
        "nested: value: child",
        "comment: text # comment",
        "multi: line\n  continuation"
      ].forEach((line) => {
        const input = "---\n" + line + "\n---\n- body\n";
        const parsed = parse(input);
        equal(parsed.metadata.length, 0, "unsupported value must not become metadata: " + line);
        equal(parsed.body, input, "unsupported value must retain full body: " + line);
        equal(parsed.source, input, "unsupported value must retain full source: " + line);
      });
    JAVASCRIPT
  end
end

RemoteUIMarkdownFrontmatterTest.run!
