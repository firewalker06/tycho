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
      context.escapeAttr = (value) => String(value);
      context.markdownViewerClassName = () => "markdown-viewer";
      context.prepareMarkdownCodeBlocks = (html) => html;
      context.window = {
        marked: {
          parse: (markdown) => {
            if (markdown.includes("1. first")) {
              return "<ol><li>first<ul><li>nested</li></ul></li></ol><hr><pre><code class=\"language-ruby\">puts :safe</code></pre>";
            }
            return "<h2>Changes since the last review</h2><ul><li>First retained unordered item.</li><li>Second retained unordered item.</li></ul>";
          }
        },
        DOMPurify: { sanitize: (html) => html }
      };
      vm.runInNewContext(source.slice(start, finish) + "; globalThis.parse = splitMarkdownFrontmatter; globalThis.render = renderMarkdown;", context);
      const parse = context.parse;
      const render = context.render;
      const escapeStart = source.indexOf("function escapeHtml");
      const escapeFinish = source.indexOf("\nfunction highlightSearchText", escapeStart);
      const metadataStart = source.indexOf("function renderMarkdownFrontmatter");
      const metadataFinish = source.indexOf("\nfunction prepareMarkdownCodeBlocks", metadataStart);
      const parsedStart = source.indexOf("function renderParsedMarkdown");
      const parsedFinish = source.indexOf("\nfunction prepareMarkdownCodeBlocks", parsedStart);
      vm.runInContext(source.slice(escapeStart, escapeFinish) + source.slice(metadataStart, metadataFinish) + source.slice(parsedStart, parsedFinish) + "; globalThis.renderMetadata = renderMarkdownFrontmatter;", context);
      const fixture = fs.readFileSync("test/fixtures/markdown/pr-review-frontmatter.md", "utf8");

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
      truthy(parsedFixture.body.includes("- First retained unordered item."), "fixture unordered lists must remain");
      equal(render(fixture), "plain:" + fixture, "loading fallback must retain complete fixture source");
      context.markdownParserReady = () => true;
      const renderedFixture = render(fixture);
      truthy(renderedFixture.includes("markdown-frontmatter"), "parsed renderer must render metadata");
      truthy(renderedFixture.includes("<ul>") && renderedFixture.includes("<li>"), "parsed renderer must render unordered lists");
      truthy(!renderedFixture.includes("URL: https://"), "parsed renderer must remove accepted frontmatter from body");
      context.markdownParserReady = () => false;
      context.markdownParser.failed = true;
      equal(render(fixture), "plain:" + fixture, "permanent fallback must retain complete fixture source");

      const fence = String.fromCharCode(96).repeat(3);
      context.markdownParser.failed = false;
      context.markdownParserReady = () => true;
      const accepted = parse("---\ntitle: \"Safe title\"\ncount: 42\nenabled: true\nempty: null\nlink: https://example.test/a:b\n---\n1. first\n   - nested\n---\n" + fence + "ruby\nputs :safe\n" + fence + "\n");
      equal(accepted.metadata.length, 5, "safe scalar metadata count");
      truthy(accepted.body.includes("1. first\n   - nested\n---\n" + fence + "ruby"), "ordered lists, nesting, rules, and fences must remain in body");
      const renderedAccepted = render(accepted.source);
      truthy(renderedAccepted.includes("<ol>"), "renderer must render ordered lists");
      truthy(renderedAccepted.includes("<ul>"), "renderer must render nested unordered lists");
      truthy(renderedAccepted.includes("<hr>"), "renderer must render ordinary horizontal rules");
      truthy(renderedAccepted.includes("<pre><code"), "renderer must render fenced code blocks");

      const hostile = parse("---\ntitle: <img src=x onerror=alert(1)>\n---\n- body\n");
      equal(hostile.metadata.length, 1, "hostile HTML is scalar text, not executable input");
      equal(hostile.metadata[0].value, "<img src=x onerror=alert(1)>", "hostile HTML must remain text for later escaping");
      const hostileHtml = render(hostile.source);
      truthy(hostileHtml.includes("&lt;img"), "metadata renderer must escape hostile HTML");
      truthy(!hostileHtml.includes("<img"), "metadata renderer must not emit hostile HTML");

      [
        "items: [one, two]",
        "meta: {owner: me}",
        "alias: *name",
        "tag: !ruby/object:X",
        "tag: !!ruby/object:X {}",
        "tag: !<tag:example.test,2026:x> hello",
        "anchor: &name",
        "note: |",
        "folded: >",
        "title: \"unterminated",
        "title: 'unterminated",
        "nested: value: child",
        "comment: text # comment",
        "comment: # only a comment",
        "sequence: -item",
        "mapping: ?item",
        "reserved: @value",
        "reserved: " + String.fromCharCode(96) + "value",
        "reserved: ,value",
        "reserved: ]",
        "reserved: }",
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
