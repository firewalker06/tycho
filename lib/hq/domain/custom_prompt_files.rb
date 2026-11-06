# frozen_string_literal: true

require "json"
require "securerandom"
require "fileutils"

module HQ
  module CustomPromptFiles
    module_function

    DIRECTORY_NAME = /\Aprompt-([1-9]\d*)-[0-9a-f]{32}\z/
    FILES = %w[lease owner.json owner.next prompt].freeze

    def root
      @root_override || File.join(logs_root, "custom_prompt_files")
    end

    def root=(path)
      @root_override = File.expand_path(path)
    end

    # This module also runs in the gem-free native launcher. Do not load HQ's
    # full constants and logger there.
    def logs_root
      return USER_LOGS_DIR if defined?(USER_LOGS_DIR)

      home = ENV["TYCHO_HOME"].to_s
      home = File.join(Dir.home, ".tycho") if home.empty?
      logs = ENV["TYCHO_LOGS_ROOT"].to_s
      File.expand_path(logs.empty? ? File.join(home, "logs") : logs)
    end

    def private_entry?(path, directory: false)
      stat = File.lstat(path)
      stat.uid == Process.uid && (stat.mode & 0o777) == (directory ? 0o700 : 0o600) &&
        (directory ? stat.directory? : stat.file?)
    rescue Errno::ENOENT
      false
    end

    def create
      FileUtils.mkdir_p(File.dirname(root))
      begin
        Dir.mkdir(root, 0o700)
      rescue Errno::EEXIST
        # Never follow an existing symlink or use a shared directory.
      end
      raise IOError, "Unsafe custom prompt directory" unless private_entry?(root, directory: true)

      directory = File.join(root, "prompt-#{Process.pid}-#{SecureRandom.hex(16)}")
      Dir.mkdir(directory, 0o700)
      lease = File.open(File.join(directory, "lease"), File::RDWR | File::CREAT | File::EXCL, 0o600)
      lease.flock(File::LOCK_EX)
      File.open(File.join(directory, "owner.json"), File::WRONLY | File::CREAT | File::EXCL, 0o600) do |file|
        file.write(JSON.generate("format" => "tycho-prompt-v1", "pid" => Process.pid))
        file.flush
        file.fsync
      end
      sync_directory(directory)
      sync_directory(root)
      [directory, lease]
    end

    def record_child(directory, pid)
      owner = { "format" => "tycho-prompt-v1", "pid" => Process.pid, "child_pid" => pid }
      path = File.join(directory, "owner.next")
      File.open(path, File::WRONLY | File::CREAT | File::EXCL, 0o600) do |file|
        file.write(JSON.generate(owner))
        file.flush
        file.fsync
      end
      File.rename(path, File.join(directory, "owner.json"))
      sync_directory(directory)
    end

    def sync_directory(path)
      File.open(path, File::RDONLY, &:fsync)
    end

    def remove(directory)
      FILES.each do |name|
        path = File.join(directory, name)
        File.unlink(path) if File.exist?(path)
      end
      Dir.rmdir(directory)
    rescue Errno::ENOENT
      nil # Another completed recovery pass already removed it.
    end

    def recover!
      return unless private_entry?(root, directory: true)

      Dir.children(root).each do |name|
        match = DIRECTORY_NAME.match(name)
        next unless match && Integer(match[1]) <= 2_147_483_647

        recover_directory(File.join(root, name), Integer(match[1]))
      end
    end

    def recover_directory(directory, pid)
      return unless private_entry?(directory, directory: true)
      return unless (Dir.children(directory) - FILES).empty?
      return unless Dir.children(directory).all? { |name| private_entry?(File.join(directory, name)) }

      File.open(File.join(directory, "lease"), File::RDWR | File::NOFOLLOW) do |lease|
        # Both runner and wrapper hold this lease. Read the latest ownership
        # only after locking, including a child published during this scan.
        return unless lease.flock(File::LOCK_EX | File::LOCK_NB)

        owner = JSON.parse(File.binread(File.join(directory, "owner.json")))
        return unless owner.is_a?(Hash) && (owner.keys - %w[format pid child_pid]).empty? &&
                      owner["format"] == "tycho-prompt-v1" && owner["pid"] == pid
        child_pid = owner["child_pid"]
        return unless child_pid.nil? || (child_pid.is_a?(Integer) && child_pid.between?(1, 2_147_483_647))

        return if live_pid?(pid) || (child_pid && live_pid?(child_pid))

        remove(directory)
      end
    rescue Errno::ENOENT, Errno::ELOOP, JSON::ParserError
      nil
    end

    def live_pid?(pid)
      Process.kill(0, pid)
      # Zombies no longer hold file descriptors and must not block recovery.
      IO.popen(["/bin/ps", "-p", pid.to_s, "-o", "stat="], &:read).strip.match?(/\A[^Z\s]/)
    rescue Errno::ESRCH
      false
    rescue SystemCallError
      true # Keep the file if process ownership cannot be checked.
    end
  end
end
