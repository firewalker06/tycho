# frozen_string_literal: true

require "base64"
require "digest"
require "fileutils"
require "securerandom"
require "time"

require_relative "constants"
require_relative "attachment_normalizer"

module HQ
  class AgentAttachmentStore
    MAX_ATTACHMENTS_PER_MESSAGE = 5
    MAX_ATTACHMENT_BYTES = 20 * 1024 * 1024
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

    def import_remote_uploads!(uploads, created_at: Time.now, dedupe_key: nil)
      items = Array(uploads)
      return [] if items.empty?
      unless items.all? { |item| item.is_a?(Hash) }
        raise ArgumentError, "Attachments must be objects"
      end

      if items.length > MAX_ATTACHMENTS_PER_MESSAGE
        raise ArgumentError, "At most #{MAX_ATTACHMENTS_PER_MESSAGE} attachments can be sent at once"
      end

      total_bytes = 0
      prepared = items.each_with_index.map do |attrs, index|
        upload = prepare_remote_upload!(attrs, created_at:, index:, dedupe_key:)
        total_bytes += upload.fetch(:attachment).fetch("size_bytes")
        if total_bytes > MAX_TOTAL_BYTES
          raise ArgumentError, "Attachments are larger than #{human_bytes(MAX_TOTAL_BYTES)} total"
        end
        upload
      end

      written = []
      prepared.each do |upload|
        written << upload.fetch(:attachment)
        write_upload!(upload)
      end
      prepared.map { |upload| upload.fetch(:attachment) }
    rescue StandardError
      remove_remote_uploads!(written) if defined?(written)
      raise
    end

    def remove_remote_uploads!(attachments)
      asset_root = File.expand_path(File.join(AGENT_LOGS_DIR, "assets", @agent.key.to_s))
      Array(attachments).each do |attachment|
        next unless attachment.is_a?(Hash) && attachment["source"] == "remote_upload"

        path = File.expand_path(attachment["path"].to_s)
        next unless path.start_with?("#{asset_root}#{File::SEPARATOR}")

        FileUtils.rm_f(path)
        remove_empty_directory(File.dirname(path), stop_at: File.dirname(asset_root))
      end
    end

    private

    def prepare_remote_upload!(attrs, created_at:, index:, dedupe_key: nil)
      filename = AttachmentNormalizer.safe_filename(attrs["filename"] || attrs["name"] || "attachment")
      title = attrs["title"].to_s.strip
      title = filename if title.empty?
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
      id = attachment_id(created_at, index, dedupe_key:, bytes:, filename:, content_type:)
      path = File.join(asset_dir(id), "original#{extension}")

      attachment = {
        "id" => id,
        "type" => "file",
        "kind" => legacy_file_kind(attrs["kind"], filename, normalized_type),
        "title" => title,
        "filename" => filename,
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

    def remove_empty_directory(path, stop_at:)
      current = File.expand_path(path)
      while current.start_with?("#{stop_at}#{File::SEPARATOR}") && File.directory?(current) && Dir.empty?(current)
        Dir.rmdir(current)
        current = File.dirname(current)
      end
    rescue Errno::ENOENT, Errno::ENOTEMPTY
      nil
    end

    def decode_content(value, filename)
      text = value.to_s
      text = text.split(",", 2).last if text.start_with?("data:")
      raise ArgumentError, "#{filename} has no file content" if text.strip.empty?

      Base64.strict_decode64(text)
    rescue ArgumentError
      raise ArgumentError, "#{filename} is not valid base64"
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

    def attachment_id(created_at, index, dedupe_key: nil, bytes: nil, filename: nil, content_type: nil)
      unless dedupe_key.to_s.empty?
        digest = Digest::SHA256.hexdigest(
          [dedupe_key, index, filename, content_type, Digest::SHA256.hexdigest(bytes.to_s)].join("\0")
        )
        return "att_#{digest[0, 32]}"
      end

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
