# frozen_string_literal: true

require_relative "constants"
require_relative "directory_handle"

module HQ
  # This policy applies only to manual Remote UI creation, not CLI registration.
  class RemoteProjectCreation
    class Error < StandardError; end

    def initialize(home: Dir.home, starter_directory: USER_WORKSPACES_DIR)
      @home_path = File.expand_path(home)
      @home = File.realpath(home)
      @starter_directory = canonical_home_path(starter_directory)
    end

    def prepare!(input, key:, files: {})
      raw = input.to_s.strip
      raw = File.join(@starter_directory, key) if raw.empty?
      raise Error, "Use a folder inside the server user home; parent traversal is not allowed" if raw.split("/").include?("..")
      raise Error, "Use ~/ or an absolute server folder path" unless raw.start_with?("~/", "/")

      path = raw.start_with?("~/") ? File.join(@home, raw.delete_prefix("~/")) : raw
      path = canonical_home_path(path)
      inside_home!(path)
      # Only the visible starter and the final folder are created. Other parents
      # must exist so a misspelled parent does not create a new directory tree.
      ensure_starter! if File.dirname(path) == File.expand_path(@starter_directory)
      resolved = ensure_directory!(path)
      DirectoryHandle.open(resolved) do |directory|
        files.each { |name, content| DirectoryHandle.write_once_at(directory, name, content) }
        verify_directory!(path, directory)
      end
      resolved
    rescue SystemCallError, ArgumentError, DirectoryHandle::Unavailable, DirectoryPermissions::Error => e
      raise Error, "Cannot use this server folder: #{e.message}"
    end

    private

    def canonical_home_path(path)
      expanded = File.expand_path(path)
      return @home + expanded.delete_prefix(@home_path) if expanded == @home_path || expanded.start_with?("#{@home_path}/")

      expanded
    end

    def inside_home!(path, allow_home: false)
      return if path.start_with?("#{@home}/") || (allow_home && path == @home)

      raise Error, "Choose a folder inside the server user home (#{@home})"
    end

    def ensure_starter!
      starter = File.expand_path(@starter_directory)
      inside_home!(starter)
      ensure_directory!(starter)
    end

    def ensure_directory!(path)
      parent = File.realpath(File.dirname(path))
      inside_home!(parent, allow_home: true)
      DirectoryHandle.open(parent) do |directory|
        begin
          DirectoryHandle.mkdir_at(directory, File.basename(path))
        rescue Errno::EEXIST
          # Existing folders and safe inside-home aliases are allowed.
        end
      end
      resolved = File.realpath(path)
      inside_home!(resolved)
      raise Error, "Choose a directory, not a file" unless File.directory?(resolved)

      resolved
    end

    def verify_directory!(path, directory)
      inside_home!(File.realpath(path))
      actual = File.stat(path)
      opened = directory.stat
      return if actual.dev == opened.dev && actual.ino == opened.ino

      raise Error, "The server folder changed during creation. Check the path and try again"
    end
  end
end
