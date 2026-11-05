# frozen_string_literal: true

require "fileutils"
require "tmpdir"
require_relative "support/markdown_paths"

# Review reproductions plus strict scanning of every line, including code.
cases = [
  ["relative_link", "[Guide](docs/guide.md)\n", true],
  ["remote_home", "[Remote](https://example.test/home/user)\n", true],
  ["remote_nested_home", "[Remote](https://example.test/help/home/user)\n", true],
  ["remote_dash_home", "[Remote](https://example.test/-/home/user)\n", true],
  ["remote_query_home", "[Remote](https://example.test/find?path=/home/user)\n", true],
  ["remote_hash_route", "[Remote](https://example.test/#/home/user)\n", true],
  ["home_relative", "`~/.tycho/logs/`\n", false],
  ["marked_inline", "`/home/example/notes` <!-- local-path-example: Placeholder path. -->\n", false],
  ["marked_backtick_block", "<!-- local-path-example: Placeholder command. -->\n```sh\ncat /home/example/notes\n```\n", false],
  ["marked_tilde_block", "<!-- local-path-example: Placeholder command. -->\n~~~sh\ncat /home/example/notes\n~~~\n", false],
  ["marked_long_fence", "<!-- local-path-example: Fence example. -->\n````text\n```\n/home/example/notes\n````\n", false],
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
  ["attribute text", "<a title=\"href='/data/notes.md'\" href='notes.md'>Notes</a>", false],
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
  ["home runtime", "`~/.tycho/logs/`", false],
  ["API route", "`GET /projects/{key}/workspace/preview`", false],
  ["review escaped inline", "[Notes](\\/data/notes.md)\n", false],
  ["review escaped reference", "[Notes]: \\/data/notes.md\n\n[Notes]\n", false],
  ["review named HTML", "<a href=\"&sol;data/notes.md\">Notes</a>", false],
  ["escaped angle destination", "[Notes](<\\/data/notes.md>)", false],
  ["escaped scheme", "[Notes](file\\:///data/notes.md)", false],
  ["escaped drive", "[Notes](C\\:&sol;data/notes.md)", false],
  ["encoded scheme", "[Notes](file&colon;&sol;&sol;&sol;data/notes.md)", false],
  ["encoded drive", "<a href='C&colon;&bsol;data&bsol;notes.md'>Notes</a>", false],
  ["encoded leading whitespace", "<a href='&Tab;&NewLine;&sol;data/notes.md'>Notes</a>", false],
  ["remote escaped slashes", "[Remote](https:\\/\\/example.test/notes)", true],
  ["remote encoded slashes", "[Remote](https:&sol;&sol;example.test/-/home/user)", true],
  ["remote encoded HTML", "<a href='https&colon;&sol;&sol;example.test/#/Users/alice'>Notes</a>", true],
  ["relative escaped punctuation", "[Notes](docs/notes\\!.md)", true],
  ["relative encoded punctuation", "<img src='images/notes&excl;.png'>", true],
  ["escaped ampersand", "[Notes](\\&sol;data/notes.md)", true],
  ["nested Markdown reference", "[Notes](&amp;sol;data/notes.md)", true],
  ["nested HTML reference", "<a href='&amp;sol;data/notes.md'>Notes</a>", true],
  ["HTML backslash is decoded", "<a href='\\/data/notes.md'>Notes</a>", false],
  ["HTML decimal without semicolon", "<img src='&#47data/notes.png'>", false],
  ["HTML hex without semicolon", "<img src='&#x2fnotes.png'>", false],
  ["review quoted reference", "> [Notes]: /data/notes.md\n>\n> [Notes]\n", false],
  ["quote token", "> Notes: /Users/alice/notes.md", false],
  ["nested list token", "- Parent\n  - Notes: /private/notes.md", false],
  ["table cell token", "| Notes | /var/folders/notes.md |", false],
  ["reference token", "[Notes]: /home/alice/notes.md", false],
  ["HTML home token", "<a href='~/notes.md'>Notes</a>", false],
  ["plain home token", "Notes: ~/notes.md", false],
  ["plain file token", "Notes: file:///data/notes.md", false],
  ["unlisted root", "Notes: /arbitrary-root/notes.md", false],
  ["relative dot path", "[Notes](./docs/notes.md)", true],
  ["relative parent path", "[Notes](../../../docs/notes.md)", true],
  ["quoted relative path", "> [Notes]: ../docs/notes.md", true],
  ["inline code token", "Notes: `/Users/alice/notes.md`", false],
  ["inline home token", "Notes: `~/notes.md`", false],
  ["inline code links", "Notes: `<a href='/data/notes.md'>Notes</a>`", false],
  ["unmarked fenced code", "```sh\ncat /Users/alice/notes.md\n```", false],
  ["quoted fenced code", "> ```sh\n> cat /Users/alice/notes.md\n> ```", false],
  ["nested list fenced code", "- Parent\n  - ```sh\n    cat /Users/alice/notes.md\n    ```", false],
  ["long inline code", "Notes: ``/Users/alice/notes`here``", false],
  ["multiline inline code", "Notes: `cat\n /Users/alice/notes.md`", false],
  ["unclosed inline code", "Notes: `cat /Users/alice/notes.md", false],
  ["code followed by path", "`/Users/alice/code.md` /home/alice/notes.md", false],
  ["quoted fence boundary", "> ```sh\n> cat /Users/alice/notes.md\n> ```\n> /home/alice/notes.md", false],
  ["remote parentheses", "[Remote](https://example.test/a(b)/home/alice)", true],
  ["URL next to local link", "[Remote](https://example.test/notes)[Notes](/data/notes.md)", false],
  ["table URL next to local", "| https://example.test/#/home/alice | /data/notes.md |", false],
  ["review quoted code end", "> ```sh\n> cat notes\n\n[Notes](/data/notes.md)\n", false],
  ["review listed code end", "- ```sh\n  cat notes\n\n[Notes](/data/notes.md)\n", false],
  ["path placeholder", "Notes: /path/to/workspace/notes.md", false],
  ["home placeholder", "Notes: <home>/.tycho/logs/agents/<key>/run.log", false],
  ["inline placeholder", "Notes: `/path/to/workspace/notes.md`", false],
  ["fenced placeholder", "```sh\ncat /path/to/workspace/notes.md\n```", false],
  ["placeholder followed by local", "<home>/.tycho /Users/alice/notes.md", false],
  ["path placeholder followed by local", "/path/to/workspace /Users/alice/notes.md", false],
  ["similar prefix is real", "/path/together/notes.md", false],
  ["marker allows literal", "/Users/alice/notes.md <!-- local-path-ok -->", true],
  ["marker allows code literal", "`/Users/alice/notes.md` <!-- local-path-ok -->", true],
  ["marker allows route", "`GET /projects/{key}/workspace/preview` <!-- local-path-ok -->", true],
  ["marker trailing spaces", "/Users/alice/notes.md <!-- local-path-ok --> \t\r\n", true],
  ["marker is line scoped", "Example <!-- local-path-ok -->\n/Users/alice/notes.md", false],
  ["marker must end line", "/Users/alice/notes.md <!-- local-path-ok --> More text", false],
  ["marker in code is not end marker", "`/Users/alice/notes.md <!-- local-path-ok -->`", false],
  ["encoded marker is not approval", "/Users/alice/notes.md &lt;!-- local-path-ok --&gt;", false],
  ["old marker is not approval", "/Users/alice/notes.md <!-- local-path-example: Sample. -->", false],
  ["marked fence does not exempt body", "```sh <!-- local-path-ok -->\ncat /Users/alice/notes.md\n```", false]
]

