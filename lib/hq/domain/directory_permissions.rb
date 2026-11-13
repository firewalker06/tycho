# frozen_string_literal: true

require "fiddle"

module HQ
  # Only same-effective-UID and root processes are trusted. This is a local
  # filesystem policy, not isolation from a trusted process or storage admin.
  module DirectoryPermissions
    class Error < StandardError; end

    module_function

    def check!(directory)
      stat = directory.stat
      raise Error, "Folder owner must be the server user or root" unless [0, Process.euid].include?(stat.uid)
      raise Error, "Folder is writable by other users; use a protected folder" if (stat.mode & 0o022).positive? && (stat.mode & 0o1000).zero?

      # Sticky directories may admit new names, but cannot let other users
      # relocate an entry owned by us/root. Every opened child is checked too.
      filesystem!(directory)
      mac_acl!(directory) if RUBY_PLATFORM.include?("darwin")
      # On Linux POSIX ACLs the group mode bits are the effective ACL mask.
      # Named-user/group write grants therefore cannot exceed the check above.
    rescue Fiddle::DLError => e
      raise Error, "Cannot verify native folder permissions: #{e.message}"
    end

    def filesystem!(directory)
      buffer = Fiddle::Pointer.malloc(4096)
      call!("fstatfs", [Fiddle::TYPE_INT, Fiddle::TYPE_VOIDP], directory.fileno, buffer)
      supported = if RUBY_PLATFORM.include?("darwin")
        # Darwin struct statfs: f_fstypename follows the 72-byte fixed header.
        mac_filesystem?(buffer)
      elsif RUBY_PLATFORM.include?("linux")
        # ext2/3/4, XFS, Btrfs, tmpfs. Remote/FUSE/overlay permission and backing
        # authority are not established by a POSIX mode or device-number check.
        [0xef53, 0x58465342, 0x9123683e, 0x01021994].include?(buffer[0, Fiddle::SIZEOF_LONG].unpack1("L!") & 0xffffffff)
      end
      raise Error, "Cannot verify this filesystem for manual creation; use a supported local filesystem" unless supported
    end

    def mac_filesystem?(buffer)
      owner = buffer[56, 4].unpack1("I")
      flags = buffer[64, 4].unpack1("I")
      local = (flags & 0x00001000).positive?
      ownership = (flags & 0x00200000).zero? # MNT_IGNORE_OWNERSHIP
      local && ownership && [0, Process.euid].include?(owner) &&
        %w[apfs hfs].include?(buffer[72, 16].split("\0").first)
    end

    def mac_acl!(directory)
      acl = native("acl_get_fd", [Fiddle::TYPE_INT], Fiddle::TYPE_VOIDP).call(directory.fileno)
      if acl.to_i.zero?
        return if Fiddle.last_error == Errno::ENOENT::Errno

        raise Error, "Cannot read folder ACL permissions"
      end
      slot = Fiddle::Pointer.malloc(Fiddle::SIZEOF_VOIDP)
      selector = 0 # ACL_FIRST_ENTRY; subsequent calls use ACL_NEXT_ENTRY (-1).
      loop do
        result = native("acl_get_entry", [Fiddle::TYPE_VOIDP, Fiddle::TYPE_INT, Fiddle::TYPE_VOIDP]).call(acl, selector, slot)
        # Darwin returns -1/EINVAL at the end, unlike Linux's ACL API.
        break if result == -1 && Fiddle.last_error == Errno::EINVAL::Errno
        raise Error, "Cannot inspect folder ACL entries" unless result == 0

        entry = slot[0, Fiddle::SIZEOF_VOIDP].unpack1("J")
        tag = Fiddle::Pointer.malloc(Fiddle::SIZEOF_INT)
        call!("acl_get_tag_type", [Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP], entry, tag)
        kind = tag[0, Fiddle::SIZEOF_INT].unpack1("i!")
        raise Error, "Cannot verify folder ACL entry type" unless [1, 2].include?(kind)

        if kind == 1 # ACL_EXTENDED_ALLOW. Deny/read-only ACLs are safe.
          call!("acl_get_permset", [Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP], entry, slot)
          permissions = slot[0, Fiddle::SIZEOF_VOIDP].unpack1("J")
          # write/add, delete, append/add-subdirectory, delete-child,
          # write-attributes/xattrs/security, and change-owner.
          [2, 4, 5, 6, 8, 10, 12, 13].each do |bit|
            grant = native("acl_get_perm_np", [Fiddle::TYPE_VOIDP, Fiddle::TYPE_INT]).call(permissions, 1 << bit)
            raise Error, "Cannot inspect folder ACL permissions" if grant == -1
            raise Error, "Folder has a write/delete ACL grant that manual creation cannot verify" if grant == 1
          end
        end
        selector = -1
      end
    ensure
      native("acl_free", [Fiddle::TYPE_VOIDP]).call(acl) if acl && !acl.to_i.zero?
    end

    def call!(name, types, *args)
      return unless native(name, types).call(*args) == -1

      raise Error, "Cannot verify folder permissions (#{name}: #{SystemCallError.new(name, Fiddle.last_error).message})"
    end

    def native(name, types, result = Fiddle::TYPE_INT)
      Fiddle::Function.new(Fiddle::Handle::DEFAULT[name], types, result)
    end
  end
end
