# frozen_string_literal: true

require "fileutils"

require_relative "file_store"

module HQ
  class FileTransaction
    def self.run(paths)
      transaction = new(paths)
      yield transaction
    rescue StandardError
      transaction&.rollback
      raise
    end

    def initialize(paths)
      @snapshots = expanded_paths(paths).to_h { |path| [path, snapshot(path)] }
      @rollback_actions = []
    end

    def on_rollback(&action)
      @rollback_actions << action
    end

    def rollback
      @rollback_actions.reverse_each do |action|
        action.call
      rescue StandardError => e
        HQ.logger.error("FileTransaction") { "Rollback action failed: #{e.class} - #{e.message}" }
      end
      @snapshots.each { |path, state| restore(path, state) }
    end

    private

    def expanded_paths(paths)
      Array(paths).compact.map { |path| File.expand_path(path) }.flat_map do |path|
        [path, FileStore.backup_path(path)]
      end.uniq
    end

    def snapshot(path)
      return { exists: false } unless File.exist?(path)

      { exists: true, content: File.binread(path), mode: File.stat(path).mode & 0o777 }
    end

    def restore(path, state)
      unless state.fetch(:exists)
        FileUtils.rm_f(path)
        return
      end

      FileStore.atomic_write(path, state.fetch(:content), backup: false)
      File.chmod(state.fetch(:mode), path)
    rescue StandardError => e
      HQ.logger.error("FileTransaction") { "Failed to restore #{path}: #{e.class} - #{e.message}" }
    end
  end
end
