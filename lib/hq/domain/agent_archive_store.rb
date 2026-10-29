# frozen_string_literal: true

require_relative "constants"
require_relative "file_store"
require_relative "managed_agent"
require "fileutils"
require "time"

module HQ
  class AgentArchiveStore
    ReceiptLookupError = Class.new(StandardError)
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
      target = key.to_s
      signature = root_signature
      cached = self.class.cache_mutex.synchronize { self.class.snapshot_cache[@root] }
      if cached && cached.fetch(:signature) == signature
        return cached.fetch(:records).find { |record| record.agent.key == target }
      end

      direct_manifest_paths(target).filter_map { |path| load_record(path) }
                                   .find { |record| record.agent.key == target }
    end

    # Creation needs proven absence, not the best-effort browsing snapshot.
    # The caller holds the agent-store mutation lock through lookup and save.
    def find_creation_request(id)
      entries = begin
        Dir.children(@root)
      rescue Errno::ENOENT
        return nil
      end
      records = entries.sort.filter_map do |entry|
        directory = File.join(@root, entry)
        next unless File.stat(directory).directory?

        load_record(File.join(directory, "agent_manifest.json"), strict: true)
      end
      records.find { |record| record.agent.creation_request&.fetch("id", nil) == id }
    rescue StandardError
      raise ReceiptLookupError, "Could not check creation request. Try again."
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

    def direct_manifest_paths(key)
      suffix = "-#{key}"
      Dir.children(@root).select { |entry| entry.end_with?(suffix) }
         .sort
         .reverse_each
         .map { |entry| File.join(@root, entry, "agent_manifest.json") }
         .select { |path| File.file?(path) }
    rescue Errno::ENOENT
      []
    end

    def load_record(path, strict: false)
      hash = FileStore.read_json(path, fallback: {})
      if strict && (!hash.is_a?(Hash) || hash["key"].to_s.empty?)
        raise ReceiptLookupError, "Could not check creation request. Try again."
      end
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
      raise ReceiptLookupError, "Could not check creation request. Try again." if strict

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
