# frozen_string_literal: true

require "cgi"
require "open3"

module MarkdownPaths
  LOCAL_PATH = %r{(?<![\w~\}])/(?:Users|home|tmp|absolute|opt|var|usr|etc|Volumes|private|root|mnt|srv|Applications|Library|workspace|workspaces)/|file://|\b[A-Za-z]:[\\/]}i
  URL = /\b([a-z][a-z0-9+.-]*):[^\s<>"'`]+/i
  TARGET = /\]\(\s*(?:<([^>\n]*)>|([^\s)]+))|^\s{0,3}\[[^\]\n]+\]:\s*(?:<([^>\n]*)>|([^\s]+))/
  HTML_TAG = /<[a-z][a-z0-9:-]*(?:\s+(?:[^>"']|"[^"]*"|'[^']*')*)?\s*\/?>/i
  HTML_ATTRIBUTE = /([^\s=<>"'`\/]+)(?:\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'=<>`]+)))?/

  module_function

  def absolute_target?(target)
    target = CGI.unescapeHTML(target).strip
    target.match?(%r{\A(?:/(?!/)|file:|[a-z]:[\\/])}i)
  end

  def invalid_lines(source)
    lines = source.lines
    invalid = []
    fence = nil
    example_block = false
    previous_example = false
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
      local_text = line.gsub(URL) do |url|
        scheme = Regexp.last_match(1)
        scheme.casecmp?("file") || scheme.length == 1 ? url : " "
      end
      invalid << index + 1 if !example && !example_block && local_text.match?(LOCAL_PATH)
      previous_example = example
    end

    # Link destinations remain checked inside marked examples. Read tags across
    # lines and consume whole attribute values so quoted text cannot add attributes.
    source.to_enum(:scan, TARGET).each do
      match = Regexp.last_match
      next unless absolute_target?(match.captures.compact.first)

      invalid << source[0...match.begin(0)].count("\n") + 1
    end
    source.to_enum(:scan, HTML_TAG).each do
      tag = Regexp.last_match
      tag_text = tag[0]
      tag_line = source[0...tag.begin(0)].count("\n") + 1
      tag_text.to_enum(:scan, HTML_ATTRIBUTE).each do
        attribute = Regexp.last_match
        name, *values = attribute.captures
        next unless %w[href src].include?(name.downcase)
        next unless values.compact.first && absolute_target?(values.compact.first)

        invalid << tag_line + tag_text[0...attribute.begin(0)].count("\n")
      end
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
