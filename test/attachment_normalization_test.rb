# frozen_string_literal: true

require "tmpdir"
require "fileutils"
require "time"

require_relative "../lib/hq/domain/managed_agent"

module AttachmentNormalizationTest
  module_function

  def run!
    assert_file_and_link_attachments_are_normalized
    assert_duplicate_attachment_targets_are_deduped
    assert_new_attachment_records_are_prepended
    assert_legacy_kind_attachments_remain_supported
    assert_invalid_attachments_are_dropped
    puts "attachment_normalization_test: ok"
  end

  def assert_file_and_link_attachments_are_normalized
    Dir.mktmpdir("hq-attachment-normalization-test") do |dir|
      FileUtils.mkdir_p(File.join(dir, "docs"))
      File.write(File.join(dir, "docs/project-notes.md"), "# Project notes\n")
      File.write(File.join(dir, "tmp-export.jsonl"), "{}\n")
      agent = HQ::ManagedAgent.new(
        key: "attachment-normalization",
        name: "Attachment Normalization",
        project_key: "demo",
        template_key: "custom",
        workspace: dir,
        prompt: "Test attachment normalization",
        agent: "claude",
        log_path: File.join(dir, "agent.raw.log")
      )

      attachments = agent.send(
        :normalize_attachments,
        [
          {
            "type" => "file",
            "title" => "Project notes",
            "path" => "docs/project-notes.md"
          },
          {
            "type" => "link",
            "title" => "Implementation PR",
            "url" => "https://github.com/example/web/pull/123"
          },
          {
            "type" => "file",
            "title" => "file://#{File.join(dir, "tmp-export.jsonl")}",
            "path" => "file://#{File.join(dir, "tmp-export.jsonl")}"
          }
        ]
      )

      assert(attachments.map { |item| item["type"] } == %w[file link file],
             "expected attachments to normalize to file/link types")
      assert(attachments[0]["path"] == File.join(dir, "docs/project-notes.md"),
             "expected relative file paths to expand against the agent workspace")
      assert(attachments[1]["url"] == "https://github.com/example/web/pull/123",
             "expected links to keep an http(s) URL")
      assert(attachments[2]["path"] == File.join(dir, "tmp-export.jsonl"),
             "expected file:// targets to normalize to absolute paths")
      assert(!attachments[2].key?("url"), "expected file attachments not to keep file:// URLs")
    end
  end

  def assert_duplicate_attachment_targets_are_deduped
    Dir.mktmpdir("hq-attachment-normalization-test") do |dir|
      FileUtils.mkdir_p(File.join(dir, "docs"))
      notes_path = File.join(dir, "docs/project-notes.md")
      File.write(notes_path, "# Project notes\n")
      agent = HQ::ManagedAgent.new(
        key: "attachment-dedup",
        name: "Attachment Dedup",
        project_key: "demo",
        template_key: "custom",
        workspace: dir,
        prompt: "Test attachment deduplication",
        agent: "claude",
        log_path: File.join(dir, "agent.raw.log")
      )

      attachments = agent.send(
        :normalize_attachments,
        [
          {
            "type" => "file",
            "title" => "Project notes",
            "path" => "docs/project-notes.md"
          },
          {
            "type" => "file",
            "title" => "Renamed project notes",
            "path" => notes_path
          },
          {
            "type" => "link",
            "title" => "Implementation PR",
            "url" => "https://github.com/example/web/pull/123"
          },
          {
            "type" => "link",
            "title" => "Renamed implementation PR",
            "url" => "https://github.com/example/web/pull/123"
          }
        ]
      )

      assert(attachments.map { |item| item["title"] } == ["Project notes", "Implementation PR"],
             "expected identical file paths and URLs to dedupe regardless of title")
    end
  end

  def assert_new_attachment_records_are_prepended
    Dir.mktmpdir("hq-attachment-normalization-test") do |dir|
      FileUtils.mkdir_p(File.join(dir, "docs"))
      older_path = File.join(dir, "docs/older.md")
      newer_path = File.join(dir, "docs/newer.md")
      File.write(older_path, "# Older\n")
      File.write(newer_path, "# Newer\n")
      agent = HQ::ManagedAgent.new(
        key: "attachment-prepend",
        name: "Attachment Prepend",
        project_key: "demo",
        template_key: "custom",
        workspace: dir,
        prompt: "Test attachment ordering",
        agent: "claude",
        log_path: File.join(dir, "agent.raw.log")
      )
      memory = agent.send(:memory_store)

      memory.append_attachment!(
        {
          "type" => "file",
          "title" => "Older notes",
          "path" => older_path
        },
        created_at: Time.parse("2026-05-01 10:00:00")
      )
      memory.append_attachment!(
        {
          "type" => "file",
          "title" => "Newer notes",
          "path" => newer_path
        },
        created_at: Time.parse("2026-05-01 11:00:00")
      )

      assert(agent.attachments.map { |item| item["title"] } == ["Newer notes", "Older notes"],
             "expected newly added attachment records to appear first")

      memory.append_attachment!(
        {
          "type" => "file",
          "title" => "Renamed older notes",
          "path" => older_path
        },
        created_at: Time.parse("2026-05-01 12:00:00")
      )

      assert(agent.attachments.map { |item| item["title"] } == ["Renamed older notes", "Newer notes"],
             "expected duplicate targets to be replaced at the front")
    end
  end

  def assert_legacy_kind_attachments_remain_supported
    Dir.mktmpdir("hq-attachment-normalization-test") do |dir|
      FileUtils.mkdir_p(File.join(dir, "tmp"))
      export_path = File.join(dir, "tmp/llm_configurations_export.jsonl")
      File.write(export_path, "{}\n")
      notes_path = File.join(dir, "notes.md")
      File.write(notes_path, "# Notes\n")
      agent = HQ::ManagedAgent.new(
        key: "attachment-normalization",
        name: "Attachment Normalization",
        project_key: "demo",
        template_key: "custom",
        workspace: dir,
        prompt: "Test attachment normalization",
        agent: "claude",
        log_path: File.join(dir, "agent.raw.log")
      )

      attachments = agent.send(
        :normalize_attachments,
        [
          {
            "kind" => "document",
            "title" => "tmp/llm_configurations_export.jsonl",
            "url" => nil
          },
          {
            "kind" => "document",
            "title" => "Markdown notes",
            "url" => "file://#{notes_path}"
          },
          {
            "kind" => "link",
            "title" => "Implementation PR",
            "url" => "https://github.com/example/web/pull/123"
          }
        ]
      )

      assert(attachments.map { |item| item["type"] } == %w[file file link],
             "expected legacy kind attachments to normalize to file/link")
      assert(attachments[0]["path"] == export_path,
             "expected legacy title-only file paths to be recovered as file paths")
      assert(attachments[0]["title"] == "llm_configurations_export.jsonl",
             "expected recovered path titles to use a display basename")
      assert(attachments[1]["path"] == notes_path,
             "expected legacy file:// URLs to become paths")
      assert(attachments[2]["kind"] == "link", "expected legacy kind to remain available")
    end
  end

  def assert_invalid_attachments_are_dropped
    Dir.mktmpdir("hq-attachment-normalization-test") do |dir|
      agent = HQ::ManagedAgent.new(
        key: "attachment-normalization",
        name: "Attachment Normalization",
        project_key: "demo",
        template_key: "custom",
        workspace: dir,
        prompt: "Test attachment normalization",
        agent: "claude",
        log_path: File.join(dir, "agent.raw.log")
      )

      attachments = agent.send(
        :normalize_attachments,
        [
          {
            "type" => "file",
            "title" => "Missing file",
            "path" => "tmp/missing.jsonl"
          },
          {
            "type" => "link",
            "title" => "Local file URL is not a link",
            "url" => "file:///tmp/result.txt"
          },
          {
            "type" => "link",
            "title" => "FTP link",
            "url" => "ftp://example.com/result.txt"
          }
        ]
      )

      assert(attachments.nil?, "expected invalid attachments to be dropped after normalization")
    end
  end

  def assert(condition, message)
    raise message unless condition
  end
end

AttachmentNormalizationTest.run! if $PROGRAM_NAME == __FILE__
