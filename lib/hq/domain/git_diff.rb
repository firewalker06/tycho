# frozen_string_literal: true

require "open3"
require "time"
require "timeout"

module HQ
  class GitDiff
    DEFAULT_SCOPE = "worktree"
    SCOPES = %w[worktree staged all].freeze
    COMMAND_TIMEOUT = 5
    MAX_DIFF_BYTES = 512 * 1024
    MAX_UNTRACKED_BYTES = 64 * 1024

    def self.parse_patch_text(output)
      new(Dir.pwd).send(:parse_patch, output)
    end

    class Error < StandardError
      attr_reader :status

      def initialize(message, status: 400)
        super(message)
        @status = status
      end
    end

    def initialize(path)
      @path = File.expand_path(path.to_s)
    end

    def status_payload(project_key: nil)
      ensure_worktree!
      status_entries = parse_status_entries(git_output("status", "--porcelain=v1", "-z"))
      {
        project_key: project_key,
        root: worktree_root,
        head: git_value("rev-parse", "--short", "HEAD"),
        branch: git_value("branch", "--show-current"),
        dirty: status_entries.any?,
        dirty_files: status_entries.length,
        files: status_entries
      }.compact
    end

    def diff_payload(scope: DEFAULT_SCOPE, project_key: nil)
      ensure_worktree!
      normalized_scope = normalize_scope(scope)
      status = status_payload(project_key:)
      output, truncated = diff_output(normalized_scope)
      files = parse_patch(output)
      files.concat(untracked_files(status.fetch(:files, []))) if %w[worktree all].include?(normalized_scope)

      {
        project_key: project_key,
        root: status[:root],
        head: status[:head],
        branch: status[:branch],
        scope: normalized_scope,
        generated_at: Time.now.iso8601,
        dirty: status[:dirty],
        dirty_files: status[:dirty_files],
        files: files,
        file_count: files.length,
        additions: files.sum { |file| file[:additions].to_i },
        deletions: files.sum { |file| file[:deletions].to_i },
        truncated: truncated
      }.compact
    end

    private

    def normalize_scope(value)
      scope = value.to_s.strip
      scope = DEFAULT_SCOPE if scope.empty?
      return scope if SCOPES.include?(scope)

      raise Error.new("Unsupported git diff scope: #{value.inspect}. Supported scopes: #{SCOPES.join(", ")}")
    end

    def ensure_worktree!
      raise Error.new("Project path is not a directory: #{@path}", status: 404) unless Dir.exist?(@path)

      inside = git_value("rev-parse", "--is-inside-work-tree")
      raise Error.new("Project path is not a Git worktree: #{@path}", status: 409) unless inside == "true"
    end

    def worktree_root
      git_value("rev-parse", "--show-toplevel")
    end

    def diff_output(scope)
      args = [
        "diff",
        "--no-color",
        "--no-ext-diff",
        "--src-prefix=a/",
        "--dst-prefix=b/",
        "--find-renames",
        "--patch",
        "--unified=3"
      ]
      case scope
      when "staged"
        args << "--cached"
      when "all"
        args << "HEAD"
      end
      args << "--"

      output = git_output(*args)
      truncated = output.bytesize > MAX_DIFF_BYTES
      output = output.byteslice(0, MAX_DIFF_BYTES).to_s if truncated
      [output.scrub, truncated]
    end

    def git_value(*args)
      git_output(*args).strip.then { |value| value.empty? ? nil : value }
    rescue Error
      nil
    end

    def git_output(*args)
      stdout = +""
      stderr = +""
      status = nil
      command = ["git", "-C", @path, "-c", "core.quotepath=false", *args]
      Timeout.timeout(COMMAND_TIMEOUT) do
        stdout, stderr, status = Open3.capture3(
          { "GIT_PAGER" => "cat", "GIT_EXTERNAL_DIFF" => "" },
          *command
        )
      end
      raise Error.new(stderr.to_s.strip.empty? ? "Git command failed" : stderr.to_s.strip, status: 409) unless status.success?

      stdout.to_s
    rescue Timeout::Error
      raise Error.new("Git command timed out", status: 409)
    rescue SystemCallError => e
      raise Error.new(e.message, status: 409)
    end

    def parse_status_entries(output)
      fields = output.to_s.split("\0")
      entries = []
      index = 0
      while index < fields.length
        field = fields[index].to_s
        index += 1
        next if field.empty?

        code = field[0, 2].to_s
        path = field[3..].to_s
        old_path = nil
        if code.include?("R") || code.include?("C")
          old_path = fields[index].to_s
          index += 1
        end
        entries << {
          path: path,
          old_path: empty_to_nil(old_path),
          index_status: code[0],
          worktree_status: code[1],
          status: status_label(code)
        }.compact
      end
      entries
    end

    def status_label(code)
      return "untracked" if code == "??"
      return "renamed" if code.include?("R")
      return "copied" if code.include?("C")
      return "added" if code.include?("A")
      return "deleted" if code.include?("D")
      return "modified" if code.include?("M")
      return "conflicted" if code.match?(/[U]/)

      "changed"
    end

    def parse_patch(output)
      files = []
      current_file = nil
      current_hunk = nil
      old_line = nil
      new_line = nil

      output.to_s.each_line(chomp: true) do |line|
        if line.start_with?("diff --git ")
          current_file = new_file_entry
          files << current_file
          current_hunk = nil
          old_line = nil
          new_line = nil
          next
        end
        next unless current_file

        case line
        when /\Anew file mode /
          current_file[:status] = "added"
        when /\Adeleted file mode /
          current_file[:status] = "deleted"
        when /\Arename from (.+)\z/
          current_file[:status] = "renamed"
          current_file[:old_path] = unquote_path(Regexp.last_match(1))
        when /\Arename to (.+)\z/
          current_file[:status] = "renamed"
          current_file[:path] = unquote_path(Regexp.last_match(1))
        when /\A--- (.+)\z/
          current_file[:old_path] = diff_path(Regexp.last_match(1), "a/")
          current_file[:status] = "deleted" if Regexp.last_match(1) == "/dev/null"
        when /\A\+\+\+ (.+)\z/
          current_file[:path] = diff_path(Regexp.last_match(1), "b/")
          current_file[:status] = "added" if current_file[:old_path].nil?
        when /\ABinary files /
          current_file[:binary] = true
        when /\AGIT binary patch\z/
          current_file[:binary] = true
        when /\A@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@(.*)\z/
          old_line = Regexp.last_match(1).to_i
          new_line = Regexp.last_match(3).to_i
          current_hunk = {
            header: line,
            old_start: old_line,
            old_lines: (Regexp.last_match(2) || "1").to_i,
            new_start: new_line,
            new_lines: (Regexp.last_match(4) || "1").to_i,
            section: empty_to_nil(Regexp.last_match(5).to_s.strip),
            lines: []
          }.compact
          current_file[:hunks] << current_hunk
        else
          next unless current_hunk

          parsed = parse_hunk_line(line, old_line, new_line)
          current_hunk[:lines] << parsed.fetch(:line)
          current_file[:additions] += 1 if parsed.fetch(:line)[:kind] == "added"
          current_file[:deletions] += 1 if parsed.fetch(:line)[:kind] == "removed"
          old_line = parsed.fetch(:old_line)
          new_line = parsed.fetch(:new_line)
        end
      end

      files.each do |file|
        file[:path] ||= file[:old_path]
        file[:old_path] = nil if file[:old_path] == file[:path]
      end
      files
    end

    def new_file_entry
      {
        path: nil,
        old_path: nil,
        status: "modified",
        binary: false,
        additions: 0,
        deletions: 0,
        hunks: []
      }
    end

    def parse_hunk_line(line, old_line, new_line)
      case line[0]
      when "+"
        parsed_line = {
          kind: "added",
          old_number: nil,
          new_number: new_line,
          content: line[1..].to_s
        }
        new_line += 1
      when "-"
        parsed_line = {
          kind: "removed",
          old_number: old_line,
          new_number: nil,
          content: line[1..].to_s
        }
        old_line += 1
      when " "
        parsed_line = {
          kind: "context",
          old_number: old_line,
          new_number: new_line,
          content: line[1..].to_s
        }
        old_line += 1
        new_line += 1
      else
        parsed_line = {
          kind: "meta",
          old_number: nil,
          new_number: nil,
          content: line
        }
      end

      { line: parsed_line, old_line: old_line, new_line: new_line }
    end

    def untracked_files(status_entries)
      status_entries.select { |entry| entry[:status] == "untracked" }.map { |entry| untracked_file(entry[:path]) }
    end

    def untracked_file(path)
      safe_path = safe_relative_path(path)
      full_path = File.join(worktree_root, safe_path)
      entry = {
        path: safe_path,
        old_path: nil,
        status: "untracked",
        binary: false,
        additions: 0,
        deletions: 0,
        hunks: []
      }
      unless File.file?(full_path)
        entry[:message] = "Untracked directory or special file is not expanded."
        return entry
      end

      size = File.size(full_path)
      content = File.binread(full_path, [size, MAX_UNTRACKED_BYTES].min)
      if content.include?("\0")
        entry[:binary] = true
        entry[:message] = "Untracked binary file is not expanded."
        return entry
      end

      lines = content.scrub.lines(chomp: true)
      entry[:truncated] = size > MAX_UNTRACKED_BYTES
      entry[:additions] = lines.length
      entry[:hunks] << {
        header: "@@ -0,0 +1,#{lines.length} @@",
        old_start: 0,
        old_lines: 0,
        new_start: 1,
        new_lines: lines.length,
        lines: lines.each_with_index.map do |text, index|
          {
            kind: "added",
            old_number: nil,
            new_number: index + 1,
            content: text
          }
        end
      }
      entry
    rescue SystemCallError => e
      entry[:message] = e.message
      entry
    end

    def safe_relative_path(path)
      expanded = File.expand_path(path.to_s, worktree_root)
      root = "#{worktree_root}#{File::SEPARATOR}"
      unless expanded == worktree_root || expanded.start_with?(root)
        raise Error.new("Git path escapes worktree: #{path.inspect}", status: 409)
      end

      expanded.delete_prefix(root)
    end

    def diff_path(value, prefix)
      raw = unquote_path(value)
      return nil if raw == "/dev/null"

      raw.start_with?(prefix) ? raw.delete_prefix(prefix) : raw
    end

    def unquote_path(value)
      text = value.to_s
      return text.undump if text.start_with?("\"") && text.end_with?("\"")

      text
    rescue ArgumentError
      text
    end

    def empty_to_nil(value)
      text = value.to_s
      text.empty? ? nil : text
    end
  end
end
