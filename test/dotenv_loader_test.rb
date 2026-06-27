# frozen_string_literal: true

require "tmpdir"

require_relative "../lib/hq/dotenv_loader"

module DotenvLoaderTest
  module_function

  def run!
    assert_loads_dotenv_without_overriding_existing_env
    assert_load_files_preserves_env_and_allows_later_files_to_override
    assert_default_paths_include_root_and_tycho_home
    assert_missing_file_is_empty
    puts "dotenv_loader_test: ok"
  end

  def assert_loads_dotenv_without_overriding_existing_env
    Dir.mktmpdir("hq-dotenv-test") do |dir|
      path = File.join(dir, ".env")
      File.write(path, <<~ENV)
        # comment
        TYCHO_WEB_PUSH_VAPID_SUBJECT=mailto:tycho@example.com
        export TYCHO_LOG_LEVEL=DEBUG
        QUOTED="hello world"
        SINGLE='single quoted'
        EMPTY=
        NO_EQUALS
        INVALID-NAME=ignored
      ENV

      env = { "TYCHO_LOG_LEVEL" => "INFO" }
      loaded = HQ::DotenvLoader.load(path, env: env)

      assert(env["TYCHO_WEB_PUSH_VAPID_SUBJECT"] == "mailto:tycho@example.com", "expected VAPID subject to load")
      assert(env["TYCHO_LOG_LEVEL"] == "INFO", "expected existing environment value to win")
      assert(!loaded.key?("TYCHO_LOG_LEVEL"), "expected skipped existing value to be absent from loaded map")
      assert(env["QUOTED"] == "hello world", "expected double-quoted value to be unquoted")
      assert(env["SINGLE"] == "single quoted", "expected single-quoted value to be unquoted")
      assert(env["EMPTY"] == "", "expected empty value to load")
      assert(!env.key?("NO_EQUALS"), "expected entry without equals to be ignored")
      assert(!env.key?("INVALID-NAME"), "expected invalid key to be ignored")
    end
  end

  def assert_load_files_preserves_env_and_allows_later_files_to_override
    Dir.mktmpdir("hq-dotenv-test") do |dir|
      install_env = File.join(dir, "install.env")
      user_env = File.join(dir, "user.env")
      File.write(install_env, <<~ENV)
        TYCHO_REMOTE_TOKEN=install-token
        TYCHO_LOG_LEVEL=DEBUG
      ENV
      File.write(user_env, <<~ENV)
        TYCHO_REMOTE_TOKEN=user-token
        TYCHO_WEB_PUSH_VAPID_SUBJECT=mailto:user@example.com
      ENV

      env = { "TYCHO_LOG_LEVEL" => "WARN" }
      loaded = HQ::DotenvLoader.load_files([install_env, user_env], env: env)

      assert(env["TYCHO_REMOTE_TOKEN"] == "user-token", "expected later dotenv file to override earlier dotenv value")
      assert(env["TYCHO_LOG_LEVEL"] == "WARN", "expected existing environment to beat every dotenv file")
      assert(env["TYCHO_WEB_PUSH_VAPID_SUBJECT"] == "mailto:user@example.com", "expected user dotenv values to load")
      assert(loaded["TYCHO_REMOTE_TOKEN"] == "user-token", "expected loaded map to show final loaded value")
      assert(!loaded.key?("TYCHO_LOG_LEVEL"), "expected protected shell env value to stay out of loaded map")
    end
  end

  def assert_default_paths_include_root_and_tycho_home
    Dir.mktmpdir("hq-dotenv-test") do |dir|
      home = File.join(dir, "home")
      paths = HQ::DotenvLoader.default_paths(root: File.join(dir, "install"), env: { "TYCHO_HOME" => home })

      assert(paths == [File.join(dir, "install", ".env"), File.join(home, ".env")],
             "expected default dotenv paths to include install root and TYCHO_HOME")
    end
  end

  def assert_missing_file_is_empty
    env = {}
    loaded = HQ::DotenvLoader.load("/tmp/hq-missing-dotenv", env: env)

    assert(loaded == {}, "expected missing file to load no values")
    assert(env == {}, "expected missing file to leave env unchanged")
  end

  def assert(condition, message)
    raise message unless condition
  end
end

DotenvLoaderTest.run! if $PROGRAM_NAME == __FILE__
