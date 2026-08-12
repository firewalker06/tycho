# frozen_string_literal: true

require_relative "constants"
require_relative "file_store"
require_relative "managed_agent"

module HQ
  class AgentArchiveStore
    Record = Struct.new(:agent, :directory, :manifest_path, keyword_init: true)

    def initialize(root: AGENT_ARCHIVE_DIR)
      @root = root
    end

    def all
      Dir.glob(File.join(@root, "*", "agent_manifest.json")).sort.filter_map do |path|
        load_record(path)
      end
    end

    def find(key)
      all.find { |record| record.agent.key == key.to_s }
    end

    def save(record)
      FileStore.write_json(record.manifest_path, record.agent.to_hash)
    end

    private

    def load_record(path)
      hash = FileStore.read_json(path, fallback: {})
      return nil if hash["key"].to_s.empty?

      directory = File.dirname(path)
      raw_name = File.basename(hash["log_path"].to_s)
      raw_name = "agent.raw.log" if raw_name.empty?
      archived_raw = File.join(directory, raw_name)
      hash = hash.merge("log_path" => archived_raw, "archived" => true, "archive_path" => directory)
      Record.new(agent: ManagedAgent.from_hash(hash), directory:, manifest_path: path)
    rescue StandardError => e
      HQ.logger.warn("AgentArchiveStore") { "Skipping #{path}: #{e.class} - #{e.message}" }
      nil
    end
  end
end