%w[&sol; &#47; &#x2f; &#X2F;].each do |slash|
  cases << ["named/numeric inline #{slash}", "[Notes](#{slash}data/notes.md)", false]
  cases << ["named/numeric reference #{slash}", "[Notes]: #{slash}data/notes.md\n\n[Notes]", false]
  cases << ["named/numeric href #{slash}", "<a href='#{slash}data/notes.md'>Notes</a>", false]
  cases << ["named/numeric src #{slash}", "<img src=#{slash}data/notes.png>", false]
end

cases << ["review comma list", "Paths: <home>/.tycho,/Users/alice/project", false]
cases << ["review semicolon list", "Paths: <home>/.tycho;/Users/alice/project", false]
cases << ["review colon list", "Paths: <home>/.tycho:/Users/alice/project", false]
cases << ["relative placeholder", "Paths: HOME/.tycho, path/to/workspace", true]
cases.each do |name, input, allowed|
  actual = MarkdownPaths.invalid_lines(input)
  raise "#{name}: expected allowed=#{allowed}, got #{actual.inspect}" unless actual.empty? == allowed
end
["review quoted code end", "review listed code end"].each do |name|
  input = cases.find { |item| item[0] == name }[1]
  raise "#{name}: expected line 4" unless MarkdownPaths.invalid_lines(input) == [4]
end
raise "expected attribute line number" unless MarkdownPaths.invalid_lines("<a\n href='/data/notes.md'>Notes</a>\n") == [2]
raise "do not unescape entity output" unless MarkdownPaths.decode_text("&#92;/data") == "\\/data"
raise "preserve escaped ampersands" unless MarkdownPaths.decode_text("\\&sol;data") == "&sol;data"
raise "unknown named references stay literal" unless MarkdownPaths.decode_text("&unknown;") == "&unknown;"
raise "decode legacy attribute references" unless MarkdownPaths.decode_text("&amp!") == "&!"
raise "retain ambiguous attribute references" unless MarkdownPaths.decode_text("&amp=1") == "&amp=1"

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

  cases.select { |name, _input, _allowed| name.start_with?("review ") }.each do |name, input, _allowed|
    File.write(path, input)
    raise "#{name}: tracked reproduction must fail" if MarkdownPaths.check(root).empty?
  end
end

puts "markdown_paths_test: ok (#{cases.length} content cases and tracked-file checks)"
