# frozen_string_literal: true

require "cgi"
require "json"
require "open3"

module MarkdownPaths
  LOCAL_PATH = %r{(?<![\w~\}])/(?:Users|home|tmp|absolute|opt|var|usr|etc|Volumes|private|root|mnt|srv|Applications|Library|workspace|workspaces)/|file://|\b[A-Za-z]:[\\/]}i
  URL = /\b([a-z][a-z0-9+.-]*):[^\s<>"'`]+/i
  TARGET = /\]\(\s*(?:<([^>\n]*)>|([^\s)]+))|^\s{0,3}\[[^\]\n]+\]:\s*(?:<([^>\n]*)>|([^\s]+))/
  HTML_TAG = /<[a-z][a-z0-9:-]*(?:\s+(?:[^>"']|"[^"]*"|'[^']*')*)?\s*\/?>/i
  HTML_ATTRIBUTE = /([^\s=<>"'`\/]+)(?:\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+)))?/
  # HTML5 named references from Python's html.entities.html5, which follows
  # https://html.spec.whatwg.org/multipage/named-characters.html
  NAMED_ENTITIES = JSON.parse(File.read(File.join(__dir__, "html_named_entities.json"))).freeze
  MARKDOWN_ENCODING = /\\([\x21-\x2f\x3a-\x40\x5b-\x60\x7b-\x7e])|&(?:#[xX][0-9a-fA-F]{1,6};|#[0-9]{1,7};|[A-Za-z][A-Za-z0-9]+;)/
  HTML_ENCODING = /&(?:#[xX][0-9a-fA-F]+;?|#[0-9]+;?|[A-Za-z][A-Za-z0-9]*;?)/

  module_function

  def decode_target(target, markdown:)
    # One pass preserves escaped ampersands and avoids decoding generated text
    # again. Backslashes have escape semantics only in Markdown destinations.
    target.gsub(markdown ? MARKDOWN_ENCODING : HTML_ENCODING) do |encoded|
      if markdown && encoded.start_with?("\\")
        encoded[1..]
      elsif encoded.start_with?("&#")
        CGI.unescapeHTML(encoded.end_with?(";") ? encoded : "#{encoded};")
      elsif !encoded.end_with?(";") && target[Regexp.last_match.end(0)].to_s.match?(/[=A-Za-z0-9]/)
        encoded
      else
        NAMED_ENTITIES.fetch(encoded.delete_prefix("&"), encoded)
      end
    end
  end

  def absolute_target?(target, markdown: false)
    target = decode_target(target, markdown: markdown).strip
    target.match?(%r{\A(?:/(?!/)|file:|[a-z]:[\\/])}i)
  end

  def mask_range!(source, range)
    source[range] = source[range].gsub(/[^\n]/, " ")
  end

  def invalid_lines(source)
    lines = source.lines
    invalid = []
    # Destinations get a syntax-aware check below. Hide them from the plain text
    # scan so encoded remote schemes cannot look like local paths there.
    local_source = source.dup

    # Link destinations remain checked inside marked examples. Read tags across
    # lines and consume whole attribute values so quoted text cannot add attributes.
    source.to_enum(:scan, TARGET).each do
      match = Regexp.last_match
      if absolute_target?(match.captures.compact.first, markdown: true)
        invalid << source[0...match.begin(0)].count("\n") + 1
      end
      mask_range!(local_source, match.begin(0)...match.end(0))
    end
    source.to_enum(:scan, HTML_TAG).each do
      tag = Regexp.last_match
      tag_text = tag[0]
      tag_line = source[0...tag.begin(0)].count("\n") + 1
      tag_text.to_enum(:scan, HTML_ATTRIBUTE).each do
        attribute = Regexp.last_match
        name, *values = attribute.captures
        next unless %w[href src].include?(name.downcase)
        next unless values.compact.first

        if absolute_target?(values.compact.first)
          invalid << tag_line + tag_text[0...attribute.begin(0)].count("\n")
        end
        mask_range!(local_source, (tag.begin(0) + attribute.begin(0))...(tag.begin(0) + attribute.end(0)))
      end
    end
    fence = nil
    example_block = false
    previous_example = false
    local_lines = local_source.lines
    lines.each_with_index do |line, index|
      example = line.match?(/<!-- local-path-example: .+ -->/)
      if (delimiter = line[/^\s{0,3}(`{3,}|~{3,})/, 1])
        if fence.nil?
          fence = delimiter
          example_block = previous_example
        elsif line.match?(/\A {0,3}#{Regexp.escape(fence[0])}{#{fence.length},}\s*\z/)
          fence = nil
          example_block = false
        end
      end
      # Mask complete scheme URLs, but retain file URIs and Windows drive paths.
      local_text = local_lines[index].gsub(URL) do |url|
        scheme = Regexp.last_match(1)
        scheme.casecmp?("file") || scheme.length == 1 ? url : " "
      end
      invalid << index + 1 if !example && !example_block && local_text.match?(LOCAL_PATH)
      previous_example = example
    end

    invalid.uniq.sort
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
