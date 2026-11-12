# frozen_string_literal: true

require "open3"
require "tempfile"

# Check resolution without a browser. Actual decoding, sanitizing, and authenticated
# reads are covered by the isolated markdown_images_smoke browser fixture.
source = File.read(File.expand_path("../lib/hq/remote_ui/assets/app.js", __dir__))
functions = source[source.index("function markdownLocalPath")...source.index("function prepareMarkdownImages")]
Tempfile.create(["tycho-markdown-images", ".js"]) do |script|
  script.write(<<~JS)
    const assert = require("assert");
    #{functions}
    const attachmentTarget = a => a.path || a.url;
    const attachmentKind = a => a.type;
    const attachmentFormat = a => a.format;
    const attachmentBlobPath = id => `/attachments/${encodeURIComponent(id)}/blob`;
    const agent = {workspace: "/fixture/project", project_key: "peer/web", attachments: [
      {type: "file", format: "image", id: "peer/picture", path: "/fixture/outside/picture.png"},
      {type: "file", format: "image", id: "peer/relative", path: "assets/relative.png"}
    ]};
    const findProject = key => key === "peer/web" ? {path: "/fixture/project"} : null;
    const context = {agent};
    assert.strictEqual(markdownImageResource("assets/space%20image.png", context), "/projects/peer%2Fweb/workspace/image?path=assets%2Fspace+image.png");
    assert.strictEqual(markdownImageResource("/fixture/project/assets/image.svg", context), "/projects/peer%2Fweb/workspace/image?path=assets%2Fimage.svg");
    assert.strictEqual(markdownImageResource("file:///fixture/project/assets/image.svg", context), "/projects/peer%2Fweb/workspace/image?path=assets%2Fimage.svg");
    assert.strictEqual(markdownImageResource("/fixture/outside/picture.png", context), "/attachments/peer%2Fpicture/blob");
    assert.strictEqual(markdownImageResource("assets/relative.png", context), "/attachments/peer%2Frelative/blob");
    assert.strictEqual(markdownImageResource("../assets/image.png", {agent, attachment: {path: "docs/report.md"}}), "/projects/peer%2Fweb/workspace/image?path=assets%2Fimage.png");
    assert.strictEqual(markdownImageResource("picture.png", {agent, attachment: {path: "/fixture/outside/report.md"}}), "/attachments/peer%2Fpicture/blob");
    for (const value of ["", "https://evil.test/tracker.png", "//evil.test/image.png", "javascript:alert(1)", "data:image/png;base64,AA", "blob:https://evil.test/id", "file://evil.test/path.png", "../private.png", "/fixture/project-other/image.png", "/etc/passwd", "%ZZ.png", "%00.png", "%2e%2e%2fprivate.png", "a%5cb.png"]) {
      assert.strictEqual(markdownImageResource(value, context), null, value);
    }
    assert.strictEqual(markdownImageResource("image.png", {}), null);
    assert.strictEqual(markdownImageResource("image.png", {agent: {...agent, workspace: "/fixture/project/sub"}}), "/projects/peer%2Fweb/workspace/image?path=sub%2Fimage.png");
    assert.strictEqual(markdownImageResource("image.png", {agent: {...agent, workspace: "/fixture/unregistered"}}), null);
    console.log("remote_ui_markdown_images_test: ok");
  JS
  script.flush
  output, error, status = Open3.capture3("node", script.path)
  raise "Markdown image resolution failed:\n#{output}#{error}" unless status.success?

  puts output
end
