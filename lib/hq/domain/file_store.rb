# frozen_string_literal: true

require "fileutils"
require "json"
require "securerandom"
require "yaml"

module HQ
  module FileStore
    module_function

    def read_json(path, fallback:)
      return fallback unless File.exist?(path)

      JSON.parse(read_text(path))
    rescue StandardError => e
      if (backup = read_backup_json(path))
        log_warning("Recovered #{path} from backup after #{e.class}: #{e.message}")
        return backup
      end

      log_warning("Failed to read #{path}: #{e.class} - #{e.message}")
      fallback
    end

    def write_json(path, value, backup: true)
      atomic_write(path, JSON.pretty_generate(value), backup:)
    end

    def write_yaml(path, value, backup: true)
      atomic_write(path, YAML.dump(value), backup:)
    end

    def atomic_write(path, content, backup: true)
      FileUtils.mkdir_p(File.dirname(path))
      temp_path = "#{path}.tmp-#{$PROCESS_ID}-#{SecureRandom.hex(6)}"

      File.open(temp_path, File::WRONLY | File::CREAT | File::EXCL, 0o600) do |file|
        file.write(content.to_s.encode(Encoding::UTF_8))
        file.flush
        file.fsync
      end

      copy_backup(path) if backup
      File.rename(temp_path, path)
      fsync_directory(File.dirname(path))
      true
    ensure
      FileUtils.rm_f(temp_path) if temp_path
    end

    def backup_path(path)
      "#{path}.bak"
    end

    def read_backup_json(path)
      backup = backup_path(path)
      return nil unless File.exist?(backup)

      JSON.parse(read_text(backup))
    rescue StandardError => e
      log_warning("Failed to read backup #{backup}: #{e.class} - #{e.message}")
      nil
    end

    def read_text(path)
      File.read(path, mode: "r:UTF-8")
    end

    def copy_backup(path)
      return unless File.exist?(path)

      FileUtils.cp(path, backup_path(path))
    rescue StandardError => e
      log_warning("Failed to back up #{path}: #{e.class} - #{e.message}")
    end

    def fsync_directory(dir)
      File.open(dir, File::RDONLY) do |directory|
        directory.fsync
      rescue SystemCallError
        nil
      end
    rescue SystemCallError
      nil
    end

    def log_warning(message)
      if HQ.respond_to?(:logger)
        HQ.logger.warn("FileStore") { message }
      end
    rescue StandardError
      nil
    end
  end
end
