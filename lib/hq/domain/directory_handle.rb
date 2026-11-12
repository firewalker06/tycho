# frozen_string_literal: true

require "fiddle"

module HQ
  # POSIX directory-relative operations for macOS and Linux (including WSL).
  # Each open consumes one component with O_NOFOLLOW; writes use only a held
  # descriptor and a basename, never a path that can follow a replaced parent.
  module DirectoryHandle
    class Unavailable < StandardError; end

    module_function

    def open(path)
      current = File.open("/", File::RDONLY)
      path.split("/").reject(&:empty?).each do |component|
        child = open_at(current, component, File::RDONLY | File::NONBLOCK | nofollow)
        begin
          raise Errno::ENOTDIR, component unless child.stat.directory?
        rescue StandardError
          child.close
          raise
        end
        current.close
        current = child
      end
      yield current
    ensure
      current&.close unless current&.closed?
    end

    def mkdir_at(directory, name)
      component!(name)
      result = mkdir_function.call(directory.fileno, name, 0o777)
      raise SystemCallError.new("mkdirat #{name}", Fiddle.last_error) if result == -1
    end

    def write_once_at(directory, name, content)
      file = open_at(directory, name, File::WRONLY | File::CREAT | File::EXCL | nofollow, 0o666)
      file.write(content)
    rescue Errno::EEXIST
      # Preserve existing files and symlinks without opening or modifying them.
      nil
    ensure
      file&.close
    end

    def open_at(directory, name, flags, mode = nil)
      component!(name)
      args = [directory.fileno, name, flags]
      args += [Fiddle::TYPE_INT, mode] unless mode.nil?
      fd = open_function.call(*args)
      raise SystemCallError.new("openat #{name}", Fiddle.last_error) if fd == -1

      io = IO.for_fd(fd)
      io.close_on_exec = true
      io
    end

    def component!(name)
      raise ArgumentError, "Expected one directory entry" if name.empty? || %w[. ..].include?(name) || name.include?("/") || name.include?("\0")
    end

    def nofollow
      raise Unavailable, "Secure folder creation requires POSIX O_NOFOLLOW" unless File.const_defined?(:NOFOLLOW)

      File::NOFOLLOW
    end

    def open_function
      @open_function ||= Fiddle::Function.new(
        Fiddle::Handle::DEFAULT["openat"],
        [Fiddle::TYPE_INT, Fiddle::TYPE_VOIDP, Fiddle::TYPE_INT, Fiddle::TYPE_VARIADIC], Fiddle::TYPE_INT
      )
    rescue Fiddle::DLError => e
      raise Unavailable, "Secure folder creation requires POSIX openat: #{e.message}"
    end

    def mkdir_function
      @mkdir_function ||= Fiddle::Function.new(
        Fiddle::Handle::DEFAULT["mkdirat"],
        [Fiddle::TYPE_INT, Fiddle::TYPE_VOIDP, Fiddle::TYPE_INT], Fiddle::TYPE_INT
      )
    rescue Fiddle::DLError => e
      raise Unavailable, "Secure folder creation requires POSIX mkdirat: #{e.message}"
    end
  end
end
