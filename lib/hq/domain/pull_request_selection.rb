# frozen_string_literal: true

require "json"

module HQ
  # Validates path/index based diff selections against one immutable snapshot and
  # renders the only prompt representation sent to an agent.
  class PullRequestSelection
    MAX_ITEMS = 100
    MAX_LINES = 250
    MAX_BYTES = 12 * 1024
    OPEN = "[TYCHO_PR_DIFF_CONTEXT]"
    CLOSE = "[/TYCHO_PR_DIFF_CONTEXT]"

    class Error < StandardError; end

    class << self
      def normalize(snapshot, selection)
        selection = stringify(selection)
        snapshot_id = selection["snapshot_id"].to_s
        raise Error, "A pull request snapshot is required." if snapshot_id.empty?
        raise Error, "The pull request changed. Refresh and select lines again." unless snapshot_id == snapshot["snapshot_id"].to_s

        requested = Array(selection["lines"])
        raise Error, "Select at most #{MAX_ITEMS} diff lines." if requested.length > MAX_ITEMS

        lookup = snapshot_lines(snapshot)
        seen = {}
        requested.each_with_object([]) do |raw, result|
          item = stringify(raw)
          key = key_for(item)
          raise Error, "Each selected line needs a path, hunk index, and line index." if key.nil?
          next if seen[key]

          line = lookup[key]
          raise Error, "A selected diff line is no longer available in this snapshot." unless line
          seen[key] = true
          result << line
        end.sort_by { |line| [line.fetch("file_index"), line.fetch("hunk_index"), line.fetch("line_index")] }
      end

      def render(snapshot, selection)
        lines = normalize(snapshot, selection)
        raise Error, "Select at least one diff line to attach." if lines.empty?

        selected = []
        omitted = 0
        bytes = 0
        lines.first(MAX_LINES).each do |line|
          payload = line.slice("path", "old_path", "side", "kind", "old_number", "new_number", "content")
          payload["content"] = safe_text(payload["content"])
          encoded = JSON.generate(payload)
          if bytes + encoded.bytesize > MAX_BYTES
            omitted += 1
          else
            selected << payload
            bytes += encoded.bytesize
          end
        end
        omitted += lines.length - MAX_LINES if lines.length > MAX_LINES

        identity = {
          "url" => PullRequestDiff.canonical_url(snapshot.fetch("repository"), snapshot.fetch("number")),
          "repository" => snapshot["repository"], "number" => snapshot["number"],
          "snapshot_id" => snapshot["snapshot_id"], "base_sha" => snapshot["base_sha"], "head_sha" => snapshot["head_sha"]
        }.compact
        body = { "identity" => identity, "lines" => selected }
        body["omitted_lines"] = omitted if omitted.positive?
        body["snapshot_truncated"] = true if snapshot["truncated"]
        [OPEN, JSON.generate(body), CLOSE].join("\n")
      end

      private

      def snapshot_lines(snapshot)
        Array(snapshot["files"]).each_with_index.each_with_object({}) do |(file, file_index), lookup|
          next if file["binary"] || file[:binary]
          path = (file["path"] || file[:path] || file["old_path"] || file[:old_path]).to_s
          Array(file["hunks"] || file[:hunks]).each_with_index do |hunk, hunk_index|
            Array(hunk["lines"] || hunk[:lines]).each_with_index do |line, line_index|
              kind = line["kind"] || line[:kind]
              next unless %w[added removed context].include?(kind)
              entry = {
                "path" => path, "old_path" => file["old_path"] || file[:old_path], "kind" => kind,
                "old_number" => line["old_number"] || line[:old_number], "new_number" => line["new_number"] || line[:new_number],
                "content" => line["content"] || line[:content], "side" => side_for(kind), "file_index" => file_index, "hunk_index" => hunk_index, "line_index" => line_index
              }.compact
              lookup[key_for(entry)] = entry
            end
          end
        end
      end

      def key_for(item)
        path = item["path"].to_s
        hunk = Integer(item["hunk_index"], exception: false)
        line = Integer(item["line_index"], exception: false)
        return nil if path.empty? || hunk.nil? || line.nil?
        [path, hunk, line].join("\0")
      end

      def safe_text(value)
        value.to_s.encode("UTF-8", invalid: :replace, undef: :replace, replace: "�")
          .gsub(/[\u0000-\u001f\u007f]/, " ").gsub(OPEN, escaped_delimiter(OPEN))
          .gsub(CLOSE, escaped_delimiter(CLOSE))
      end

      def escaped_delimiter(value)
        value.tr("[]", "［］")
      end

      def side_for(kind)
        return "left" if kind == "removed"
        return "right" if kind == "added"

        "both"
      end

      def stringify(value)
        case value
        when Hash then value.to_h { |key, item| [key.to_s, stringify(item)] }
        when Array then value.map { |item| stringify(item) }
        else value
        end
      end
    end
  end
end
