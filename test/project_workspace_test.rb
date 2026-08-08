# frozen_string_literal: true

require "fileutils"
require "tmpdir"

require_relative "../lib/hq/domain/project_workspace"

module ProjectWorkspaceTest
  module_function

  def run!
    assert_lists_nested_content_with_deterministic_sorting
    assert_paginates_and_bounds_directory_payloads
    assert_rejects_directories_above_the_deterministic_scan_cap
    assert_previews_unicode_and_scrubs_invalid_utf8
    assert_rejects_binary_large_sensitive_and_generated_files
    assert_reports_permission_errors
    assert_rejects_traversal_and_absolute_paths
    assert_allows_internal_symlinks_and_rejects_escapes
    assert_handles_deleted_and_unavailable_paths
    puts "project_workspace_test: ok"
  end

  def assert_lists_nested_content_with_deterministic_sorting
    with_workspace do |root|
      FileUtils.mkdir_p(File.join(root, "docs"))
      File.write(File.join(root, "docs", "readme.md"), "hello")
      File.write(File.join(root, "Zeta.rb"), "z")
      File.write(File.join(root, "alpha.rb"), "a")
      File.write(File.join(root, ".rubocop.yml"), "AllCops: {}")
      File.write(File.join(root, ".env"), "SECRET=no")
      FileUtils.mkdir_p(File.join(root, ".git"))
      FileUtils.mkdir_p(File.join(root, "node_modules", "package"))

      listing = HQ::ProjectWorkspace.new(root).list
      assert(listing[:entries].map { |entry| entry[:name] } == ["docs", ".rubocop.yml", "alpha.rb", "Zeta.rb"],
             "expected directories first and stable case-insensitive sorting")
      assert(!listing.inspect.include?(root), "expected workspace payloads to omit host paths")

      nested = HQ::ProjectWorkspace.new(root).list(path: "docs")
      assert(nested[:parent] == "" && nested[:entries].first[:path] == "docs/readme.md",
             "expected relative nesting and a root parent breadcrumb")
    end
  end

  def assert_paginates_and_bounds_directory_payloads
    with_workspace do |root|
      205.times { |index| File.write(File.join(root, format("file-%03d.txt", index)), index.to_s) }
      browser = HQ::ProjectWorkspace.new(root)
      first = browser.list(limit: 100)
      second = browser.list(offset: first[:next_offset], limit: 100)
      last = browser.list(offset: second[:next_offset], limit: 100)

      assert(first[:entries].length == 100 && second[:entries].length == 100 && last[:entries].length == 5,
             "expected bounded paginated directory listings")
      assert(last[:next_offset].nil? && last[:total] == 205, "expected pagination metadata")
      assert_error("invalid_pagination") { browser.list(limit: 201) }
    end
  end

  def assert_previews_unicode_and_scrubs_invalid_utf8
    with_workspace do |root|
      File.write(File.join(root, "こんにちは.txt"), "héllo\n世界")
      File.binwrite(File.join(root, "scrub.txt"), "valid\xFFtail".b)
      browser = HQ::ProjectWorkspace.new(root)

      unicode = browser.preview(path: "こんにちは.txt")
      scrubbed = browser.preview(path: "scrub.txt")
      assert(unicode[:content] == "héllo\n世界", "expected Unicode text previews")
      assert(scrubbed[:content].valid_encoding? && scrubbed[:content].include?("\uFFFD"),
             "expected safe UTF-8 replacement for isolated invalid bytes")
    end
  end

  def assert_rejects_directories_above_the_deterministic_scan_cap
    with_workspace do |root|
      old_limit = HQ::ProjectWorkspace::MAX_DIRECTORY_ENTRIES
      replace_constant(HQ::ProjectWorkspace, :MAX_DIRECTORY_ENTRIES, 5)
      6.times { |index| File.write(File.join(root, "entry-#{index}.txt"), index.to_s) }
      assert_error("directory_too_large") { HQ::ProjectWorkspace.new(root).list }
    ensure
      replace_constant(HQ::ProjectWorkspace, :MAX_DIRECTORY_ENTRIES, old_limit) if old_limit
    end
  end

  def assert_rejects_binary_large_sensitive_and_generated_files
    with_workspace do |root|
      File.binwrite(File.join(root, "image.bin"), "abc\0def")
      File.binwrite(File.join(root, "late-binary.bin"), ("a" * 9_000) + "\0binary")
      File.binwrite(File.join(root, "large.txt"), "x" * (HQ::ProjectWorkspace::MAX_PREVIEW_BYTES + 1))
      File.write(File.join(root, "secret.pem"), "-----BEGIN PRIVATE KEY-----\nnope")
      File.write(File.join(root, "secrets.yml"), "token: nope\n")
      File.write(File.join(root, ".envrc"), "export TOKEN=nope\n")
      File.write(File.join(root, "config.yml"), "api_key: sk-abcdefghijklmnopqrstuvwxyz\n")
      File.write(File.join(root, "rails.yml"), "secret_key_base: a-real-application-secret\n")
      File.write(File.join(root, "service.yml"), "token: provider-access-value\n")
      File.write(File.join(root, "database.yml"), "url: postgres://user:password@example.test/app\n")
      FileUtils.mkdir_p(File.join(root, "dist"))
      File.write(File.join(root, "dist", "bundle.js"), "generated")
      browser = HQ::ProjectWorkspace.new(root)

      assert_error("binary") { browser.preview(path: "image.bin") }
      assert_error("binary") { browser.preview(path: "late-binary.bin") }
      assert_error("too_large") { browser.preview(path: "large.txt") }
      assert_error("not_found") { browser.preview(path: "secret.pem") }
      assert_error("not_found") { browser.preview(path: "secrets.yml") }
      assert_error("not_found") { browser.preview(path: ".envrc") }
      assert_error("sensitive") { browser.preview(path: "config.yml") }
      assert_error("sensitive") { browser.preview(path: "rails.yml") }
      assert_error("sensitive") { browser.preview(path: "service.yml") }
      assert_error("sensitive") { browser.preview(path: "database.yml") }
      assert_error("not_found") { browser.preview(path: "dist/bundle.js") }
    end
  end

  def assert_rejects_traversal_and_absolute_paths
    with_workspace do |root|
      browser = HQ::ProjectWorkspace.new(root)
      ["../outside", "docs/../../outside", "/etc/passwd", "C:\\Windows\\system.ini", "..%2foutside",
       "%2e%2e/outside", "%252e%252e%252foutside", "a\0b"].each do |path|
        assert_error("invalid_path") { browser.list(path:) }
      end
    end
  end

  def assert_reports_permission_errors
    return if Process.euid.zero?

    with_workspace do |root|
      locked = File.join(root, "locked")
      FileUtils.mkdir_p(locked)
      File.write(File.join(locked, "hidden.txt"), "hidden")
      File.chmod(0o000, locked)
      assert_error("permission_denied") { HQ::ProjectWorkspace.new(root).list(path: "locked") }
    ensure
      File.chmod(0o700, locked) if locked && File.exist?(locked)
    end
  end

  def assert_allows_internal_symlinks_and_rejects_escapes
    with_workspace do |root|
      outside = Dir.mktmpdir("tycho-workspace-outside")
      File.write(File.join(root, "target.txt"), "inside")
      File.write(File.join(outside, "outside.txt"), "outside")
      File.symlink(File.join(root, "target.txt"), File.join(root, "inside-link.txt"))
      File.symlink(File.join(outside, "outside.txt"), File.join(root, "outside-link.txt"))
      browser = HQ::ProjectWorkspace.new(root)

      listing = browser.list
      assert(listing[:entries].any? { |entry| entry[:name] == "inside-link.txt" && entry[:symlink] },
             "expected safe internal symlinks")
      assert(listing[:entries].none? { |entry| entry[:name] == "outside-link.txt" },
             "expected symlink escapes to be hidden")
      assert(browser.preview(path: "inside-link.txt")[:content] == "inside", "expected safe symlink previews")
      assert_error("invalid_path") { browser.preview(path: "outside-link.txt") }
    ensure
      FileUtils.remove_entry(outside) if outside && File.exist?(outside)
    end
  end

  def assert_handles_deleted_and_unavailable_paths
    root = Dir.mktmpdir("tycho-workspace-unavailable")
    begin
      file = File.join(root, "gone.txt")
      File.write(file, "gone")
      browser = HQ::ProjectWorkspace.new(root)
      File.delete(file)
      assert_error("not_found") { browser.preview(path: "gone.txt") }
      FileUtils.remove_entry(root)
      assert_error("workspace_unavailable") { browser.list }
    ensure
      FileUtils.remove_entry(root) if File.exist?(root)
    end
  end

  def with_workspace
    Dir.mktmpdir("tycho-workspace") { |root| yield(root) }
  end

  def assert_error(code)
    yield
    raise "expected #{code}"
  rescue HQ::ProjectWorkspace::Error => e
    raise "expected #{code}, got #{e.code}" unless e.code == code
  end

  def assert(condition, message)
    raise message unless condition
  end

  def replace_constant(mod, name, value)
    mod.send(:remove_const, name)
    mod.const_set(name, value)
  end
end

ProjectWorkspaceTest.run! if $PROGRAM_NAME == __FILE__
