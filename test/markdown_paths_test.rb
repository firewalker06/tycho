# frozen_string_literal: true

require "fileutils"
require "tmpdir"
require_relative "support/markdown_paths"

# Exact input and expected outcomes from the PR #328 review reproductions.
cases = [
  ["relative_link", "[Guide](docs/guide.md)\n", true],
  ["remote_home", "[Remote](https://example.test/home/user)\n", true],
  ["remote_nested_home", "[Remote](https://example.test/help/home/user)\n", true],
  ["remote_dash_home", "[Remote](https://example.test/-/home/user)\n", true],
  ["remote_query_home", "[Remote](https://example.test/find?path=/home/user)\n", true],
  ["remote_hash_route", "[Remote](https://example.test/#/home/user)\n", true],
  ["home_relative", "`~/.tycho/logs/`\n", true],
  ["marked_inline", "`/home/example/notes` <!-- local-path-example: Placeholder path. -->\n", true],
  ["marked_backtick_block", "<!-- local-path-example: Placeholder command. -->\n```sh\ncat /home/example/notes\n```\n", true],
  ["marked_tilde_block", "<!-- local-path-example: Placeholder command. -->\n~~~sh\ncat /home/example/notes\n~~~\n", true],
  ["marked_long_fence", "<!-- local-path-example: Fence example. -->\n````text\n```\n/home/example/notes\n````\n", true],
  ["fence_boundary", "<!-- local-path-example: Placeholder command. -->\n```sh\ncat /home/example/notes\n```\n/home/alice/real-notes\n", false],
  ["users_plain", "/Users/alice/notes.md\n", false],
  ["home_plain", "/home/alice/notes.md\n", false],
  ["tmp_plain", "/tmp/report.md\n", false],
  ["windows_plain", "C:\\Users\\Alice\\notes.md\n", false],
  ["file_uri", "[Notes](file:///Users/alice/notes.md)\n", false],
  ["absolute_markdown", "[Notes](/data/notes.md)\n", false],
  ["absolute_reference", "[Notes]: /data/notes.md\n", false],
  ["html_link", "<a href=\"/data/notes.md\">Notes</a>\n", false],
  ["html_link_spaced", "<a href = \"/data/notes.md\">Notes</a>\n", false],
  ["html_image_spaced", "<img src = \"/data/notes.png\">\n", false],
  ["html_attribute_uppercase", "<a HREF=\"/data/notes.md\">Notes</a>\n", false],
  ["case_insensitive_suffix", "/Users/alice/notes.md\n", false],
  ["remote Users path", "[Remote](https://example.test/-/Users/alice)", true],
  ["remote Users query", "https://example.test/find?path=/Users/alice", true],
  ["remote Users fragment", "<https://example.test/#/Users/alice>", true],
  ["other scheme", "[Remote](sftp://example.test/-/home/alice)", true],
  ["opaque scheme", "custom:notes?path=/home/alice", true],
  ["local after remote", "https://example.test/-/home/alice /Users/alice/notes", false],
  ["single quotes", "<a href='/data/notes.md'>Notes</a>", false],
  ["unquoted link", "<a href=/data/notes.md>Notes</a>", false],
  ["unquoted image", "<img src=/data/notes.png>", false],
  ["mixed whitespace", "<a title='Notes' HREF \t= '/data/notes.md'>Notes</a>", false],
  ["attribute order", "<img alt='Notes' width=20 SRC = /data/notes.png>", false],
  ["multiline attribute", "<a title='Notes'\n href \n=\n '/data/notes.md'>Notes</a>", false],
  ["quoted angle", "<a title='a > b' href='/data/notes.md'>Notes</a>", false],
  ["encoded target", "<a href='&#47;data/notes.md'>Notes</a>", false],
  ["attribute text", "<a title=\"href='/data/notes.md'\" href='notes.md'>Notes</a>", true],
  ["relative HTML", "<img ALT='Notes' SRC = '../images/notes.png'>", true],
  ["remote HTML", "<a HREF = 'https://example.test/-/home/alice'>Notes</a>", true],
  ["remote image", "<img SRC=https://example.test/find?path=/Users/alice>", true],
  ["remote attribute text", "<a title='https://example.test/-/home/alice' href='notes.md'>Notes</a>", true],
  ["marked HTML", "<a HREF = '/data/notes.md'>Notes</a> <!-- local-path-example: Target. -->", false],
  ["marked link block", "<!-- local-path-example: Target. -->\n```html\n<a href='/data/notes.md'>Notes</a>\n```", false],
  ["angle Markdown", "[Notes](</data/notes with spaces.md>)", false],
  ["angle reference", "[Notes]: </data/notes with spaces.md>", false],
  ["Windows target", "[Notes](C:/data/notes.md) <!-- local-path-example: Target. -->", false],
  ["file target", "<a href='file:///data/notes.md'>Notes</a>", false],
  ["home runtime", "`~/.tycho/logs/`", true],
  ["API route", "`GET /projects/{key}/workspace/preview`", true]
]

cases.each do |name, input, allowed|
  actual = MarkdownPaths.invalid_lines(input)
  raise "#{name}: expected allowed=#{allowed}, got #{actual.inspect}" unless actual.empty? == allowed
end
raise "expected attribute line number" unless MarkdownPaths.invalid_lines("<a\n href='/data/notes.md'>Notes</a>\n") == [2]

Dir.mktmpdir("tycho-markdown-paths-") do |root|
  system("git", "init", "-q", root, exception: true)
  FileUtils.mkdir_p(File.join(root, "docs"))
  path = File.join(root, "docs", "with space.MD")
  File.write(path, "[Guide](guide.md)\n")
  File.write(File.join(root, "untracked.md"), "/Users/alice/notes.md\n")
  system("git", "add", "docs/with space.MD", chdir: root, exception: true)
  raise "untracked files must be ignored" unless MarkdownPaths.check(root).empty?

  File.write(path, "# Notes\n<a href = '/data/notes.md'>Notes</a>\n")
  expected = "docs/with space.MD:2: <a href = '/data/notes.md'>Notes</a>"
  raise "expected tracked filename, line, and text" unless MarkdownPaths.check(root) == [expected]
end

puts "markdown_paths_test: ok (#{cases.length} content cases and tracked-file checks)"
