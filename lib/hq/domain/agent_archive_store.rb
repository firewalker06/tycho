# frozen_string_literal: true

require_relative "constants"
require_relative "file_store"
require_relative "managed_agent"
require "fileutils"
require "time"

module HQ
  class AgentArchiveStore
    Record = Struct.new(:agent, :directory, :manifest_path, keyword_init: true)
    @cache_mutex = Mutex.new
    @snapshot_cache = {}

    class << self
      attr_reader :cache_mutex, :snapshot_cache
    end

    def initialize(root: AGENT_ARCHIVE_DIR)
      @root = root
    end

    def all
      signature = root_signature
      self.class.cache_mutex.synchronize do
        cached = self.class.snapshot_cache[@root]
        return cached.fetch(:records) if cached && cached.fetch(:signature) == signature
      end

      loop do
        signature = root_signature
        paths = Dir.glob(File.join(@root, "*", "agent_manifest.json")).sort
        records = paths.filter_map { |path| load_record(path) }.freeze
        next unless signature == root_signature

        self.class.cache_mutex.synchronize do
          cached = self.class.snapshot_cache[@root]
          return cached.fetch(:records) if cached && cached.fetch(:signature) == signature

          self.class.snapshot_cache[@root] = { signature:, records: }
        end
        return records
      end
    end

    def find(key)
      all.find { |record| record.agent.key == key.to_s }
    end

    def save(record)
      FileStore.write_json(record.manifest_path, record.agent.to_hash)
      FileUtils.touch(@root) if File.directory?(@root)
      invalidate!
    end

    private

    def root_signature
      mtime = File.mtime(@root)
      [mtime.to_i, mtime.nsec]
    rescue Errno::ENOENT
      nil
    end

    def invalidate!
      self.class.cache_mutex.synchronize { self.class.snapshot_cache.delete(@root) }
    end

    def load_record(path)
      hash = FileStore.read_json(path, fallback: {})
      return nil if hash["key"].to_s.empty?

      directory = File.dirname(path)
      raw_name = File.basename(hash["log_path"].to_s)
      raw_name = "agent.raw.log" if raw_name.empty?
      archived_raw = File.join(directory, raw_name)
      hash = hash.merge(
        "log_path" => archived_raw,
        "archived" => true,
        "archive_path" => directory,
        "archived_at" => archived_at(path).iso8601
      )
      Record.new(agent: ManagedAgent.from_hash(hash), directory:, manifest_path: path)
    rescue StandardError => e
      HQ.logger.warn("AgentArchiveStore") { "Skipping #{path}: #{e.class} - #{e.message}" }
      nil
    end

    def archived_at(path)
      basename = File.basename(File.dirname(path))
      Time.strptime(basename[0, 15], "%Y%m%d-%H%M%S")
    rescue ArgumentError
      File.mtime(path)
    end
  end
end
