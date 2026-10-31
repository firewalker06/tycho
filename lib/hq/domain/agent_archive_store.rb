# frozen_string_literal: true

require_relative "constants"
require_relative "file_store"
require_relative "managed_agent"
require "fileutils"
require "time"

module HQ
  class AgentArchiveStore
    ReceiptLookupError = Class.new(StandardError)
    # Start of the first receipt-capable source day (0429119, +07:00).
    RECEIPT_CAPABILITY_BOUNDARY = Time.iso8601("2026-10-29T00:00:00+07:00").freeze
    Record = Struct.new(:agent, :directory, :manifest_path, keyword_init: true)
    @cache_mutex = Mutex.new
    @snapshot_cache = {}

    class << self
      attr_reader :cache_mutex, :snapshot_cache
    end

    attr_reader :receipt_scan_health

    def initialize(root: AGENT_ARCHIVE_DIR)
      @root = root
      @receipt_scan_health = {}
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
      @receipt_scan_health = {}
      missing_manifests = 0
      entries = begin
        Dir.children(@root)
      rescue Errno::ENOENT
        return nil
      end
      records = entries.sort.filter_map do |entry|
        directory = File.join(@root, entry)
        raise ReceiptLookupError, "Archive directory is a symbolic link" if File.symlink?(directory)
        next unless File.stat(directory).directory?

        path = File.join(directory, "agent_manifest.json")
        if pre_receipt_archive_without_manifest?(entry, path)
          missing_manifests += 1
          next
        end

        load_record(path, strict: true)
      end
      if missing_manifests.positive?
        @receipt_scan_health = {
          status: "history_unavailable", missing_manifests:,
          message: "Some older archive history is unavailable."
        }
        HQ.logger.warn("AgentArchiveStore") do
          "#{missing_manifests} pre-receipt archives have no manifest or backup; archive history is unavailable, not verified healthy"
        end
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

    # Manifest writing began in e04dcfb (Aug 8); it does not prove receipt support.
    # Receipts first appear in 0429119 (Oct 29), merged as e5eed8b / PR 281.
    # Exclude only missing files in strictly dated, unchanged pre-capability
    # archives. Report unavailable archive history separately above.
    def pre_receipt_archive_without_manifest?(entry, path)
      return false unless entry.match?(/\A\d{8}-\d{6}-.+\z/) && entry < "20261029-000000"

      timestamp = entry[0, 15]
      parsed = Time.strptime(timestamp, "%Y%m%d-%H%M%S")
      return false unless parsed.strftime("%Y%m%d-%H%M%S") == timestamp

      !archive_file_present?(path) && !archive_file_present?("#{path}.bak") &&
        File.mtime(File.dirname(path)) < RECEIPT_CAPABILITY_BOUNDARY
    rescue ArgumentError
      false
    end

    def archive_file_present?(path)
      File.lstat(path)
      true
    rescue Errno::ENOENT
      false
    end

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
