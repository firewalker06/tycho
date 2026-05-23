# frozen_string_literal: true

require "base64"
require "fileutils"
require "securerandom"
require "time"

require_relative "constants"

module HQ
  class AgentAttachmentStore
    MAX_ATTACHMENTS_PER_MESSAGE = 5
    MAX_ATTACHMENT_BYTES = 10 * 1024 * 1024
    MAX_TOTAL_BYTES = 25 * 1024 * 1024

    IMAGE_CONTENT_TYPES = {
      ".gif" => "image/gif",
      ".heic" => "image/heic",
      ".jpeg" => "image/jpeg",
      ".jpg" => "image/jpeg",
      ".png" => "image/png",
      ".svg" => "image/svg+xml",
      ".webp" => "image/webp"
    }.freeze

    DOCUMENT_CONTENT_TYPES = {
      ".doc" => "application/msword",
      ".docx" => "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
      ".json" => "application/json",
      ".jsonl" => "application/x-ndjson",
      ".md" => "text/markdown",
      ".markdown" => "text/markdown",
      ".pdf" => "application/pdf",
      ".rtf" => "application/rtf",
      ".txt" => "text/plain"
    }.freeze

    EXTENSION_BY_CONTENT_TYPE = {
      "application/msword" => ".doc",
      "application/pdf" => ".pdf",
      "application/rtf" => ".rtf",
      "application/vnd.openxmlformats-officedocument.wordprocessingml.document" => ".docx",
      "application/json" => ".json",
      "application/x-ndjson" => ".jsonl",
      "audio/aac" => ".aac",
      "audio/mp4" => ".m4a",
      "audio/mpeg" => ".mp3",
      "audio/ogg" => ".ogg",
      "audio/wav" => ".wav",
      "image/gif" => ".gif",
      "image/heic" => ".heic",
      "image/jpeg" => ".jpg",
      "image/png" => ".png",
      "image/svg+xml" => ".svg",
      "image/webp" => ".webp",
      "text/markdown" => ".md",
      "text/plain" => ".txt",
      "video/mp4" => ".mp4",
      "video/quicktime" => ".mov",
      "video/webm" => ".webm"
    }.freeze

    def initialize(agent)
      @agent = agent
    end

    def import_remote_uploads!(uploads, created_at: Time.now)
      items = Array(uploads).select { |item| item.is_a?(Hash) }
      return [] if items.empty?

      if items.length > MAX_ATTACHMENTS_PER_MESSAGE
        raise ArgumentError, "At most #{MAX_ATTACHMENTS_PER_MESSAGE} attachments can be sent at once"
      end

      total_bytes = 0
      prepared = items.each_with_index.map do |attrs, index|
        upload = prepare_remote_upload!(attrs, created_at:, index:)
        total_bytes += upload.fetch(:attachment).fetch("size_bytes")
        if total_bytes > MAX_TOTAL_BYTES
          raise ArgumentError, "Attachments are larger than #{human_bytes(MAX_TOTAL_BYTES)} total"
        end
        upload
      end

      prepared.each { |upload| write_upload!(upload) }
      prepared.map { |upload| upload.fetch(:attachment) }
    end

    private

    def prepare_remote_upload!(attrs, created_at:, index:)
      filename = safe_filename(attrs["filename"] || attrs["name"] || "attachment")
      content_type = attrs["mime_type"].to_s.strip
      content_type = attrs["content_type"].to_s.strip if content_type.empty?
      declared_type = attrs["type"].to_s.strip
      content_type = declared_type unless !content_type.empty? || %w[file link].include?(declared_type.downcase)
      bytes = decode_content(attrs["content_base64"] || attrs["base64"] || attrs["content"], filename)
      if bytes.bytesize > MAX_ATTACHMENT_BYTES
        raise ArgumentError, "#{filename} is larger than #{human_bytes(MAX_ATTACHMENT_BYTES)}"
      end

      extension = attachment_extension(filename, content_type)
      normalized_type = attachment_content_type(extension, content_type)
      id = attachment_id(created_at, index)
      path = File.join(asset_dir(id), "original#{extension}")

      attachment = {
        "id" => id,
        "type" => "file",
        "kind" => legacy_file_kind(attrs["kind"], filename, normalized_type),
        "title" => filename,
        "path" => path,
        "mime_type" => normalized_type,
        "size_bytes" => bytes.bytesize,
        "source" => "remote_upload",
        "created_at" => created_at.iso8601
      }
      { attachment:, bytes: }
    end

    def write_upload!(upload)
      attachment = upload.fetch(:attachment)
      path = attachment.fetch("path")
      FileUtils.mkdir_p(File.dirname(path))
      File.binwrite(path, upload.fetch(:bytes))
    end

    def decode_content(value, filename)
      text = value.to_s
      text = text.split(",", 2).last if text.start_with?("data:")
      raise ArgumentError, "#{filename} has no file content" if text.strip.empty?

      Base64.strict_decode64(text)
    rescue ArgumentError
      raise ArgumentError, "#{filename} is not valid base64"
    end

    def safe_filename(value)
      basename = File.basename(value.to_s.tr("\\", "/")).strip
      basename = "attachment" if basename.empty? || basename == "." || basename == ".."
      basename.gsub(/[^A-Za-z0-9._ -]/, "_")[0, 120]
    end

    def legacy_file_kind(value, filename, content_type)
      declared = value.to_s.strip.downcase.tr("-", "_")
      return "image" if declared == "image"
      return "document" if %w[document doc file text markdown md pdf].include?(declared)
      return "image" if content_type.start_with?("image/")

      extension = File.extname(filename).downcase
      return "image" if IMAGE_CONTENT_TYPES.key?(extension)

      "document"
    end

    def attachment_extension(filename, content_type)
      extension = File.extname(filename).downcase
      return extension if extension.match?(/\A\.[A-Za-z0-9]{1,12}\z/)

      inferred = EXTENSION_BY_CONTENT_TYPE[content_type.downcase]
      return inferred if inferred

      ".bin"
    end

    def attachment_content_type(extension, content_type)
      known = IMAGE_CONTENT_TYPES[extension] || DOCUMENT_CONTENT_TYPES[extension]
      return known if known

      content_type.to_s.empty? ? "application/octet-stream" : content_type
    end

    def attachment_id(created_at, index)
      stamp = created_at.utc.strftime("%Y%m%d%H%M%S")
      "att_#{stamp}_#{index + 1}_#{SecureRandom.hex(5)}"
    end

    def asset_dir(id)
      File.expand_path(File.join(AGENT_LOGS_DIR, "assets", @agent.key.to_s, id))
    end

    def human_bytes(bytes)
      "#{(bytes.to_f / (1024 * 1024)).round} MB"
    end
  end
end
