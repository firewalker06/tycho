# frozen_string_literal: true

require "cgi"
require "json"
require "open3"

module MarkdownPaths
  LOCAL_PATH = %r{(?<![\w.~\\/\}])(?:~/|/(?!/)(?:[A-Za-z0-9._~-]+/|[A-Za-z0-9._~-]*\.[A-Za-z0-9])|file://|[A-Za-z]:[\\/])}i
  URL = /\b([a-z][a-z0-9+.-]*):(?:[^\s<>"'`|()\[\]]|\([^()\s]*\)|\[[^\]\s]*\])+/i
  INLINE_CODE = /(?<![\\`])(`+)(?!`)(.*?)\1(?!`)/m
  # HTML5 named references from Python's html.entities.html5, which follows
  # https://html.spec.whatwg.org/multipage/named-characters.html
  NAMED_ENTITIES = JSON.parse(File.read(File.join(__dir__, "html_named_entities.json"))).freeze
  ENCODING = /\\[\x21-\x2f\x3a-\x40\x5b-\x60\x7b-\x7e]|&(?:#[xX][0-9a-fA-F]+;?|#[0-9]+;?|[A-Za-z][A-Za-z0-9]*;?)/

  module_function

  def decode_text(text)
    # One pass preserves escaped ampersands and never decodes generated output.
    text.gsub(ENCODING) do |encoded|
      if encoded.start_with?("\\")
        encoded[1..]
      elsif encoded.start_with?("&#")
        CGI.unescapeHTML(encoded.end_with?(";") ? encoded : "#{encoded};")
      elsif !encoded.end_with?(";") && text[Regexp.last_match.end(0)].to_s.match?(/[=A-Za-z0-9]/)
        encoded
      else
        NAMED_ENTITIES.fetch(encoded.delete_prefix("&"), encoded)
      end
    end
  end

  def without_code(source)
    fence = nil
    text = source.lines.map do |line|
      # Container prefixes do not affect the scan or code-fence detection.
      content = line.sub(/\A(?:[ \t]+|>[ \t]?|[-+*][ \t]+|\d+[.)][ \t]+)*/, "")
      delimiter = content[/\A(`{3,}|~{3,})/, 1]
      if fence
        fence = nil if content.match?(/\A#{Regexp.escape(fence[0])}{#{fence.length},}[ \t]*(?:\r?\n)?\z/)
        line.gsub(/[^\n]/, " ")
      elsif delimiter
        fence = delimiter
        line.gsub(/[^\n]/, " ")
      else
        line
      end
    end.join
    text.gsub(INLINE_CODE) { |code| code.gsub(/[^\n]/, " ") }
  end

  def invalid_lines(source)
    without_code(source).lines.each_with_index.filter_map do |line, index|
      text = decode_text(line).gsub(URL) do |url|
        scheme = Regexp.last_match(1)
        scheme.casecmp?("file") || scheme.length == 1 ? url : " "
      end
      index + 1 if text.match?(LOCAL_PATH)
    end
  end

  def check(root)
    files, status = Open3.capture2("git", "ls-files", "-z", chdir: root)
    raise "Cannot list tracked Markdown files" unless status.success?

    files.split("\0").select { |path| path.downcase.end_with?(".md") }.flat_map do |path|
      source = File.read(File.join(root, path))
      lines = source.lines
      invalid_lines(source).map { |number| "#{path}:#{number}: #{lines[number - 1].strip}" }
    end
  end
end
