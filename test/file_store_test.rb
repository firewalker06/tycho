# frozen_string_literal: true

require "json"
require "tmpdir"
require "yaml"

require_relative "../lib/hq/domain/file_store"

module FileStoreTest
  module_function

  def run!
    assert_write_json_creates_backup_and_replaces_atomically
    assert_write_yaml_creates_backup_and_replaces_atomically
    assert_read_json_recovers_from_backup
    assert_read_json_handles_utf8_when_external_encoding_is_ascii
    puts "file_store_test: ok"
  end

  def assert_write_json_creates_backup_and_replaces_atomically
    Dir.mktmpdir("hq-file-store-test") do |dir|
      path = File.join(dir, "state.json")
      HQ::FileStore.write_json(path, [{ "key" => "first" }])
      first = JSON.parse(File.read(path))
      assert(first == [{ "key" => "first" }], "expected initial JSON write")

      HQ::FileStore.write_json(path, [{ "key" => "second" }])
      current = JSON.parse(File.read(path))
      backup = JSON.parse(File.read(HQ::FileStore.backup_path(path)))

      assert(current == [{ "key" => "second" }], "expected current file to contain replacement state")
      assert(backup == [{ "key" => "first" }], "expected backup to contain previous state")
      assert(Dir.glob("#{path}.tmp-*").empty?, "expected temporary files to be cleaned up")
    end
  end

  def assert_write_yaml_creates_backup_and_replaces_atomically
    Dir.mktmpdir("hq-file-store-test") do |dir|
      path = File.join(dir, "state.yml")
      HQ::FileStore.write_yaml(path, { "name" => "first" })
      first = YAML.safe_load(File.read(path))
      assert(first == { "name" => "first" }, "expected initial YAML write")

      HQ::FileStore.write_yaml(path, { "name" => "second" })
      current = YAML.safe_load(File.read(path))
      backup = YAML.safe_load(File.read(HQ::FileStore.backup_path(path)))

      assert(current == { "name" => "second" }, "expected current file to contain replacement YAML")
      assert(backup == { "name" => "first" }, "expected YAML backup to contain previous state")
      assert(Dir.glob("#{path}.tmp-*").empty?, "expected YAML temporary files to be cleaned up")
    end
  end

  def assert_read_json_recovers_from_backup
    Dir.mktmpdir("hq-file-store-test") do |dir|
      path = File.join(dir, "state.json")
      File.write(path, "{not json")
      File.write(HQ::FileStore.backup_path(path), JSON.pretty_generate([{ "key" => "backup" }]))

      recovered = HQ::FileStore.read_json(path, fallback: [])
      assert(recovered == [{ "key" => "backup" }], "expected invalid primary JSON to recover from backup")
    end
  end

  def assert_read_json_handles_utf8_when_external_encoding_is_ascii
    Dir.mktmpdir("hq-file-store-test") do |dir|
      path = File.join(dir, "state.json")
      File.binwrite(path, JSON.pretty_generate([{ "name" => "Let’s implement autocomplete" }]))

      previous_external = Encoding.default_external
      Encoding.default_external = Encoding::US_ASCII
      loaded = HQ::FileStore.read_json(path, fallback: [])

      assert(loaded == [{ "name" => "Let’s implement autocomplete" }],
             "expected UTF-8 JSON to load when default external encoding is US-ASCII")
    ensure
      Encoding.default_external = previous_external if previous_external
    end
  end

  def assert(condition, message)
    raise message unless condition
  end
end

FileStoreTest.run! if $PROGRAM_NAME == __FILE__
