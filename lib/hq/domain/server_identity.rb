# frozen_string_literal: true

require "socket"
require "securerandom"

require_relative "constants"
require_relative "file_store"

module HQ
  class ServerIdentity
    SCHEMA_VERSION = 1

    def self.load(path: SERVER_IDENTITY_FILE)
      new(path:).load
    end

    def initialize(path: SERVER_IDENTITY_FILE)
      @path = path
    end

    def load
      identity = FileStore.read_json(@path, fallback: {})
      return normalize(identity) unless identity["id"].to_s.empty?

      identity = {
        "schema_version" => SCHEMA_VERSION,
        "id" => SecureRandom.uuid,
        "name" => Socket.gethostname.to_s,
        "created_at" => Time.now.utc.iso8601
      }
      FileStore.write_json(@path, identity)
      identity
    end

    private

    def normalize(identity)
      {
        "schema_version" => SCHEMA_VERSION,
        "id" => identity["id"].to_s,
        "name" => identity["name"].to_s,
        "created_at" => identity["created_at"].to_s
      }
    end
  end
end
