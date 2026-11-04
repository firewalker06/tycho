# frozen_string_literal: true

require "open3"

script = <<~'JS'
  const assert = require("node:assert/strict");
  const fs = require("node:fs");
  const vm = require("node:vm");
  const source = fs.readFileSync(process.argv[1], "utf8");
  const start = source.indexOf("function prettyPrintJsonSource(");
  const end = source.indexOf("\nfunction renderCodeAttachment", start);
  assert(start > 0 && end > start, "prettyPrintJsonSource must exist");
  const context = {};
  vm.createContext(context);
  vm.runInContext(source.slice(start, end), context);
  const pretty = (text) => context.prettyPrintJsonSource(text);

  // The card #796 shape: one long line with extra spacing.
  const oneLine = '{  "name": "Schedule Resume",  "url": "https://example.test/",  "list": [1, 2],  "nested": {"a": null}  }';
  const formatted = pretty(oneLine);
  assert(formatted.split("\n").length > 5, "single-line JSON must become multi-line");
  assert.deepEqual(JSON.parse(formatted), JSON.parse(oneLine), "formatting must not change data");
  assert(formatted.includes('  "name": "Schedule Resume"'));
  assert.equal(pretty('[{"a":1},{"b":[true,false]}]').split("\n")[0], "[");

  // Content that must stay untouched.
  const multiline = '{\n"a": 1\n}\n';
  assert.equal(pretty(multiline), multiline, "already multi-line JSON stays as-is");
  const lines = '{"a":1}\n{"b":2}';
  assert.equal(pretty(lines), lines, "JSON Lines stays as-is");
  const truncated = '{"a": [1, 2, 3';
  assert.equal(pretty(truncated), truncated, "invalid or truncated JSON stays as-is");
  assert.equal(pretty("plain text"), "plain text");
  assert.equal(pretty(""), "");
  assert.equal(pretty(null), "");
  const bigNumber = '{"id": 12345678901234567890}';
  assert.equal(pretty(bigNumber), bigNumber, "lossy number round trips stay as-is");
  const keepsSpaces = pretty('{"text": "a  b   c"}');
  assert(keepsSpaces.includes('"a  b   c"'), "string whitespace is preserved");

  // Prism must not auto-highlight on load: it rebuilds code from textContent and
  // drops the newlines between per-line spans, which showed multi-line JSON as one line.
  (async () => {
    const hStart = source.indexOf("function ensureCodeHighlighterLoaded(");
    const hEnd = source.indexOf("\nfunction highlightedCodeHtml", hStart);
    assert(hStart > 0 && hEnd > hStart, "ensureCodeHighlighterLoaded must exist");
    const seen = [];
    const win = {};
    const ctx = {
      window: win,
      codeHighlighter: { promise: null, failedLanguages: {}, loadedLanguages: {} },
      CODE_HIGHLIGHTER_SCRIPT_URLS: { prism: "prism.js" },
      CODE_LANGUAGE_COMPONENT_URLS: {},
      codeHighlighterReady: () => false,
      renderCodeRoute() {},
      loadExternalScript: async (url) => { seen.push({ url, manual: win.Prism?.manual }); win.Prism = { ...win.Prism, highlight() {}, languages: {} }; },
      console: { warn() {} },
    };
    vm.createContext(ctx);
    vm.runInContext(source.slice(hStart, hEnd), ctx);
    await ctx.ensureCodeHighlighterLoaded("json");
    assert.equal(seen[0]?.url, "prism.js");
    assert.equal(seen[0].manual, true, "Prism.manual must be set before the Prism script loads");
  })().catch((error) => { console.error(error); process.exitCode = 1; });
JS
out, err, status = Open3.capture3("node", "-e", script, File.expand_path("../lib/hq/remote_ui/assets/app.js", __dir__))
raise "JSON preview regression failed: #{out}#{err}" unless status.success?
puts "remote_ui_json_preview_test: ok"
