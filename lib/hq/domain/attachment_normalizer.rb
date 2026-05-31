# frozen_string_literal: true

require "uri"

module HQ
  class AttachmentNormalizer
    PATH_KEYS = %w[path file file_path filePath filepath absolute_path absolutePath].freeze
    URL_KEYS = %w[url href].freeze

    MIME_TYPES = {
      ".aac" => "audio/aac",
      ".avif" => "image/avif",
      ".csv" => "text/csv",
      ".doc" => "application/msword",
      ".docx" => "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
      ".gif" => "image/gif",
      ".heic" => "image/heic",
      ".jpeg" => "image/jpeg",
      ".jpg" => "image/jpeg",
      ".json" => "application/json",
      ".jsonl" => "application/x-ndjson",
      ".m4a" => "audio/mp4",
      ".markdown" => "text/markdown",
      ".md" => "text/markdown",
      ".mov" => "video/quicktime",
      ".mp3" => "audio/mpeg",
      ".mp4" => "video/mp4",
      ".ogg" => "audio/ogg",
      ".pdf" => "application/pdf",
      ".png" => "image/png",
      ".rtf" => "application/rtf",
      ".svg" => "image/svg+xml",
      ".tsv" => "text/tab-separated-values",
      ".txt" => "text/plain",
      ".wav" => "audio/wav",
      ".webm" => "video/webm",
      ".webp" => "image/webp"
    }.freeze

    class << self
      def normalize(value, workspace: nil, require_existing_file: true)
        items = value.is_a?(Array) ? value : [value]
        dedupe(items.filter_map do |item|
          normalize_one(item, workspace:, require_existing_file:)
        end)
      end

      def normalize_one(value, workspace: nil, require_existing_file: true)
        if value.is_a?(String)
          return normalize_string(value, workspace:, require_existing_file:)
        end
        return nil unless value.is_a?(Hash)

        title = first_present(value, %w[title label name])
        path = first_present(value, PATH_KEYS)
        url = first_present(value, URL_KEYS)

        if path.empty? && file_uri?(url)
          path = url
          url = ""
        end

        title_is_target = false
        if path.empty? && url.empty? && attachment_target?(title)
          title_is_target = true
          if http_url?(title)
            url = title
          else
            path = title
          end
        end

        type = attachment_type(value["type"], value["kind"], path:, url:)
        type == "link" ? normalize_link(value, title, url) : normalize_file(value, title, path, url, title_is_target:, workspace:, require_existing_file:)
      end

      def file_attachment?(attachment)
        return false unless attachment.is_a?(Hash)

        attachment_type(attachment["type"], attachment["kind"],
                        path: attachment["path"], url: attachment["url"]) == "file"
      end

      def link_attachment?(attachment)
        return false unless attachment.is_a?(Hash)

        attachment_type(attachment["type"], attachment["kind"],
                        path: attachment["path"], url: attachment["url"]) == "link"
      end

      def attachment_target(attachment)
        return "" unless attachment.is_a?(Hash)

        if link_attachment?(attachment)
          attachment["url"].to_s.strip
        else
          path = attachment["path"].to_s.strip
          path.empty? ? attachment["url"].to_s.strip : path
        end
      end

      def image_file?(attachment)
        return false unless file_attachment?(attachment)

        mime = attachment["mime_type"].to_s.downcase
        return true if mime.start_with?("image/")

        image_path?(attachment["path"].to_s)
      end

      def mime_type_for_path(path)
        MIME_TYPES[File.extname(path.to_s).downcase] || "application/octet-stream"
      end

      private

      def normalize_string(value, workspace:, require_existing_file:)
        text = value.to_s.strip
        return nil if text.empty?

        if http_url?(text)
          normalize_link({}, "", text)
        else
          normalize_file({}, "", text, "", title_is_target: true, workspace:, require_existing_file:)
        end
      end

      def normalize_link(value, title, url)
        target = normalize_http_url(url)
        return nil if target.empty?

        result = {
          "type" => "link",
          "kind" => "link",
          "title" => display_title(title, target, title_is_target: title.to_s.strip == target),
          "url" => target
        }
        description = value["description"].to_s.strip
        result["description"] = description unless description.empty?
        copy_metadata!(result, value)
        result
      end

      def normalize_file(value, title, path, url, title_is_target:, workspace:, require_existing_file:)
        target = path.to_s.strip
        target = url.to_s.strip if target.empty? && !http_url?(url)
        target = resolved_file_uri_path(target) if file_uri?(target)
        target = expand_path(target, workspace)
        return nil if target.empty?
        return nil if require_existing_file && !File.file?(target)

        mime_type = value["mime_type"].to_s.strip
        mime_type = value["content_type"].to_s.strip if mime_type.empty?
        mime_type = mime_type_for_path(target) if mime_type.empty?
        result = {
          "type" => "file",
          "kind" => legacy_file_kind(value["kind"], target, mime_type),
          "title" => display_title(title, target, title_is_target:),
          "path" => target,
          "mime_type" => mime_type
        }
        description = value["description"].to_s.strip
        result["description"] = description unless description.empty?
        size = value["size_bytes"]
        result["size_bytes"] = size if size && !size.to_s.empty?
        result["size_bytes"] ||= File.size(target) if File.file?(target)
        copy_metadata!(result, value)
        result
      rescue SystemCallError
        nil
      end

      def copy_metadata!(result, value)
        %w[id source created_at].each do |key|
          result[key] = value[key] if value.key?(key) && !value[key].to_s.empty?
        end
      end

      def attachment_type(type, kind, path:, url:)
        declared = type.to_s.strip.downcase.tr("-", "_")
        return declared if %w[file link].include?(declared)

        legacy = kind.to_s.strip.downcase.tr("-", "_")
        return "link" if %w[link url pr pull_request github webpage website].include?(legacy)
        return "file" if %w[document doc markdown md text note image photo picture screenshot file audio video].include?(legacy)
        return "file" if !path.to_s.strip.empty? || file_uri?(url)
        return "link" if http_url?(url)

        "file"
      end

      def legacy_file_kind(kind, path, mime_type)
        declared = kind.to_s.strip.downcase.tr("-", "_")
        return declared if %w[document image].include?(declared)
        return "image" if mime_type.to_s.downcase.start_with?("image/") || image_path?(path)

        "document"
      end

      def first_present(hash, keys)
        keys.each do |key|
          value = hash[key].to_s.strip
          return value unless value.empty?
        end
        ""
      end

      def display_title(title, target, title_is_target:)
        value = title.to_s.strip
        value = "" if title_is_target
        return value unless value.empty?

        basename = File.basename(target.to_s.sub(%r{\Ahttps?://[^/]+/?}i, ""))
        basename.empty? || basename == "." ? target.to_s : basename
      end

      def attachment_target?(value)
        text = value.to_s.strip
        return false if text.empty?
        return true if http_url?(text) || file_uri?(text)
        return true if text.match?(%r{\A(?:~|/|\./|\.\./)})
        return true if text.include?("/")
        return true if text.match?(/\.[A-Za-z0-9]{1,8}\z/)

        false
      end

      def expand_path(value, workspace)
        path = value.to_s.strip
        return "" if path.empty?
        return "" if path.match?(/\A[a-z][a-z0-9+.-]*:/i)

        base = workspace.to_s.empty? ? Dir.pwd : workspace.to_s
        path.start_with?("~") ? File.expand_path(path) : File.expand_path(path, base)
      end

      def normalize_http_url(value)
        text = value.to_s.strip
        return "" unless http_url?(text)

        uri = URI.parse(text)
        return "" if uri.host.to_s.empty?

        uri.to_s
      rescue URI::InvalidURIError
        ""
      end

      def http_url?(value)
        value.to_s.match?(%r{\Ahttps?://}i)
      end

      def file_uri?(value)
        value.to_s.match?(/\Afile:/i)
      end

      def resolved_file_uri_path(value)
        uri = URI.parse(value.to_s)
        return "" unless uri.scheme.to_s.downcase == "file"
        return "" unless uri.host.to_s.empty? || uri.host == "localhost"

        path = uri.path.to_s
        return "" if path.empty?

        File.expand_path(URI::DEFAULT_PARSER.unescape(path))
      rescue URI::InvalidURIError
        ""
      end

      def image_path?(path)
        path.to_s.downcase.match?(/\.(avif|gif|heic|jpe?g|png|svg|webp)\z/)
      end

      def dedupe(attachments)
        seen = {}
        deduped = []
        attachments.each do |attachment|
          key = [
            attachment["type"],
            attachment["type"] == "link" ? attachment["url"] : attachment["path"]
          ]
          next if seen[key]

          seen[key] = true
          deduped << attachment
        end
        deduped
      end
    end
  end
end
