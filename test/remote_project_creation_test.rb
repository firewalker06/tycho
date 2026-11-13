# frozen_string_literal: true

require_relative "support/push_safety"
require_relative "../lib/hq/domain/remote_project_creation"

module RemoteProjectCreationTest
  module_function

  def assert(value, message)
    raise message unless value
  end

  def with_replacement_before_mkdir(parent:, outside:, name:)
    # Hook the last Ruby boundary before the real OS operation. The operation
    # itself still runs, including when the policy later rejects the path.
    receiver = defined?(HQ::DirectoryHandle) ? HQ::DirectoryHandle : Dir
    method = receiver == Dir ? :mkdir : :mkdir_at
    original = receiver.method(method)
    replaced = false
    receiver.define_singleton_method(method) do |*args|
      leaf = receiver == Dir ? File.basename(args.first) : args[1]
      if !replaced && leaf == name
        replaced = true
        File.rename(parent, "#{parent}-saved")
        File.symlink(outside, parent)
      end
      original.call(*args)
    end
    yield
    assert(replaced, "replacement hook must reach the real creation boundary")
  ensure
    receiver.define_singleton_method(method, original) if original
  end

  def assert_replacement_race(kind)
    Dir.mktmpdir("tycho-project-race-") do |temporary|
      root = File.realpath(temporary)
      home = File.join(root, "home")
      outside = File.join(root, "outside")
      FileUtils.mkdir_p([home, outside])
      File.write(File.join(outside, "keep"), "unchanged")
      starter = File.join(home, "tycho-projects")
      case kind
      when :parent
        parent = File.join(home, "parent")
        FileUtils.mkdir_p(parent)
        path = File.join(parent, "new")
        leaf = "new"
      when :ancestor
        parent = File.join(home, "ancestor")
        FileUtils.mkdir_p(File.join(parent, "parent"))
        FileUtils.mkdir_p(File.join(outside, "parent"))
        path = File.join(parent, "parent", "new")
        leaf = "new"
      when :starter_parent
        parent = File.join(home, "custom")
        FileUtils.mkdir_p(parent)
        starter = File.join(parent, "starter")
        path = ""
        leaf = "starter"
      when :starter
        parent = starter
        FileUtils.mkdir_p(parent)
        path = ""
        leaf = "new"
      when :home
        parent = home
        path = ""
        leaf = "tycho-projects"
      end
      policy = HQ::RemoteProjectCreation.new(home: home, starter_directory: starter)
      with_replacement_before_mkdir(parent: parent, outside: outside, name: leaf) do
        begin
          policy.prepare!(path, key: "new")
          raise "replaced path must be rejected (#{kind})"
        rescue HQ::RemoteProjectCreation::Error
        end
      end
      unexpected = Dir.glob(File.join(outside, "**", "*"), File::FNM_DOTMATCH).reject do |entry|
        [outside, File.join(outside, "."), File.join(outside, "keep"), File.join(outside, "parent")].include?(entry)
      end
      assert(unexpected.empty?, "#{kind} replacement created outside entries: #{unexpected.inspect}")
      assert(File.read(File.join(outside, "keep")) == "unchanged", "outside files must be preserved")
    end
  end

  def assert_replacement_before_open
    Dir.mktmpdir("tycho-project-open-race-") do |temporary|
      root = File.realpath(temporary)
      home = File.join(root, "home")
      parent = File.join(home, "parent")
      outside = File.join(root, "outside")
      FileUtils.mkdir_p([parent, outside])
      original = HQ::DirectoryHandle.method(:open_at)
      replaced = false
      HQ::DirectoryHandle.define_singleton_method(:open_at) do |directory, name, *args|
        if name == "parent" && !replaced
          replaced = true
          File.rename(parent, "#{parent}-saved")
          File.symlink(outside, parent)
        end
        original.call(directory, name, *args)
      end
      policy = HQ::RemoteProjectCreation.new(home: home, starter_directory: File.join(home, "tycho-projects"))
      begin
        policy.prepare!(File.join(parent, "new"), key: "new")
        raise "replacement symlink must not be opened"
      rescue HQ::RemoteProjectCreation::Error
      end
      assert(replaced, "must reach the no-follow open boundary")
      assert(Dir.empty?(outside), "no-follow open must prevent outside writes")
      assert(Dir.empty?("#{parent}-saved"), "rejected open must not create a folder")
    ensure
      HQ::DirectoryHandle.define_singleton_method(:open_at, original) if original
    end
  end

  def assert_welcome_file_replacement
    Dir.mktmpdir("tycho-project-files-race-") do |temporary|
      root = File.realpath(temporary)
      home = File.join(root, "home")
      target = File.join(home, "welcome")
      outside = File.join(root, "outside")
      FileUtils.mkdir_p([home, outside])
      original = HQ::DirectoryHandle.method(:write_once_at)
      replaced = false
      HQ::DirectoryHandle.define_singleton_method(:write_once_at) do |directory, name, content|
        unless replaced
          replaced = true
          File.rename(target, "#{target}-saved")
          File.symlink(outside, target)
        end
        original.call(directory, name, content)
      end
      policy = HQ::RemoteProjectCreation.new(home: home, starter_directory: File.join(home, "tycho-projects"))
      begin
        policy.prepare!(target, key: "welcome", files: { "README.md" => "Welcome", "notes.md" => "Notes" })
        raise "changed Welcome path must be rejected"
      rescue HQ::RemoteProjectCreation::Error
      end
      assert(replaced, "must reach the real Welcome file write")
      assert(Dir.empty?(outside), "Welcome files must not follow a replaced folder")
      assert(File.read("#{target}-saved/README.md") == "Welcome", "file write must use the held directory")
      assert(File.read("#{target}-saved/notes.md") == "Notes", "all Welcome files must use the held directory")
    ensure
      HQ::DirectoryHandle.define_singleton_method(:write_once_at, original) if original
    end
  end

  def assert_existing_alias_and_files
    Dir.mktmpdir("tycho-project-existing-") do |temporary|
      home = File.realpath(temporary)
      target = File.join(home, "existing")
      FileUtils.mkdir_p(target)
      File.symlink(target, File.join(home, "alias"))
      File.write(File.join(target, "README.md"), "Keep")
      File.symlink(File.join(home, "missing"), File.join(target, "notes.md"))
      policy = HQ::RemoteProjectCreation.new(home: home, starter_directory: File.join(home, "tycho-projects"))
      result = policy.prepare!(File.join(home, "alias"), key: "existing", files: { "README.md" => "Replace", "notes.md" => "Replace" })
      assert(result == target, "safe existing alias must use its canonical inside-home path")
      assert(File.read(File.join(target, "README.md")) == "Keep", "existing files must not change")
      assert(File.symlink?(File.join(target, "notes.md")), "existing dangling file links must not change")
      assert(!File.exist?(File.join(home, "missing")), "write-once files must not follow dangling links")
    end
  end

  def assert_unavailable_fails_closed
    Dir.mktmpdir("tycho-project-native-unavailable-") do |temporary|
      home = File.realpath(temporary)
      original = HQ::DirectoryHandle.method(:mkdir_function)
      HQ::DirectoryHandle.define_singleton_method(:mkdir_function) do
        raise HQ::DirectoryHandle::Unavailable, "Secure folder creation requires POSIX mkdirat"
      end
      policy = HQ::RemoteProjectCreation.new(home: home, starter_directory: File.join(home, "tycho-projects"))
      begin
        policy.prepare!(File.join(home, "new"), key: "new")
        raise "unavailable native operation must fail closed"
      rescue HQ::RemoteProjectCreation::Error => e
        assert(e.message.include?("requires POSIX mkdirat"), "unavailable platform needs a useful error")
      end
      assert(Dir.empty?(home), "unsupported native operations must not fall back to pathname writes")
    ensure
      HQ::DirectoryHandle.define_singleton_method(:mkdir_function, original) if original
    end
  end

  def assert_permission_policy
    Dir.mktmpdir("tycho-project-permissions-") do |temporary|
      home = File.realpath(temporary)
      parent = File.join(home, "parent")
      Dir.mkdir(parent)
      policy = HQ::RemoteProjectCreation.new(home: home, starter_directory: File.join(parent, "starter"))
      [0o770, 0o777].each do |mode|
        File.chmod(mode, parent)
        [File.join(parent, "new"), ""].each do |input|
          begin
            policy.prepare!(input, key: "new", files: { "README.md" => "Welcome" })
            raise "untrusted-writable parent must be rejected"
          rescue HQ::RemoteProjectCreation::Error => e
            assert(e.message.include?("writable by other users"), "permissions error must explain rejection")
          end
          assert(Dir.empty?(parent), "reject before project/starter/Welcome mutation")
        end
      end
      File.chmod(0o1777, parent)
      target = policy.prepare!(File.join(parent, "new"), key: "new", files: { "README.md" => "Welcome" })
      assert(File.read(File.join(target, "README.md")) == "Welcome", "owned sticky entry must work")
      assert((File.stat(target).mode & 0o077).zero?, "new directory must exclude other users")
      assert((File.stat(File.join(target, "README.md")).mode & 0o077).zero?, "new file must exclude other users")
      # A real held fd with a substituted owner stat isolates the ownership
      # gate without privileged chown or relying on another host account.
      File.open(target) do |fd|
        actual = fd.method(:stat)
        fd.define_singleton_method(:stat) do
          stat = actual.call
          stat.define_singleton_method(:uid) { Process.euid + 10001 }
          stat
        end
        begin
          HQ::DirectoryPermissions.check!(fd)
          raise "foreign-owned entry under sticky parent must be rejected"
        rescue HQ::DirectoryPermissions::Error => e
          assert(e.message.include?("owner"), "foreign owner must explain rejection")
        end
      end
    end
  end

  def assert_native_acl_policy
    return unless RUBY_PLATFORM.include?("darwin")

    Dir.mktmpdir("tycho-project-acl-") do |temporary|
      home = File.realpath(temporary)
      policy = HQ::RemoteProjectCreation.new(home: home, starter_directory: File.join(home, "starter"))
      assert(system("chmod", "+a", "everyone allow delete_child", home), "fixture ACL installation must succeed")
      begin
        policy.prepare!("", key: "new")
        raise "mode bits must not hide an ACL delete grant"
      rescue HQ::RemoteProjectCreation::Error => e
        assert(e.message.include?("ACL grant"), "ACL grant must produce useful error")
      end
      assert(Dir.empty?(home), "ACL rejection must precede starter creation")
      assert(system("chmod", "-N", home), "remove only fixture ACL")
      assert(system("chmod", "+a", "everyone allow readattr,readextattr,readsecurity", home), "fixture read-only ACL installation must succeed")
      policy.prepare!(File.join(home, "readable"), key: "readable")
      assert(system("chmod", "+a", "everyone deny delete", home), "fixture deny ACL installation must succeed")
      policy.prepare!(File.join(home, "safe"), key: "safe")
      assert(Dir.exist?(File.join(home, "safe")), "deny ACL must remain compatible")
    ensure
      system("chmod", "-N", home) if home && File.exist?(home)
    end
  end

  def assert_input_and_unknown_policy
    Dir.mktmpdir("tycho-project-input-") do |temporary|
      root = File.realpath(temporary)
      home = File.join(root, "home")
      outside = File.join(root, "outside")
      FileUtils.mkdir_p([home, outside])
      File.symlink(outside, File.join(home, "escape"))
      policy = HQ::RemoteProjectCreation.new(home: home, starter_directory: File.join(home, "starter"))
      [File.join(home, "..", "outside", "new"), File.join(home, "escape", "new"), File.join(outside, "new")].each do |input|
        begin
          policy.prepare!(input, key: "new")
          raise "outside/traversal input must fail"
        rescue HQ::RemoteProjectCreation::Error
        end
      end
      assert(Dir.empty?(outside), "outside input must have no effects")
      original = HQ::DirectoryPermissions.method(:filesystem!)
      HQ::DirectoryPermissions.define_singleton_method(:filesystem!) do |_fd|
        raise HQ::DirectoryPermissions::Error, "Cannot verify this filesystem"
      end
      begin
        policy.prepare!("", key: "new")
        raise "unknown filesystem must fail closed"
      rescue HQ::RemoteProjectCreation::Error => e
        assert(e.message.include?("Cannot verify"), "unknown authority needs useful error")
      end
      assert(!Dir.exist?(File.join(home, "starter")), "unverified filesystem must not create starter")
    ensure
      HQ::DirectoryPermissions.define_singleton_method(:filesystem!, original) if original
    end
  end

  def run!
    %i[parent ancestor starter_parent starter home].each { |kind| assert_replacement_race(kind) }
    assert_replacement_before_open
    assert_welcome_file_replacement
    assert_existing_alias_and_files
    assert_unavailable_fails_closed
    assert_permission_policy
    assert_native_acl_policy
    assert_input_and_unknown_policy
    puts "remote_project_creation_test: ok"
  end
end

RemoteProjectCreationTest.run!
